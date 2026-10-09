import AVFoundation
import CoreMotion
import Foundation
import simd
import UIKit

/// Six continuous mono sources feed Apple's environment renderer, not a stereo pan approximation.
final class SpatialAudio {
    private final class Voice {
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        let color = AVAudioUnitEQ(numberOfBands: 1)
        let spatial = AVAudioMixerNode()
        var id: String?
        var kind: EventKind = .obstacle
        var gain: Float = 0
        var targetGain: Float = 0
        var position = SIMD3<Double>(0, 0, -1)
        var targetPosition = SIMD3<Double>(0, 0, -1)
        var buffer: AVAudioPCMBuffer?
        var cue = SceneTone.Cue(pitchCents: 0, brightness: 0, pulseRate: 0.8, pulseDepth: 0.15)
        var pulsePhase = 0.0
        var pulseRate = 0.8
        var pulseDepth = 0.15
    }

    private let engine: AVAudioEngine
    private let environment = AVAudioEnvironmentNode()
    private let voices = (0..<SceneSelector.maximumSources).map { _ in Voice() }
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private let headphones = CMHeadphoneMotionManager()
    private let motionQueue = OperationQueue()
    private let motionLock = NSLock()
    private var head: simd_quatd?
    private var headTime: TimeInterval = 0
    private var motionGeneration = 0
    private var alignment: simd_quatd?
    private var camera = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))
    private var lastUpdate: TimeInterval = 0
    private var timer: DispatchSourceTimer?
    private var speechActive = false
    private var stereo = false
    private var geometryAvailable = false
    private var earCalibrated = false
    private var lastTick: TimeInterval = 0

    init(engine: AVAudioEngine) {
        self.engine = engine
        engine.attach(environment)
        environment.outputType = .auto
        environment.reverbParameters.enable = false
        // Distance is encoded explicitly in gain, avoiding attenuation applied twice.
        environment.distanceAttenuationParameters.rolloffFactor = 0
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        for voice in voices {
            engine.attach(voice.player)
            engine.attach(voice.pitch)
            engine.attach(voice.color)
            engine.attach(voice.spatial)
            voice.color.bands[0].filterType = .highShelf
            voice.color.bands[0].frequency = 500
            voice.color.bands[0].bypass = false
            voice.spatial.renderingAlgorithm = .auto
            voice.spatial.outputVolume = 0
            connect(voice)
        }
        engine.mainMixerNode.outputVolume = 0.8
    }

    func start(queue: DispatchQueue) {
        alignment = nil
        lastTick = ProcessInfo.processInfo.systemUptime
        headphones.stopDeviceMotionUpdates()
        motionLock.lock()
        motionGeneration += 1
        let token = motionGeneration
        head = nil
        motionLock.unlock()
        if headphones.isDeviceMotionAvailable {
            headphones.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
                guard let self else { return }
                motionLock.lock()
                guard motionGeneration == token else { motionLock.unlock(); return }
                head = motion.map { Self.attitude($0.attitude) * SceneAudioMath.audioToHeadphoneAxes }
                headTime = ProcessInfo.processInfo.systemUptime
                motionLock.unlock()
            }
        }
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.02)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        headphones.stopDeviceMotionUpdates()
        motionLock.lock()
        motionGeneration += 1
        head = nil
        motionLock.unlock()
        alignment = nil
        speechActive = false
        for voice in voices {
            voice.player.stop()
            voice.id = nil
            voice.gain = 0
            voice.targetGain = 0
            voice.spatial.outputVolume = 0
        }
    }

    func clear() { for voice in voices { voice.targetGain = 0 } }
    func realign() { alignment = nil }
    func duck(_ active: Bool) { speechActive = active }

    func update(_ sources: [SceneSource], configuration: FeedbackConfiguration,
                camera: simd_quatd?, earCalibrated: Bool) {
        self.camera = camera ?? self.camera
        self.earCalibrated = earCalibrated
        geometryAvailable = camera != nil && sources.allSatisfy { $0.position != nil }
        lastUpdate = ProcessInfo.processInfo.systemUptime
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        stereo = !outputs.isEmpty && outputs.allSatisfy {
            [.headphones, .bluetoothA2DP, .bluetoothLE].contains($0.portType) && ($0.channels?.count ?? 0) >= 2
        }
        for voice in voices where !sources.contains(where: { $0.event.id == voice.id }) { voice.targetGain = 0 }
        for source in sources {
            let existing = voices.first { $0.id == source.event.id }
            guard let voice = existing ?? voices.first(where: { $0.id == nil }) else { continue }
            if voice.id == nil || voice.kind != source.event.kind {
                voice.player.stop()
                voice.id = source.event.id
                if voice.kind != source.event.kind { voice.buffer = nil }
                voice.kind = source.event.kind
                let slot = voices.firstIndex { $0 === voice }!
                voice.buffer = voice.buffer ?? buffer(kind: voice.kind, slot: slot)
                if let buffer = voice.buffer {
                    voice.player.scheduleBuffer(buffer, at: nil, options: .loops)
                    voice.player.play()
                }
            }
            voice.targetPosition = source.position ?? SIMD3(Double(source.event.pan), 0, -1)
            voice.cue = SceneTone.cue(event: source.event, position: source.position, range: configuration.warningDistanceMeters)
            if existing == nil {
                voice.position = voice.targetPosition
                voice.pitch.pitch = voice.cue.pitchCents
                voice.color.bands[0].gain = voice.cue.brightness
                voice.pulseRate = voice.cue.pulseRate
                voice.pulseDepth = voice.cue.pulseDepth
                voice.pulsePhase = 0
            }
            // Legacy repeat-off preference now means scene tones off; speech/haptics stay available.
            voice.targetGain = configuration.audioEnabled && configuration.continuousAudio
                ? SceneAudioMath.gain(distance: source.event.approximateDistanceMeters ?? configuration.warningDistanceMeters,
                                      range: configuration.warningDistanceMeters, volume: configuration.audioVolume,
                                      count: SceneSelector.maximumSources) : 0
        }
    }

    var capability: String {
        guard stereo else { return "speaker: no reliable height, front/back, or head tracking" }
        guard geometryAvailable else { return "stereo direction only: camera geometry/motion unavailable" }
        motionLock.lock()
        let tracksHead = head != nil && ProcessInfo.processInfo.systemUptime - headTime < 0.5
        motionLock.unlock()
        return "binaural; \(tracksHead ? "head tracking" : "head tracking unavailable"); \(earCalibrated ? "ear height calibrated" : "camera-centered: set ear height")"
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(max(now - lastTick, 0), 0.1)
        lastTick = now
        motionLock.lock()
        let currentHead = now - headTime < 0.5 ? head : nil
        motionLock.unlock()
        // At session start look along the camera; phone and headphones have independent arbitrary yaw origins.
        if alignment == nil, geometryAvailable, let currentHead { alignment = camera * currentHead.inverse }
        for voice in voices {
            let target = now - lastUpdate < 0.8 ? voice.targetGain * (speechActive || UIAccessibility.isVoiceOverRunning ? 0.2 : 1) : 0
            voice.gain += (target - voice.gain) * 0.12
            voice.position += (voice.targetPosition - voice.position) * 0.18
            let point: SIMD3<Double>
            if stereo, geometryAvailable, let currentHead, let alignment {
                point = SceneAudioMath.listenerPoint(voice.position, camera: camera, head: currentHead, alignment: alignment)
            } else { point = voice.position }
            voice.pitch.pitch += (voice.cue.pitchCents - voice.pitch.pitch) * 0.12
            voice.color.bands[0].gain += (voice.cue.brightness - voice.color.bands[0].gain) * 0.12
            voice.pulseRate += (voice.cue.pulseRate - voice.pulseRate) * 0.12
            voice.pulseDepth += (voice.cue.pulseDepth - voice.pulseDepth) * 0.12
            voice.pulsePhase = (voice.pulsePhase + elapsed * 2 * .pi * voice.pulseRate).truncatingRemainder(dividingBy: 2 * .pi)
            voice.spatial.position = AVAudio3DPoint(x: Float(point.x), y: Float(point.y), z: Float(point.z))
            voice.spatial.outputVolume = voice.gain * SceneTone.pulse(phase: voice.pulsePhase, depth: voice.pulseDepth)
            if target == 0, voice.gain < 0.0001 {
                voice.player.stop()
                voice.id = nil
            }
        }
    }

    func recover() {
        alignment = nil
        engine.disconnectNodeOutput(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        for (slot, voice) in voices.enumerated() {
            voice.player.stop()
            engine.disconnectNodeOutput(voice.player)
            engine.disconnectNodeOutput(voice.pitch)
            engine.disconnectNodeOutput(voice.color)
            engine.disconnectNodeOutput(voice.spatial)
            connect(voice)
            voice.buffer = voice.buffer ?? buffer(kind: voice.kind, slot: slot)
            if voice.id != nil, let buffer = voice.buffer {
                voice.player.scheduleBuffer(buffer, at: nil, options: .loops)
                voice.player.play()
            }
        }
    }

    private func connect(_ voice: Voice) {
        engine.connect(voice.player, to: voice.pitch, format: format)
        engine.connect(voice.pitch, to: voice.color, format: format)
        engine.connect(voice.color, to: voice.spatial, format: format)
        engine.connect(voice.spatial, to: environment, format: format)
    }

    private func buffer(kind: EventKind, slot: Int) -> AVAudioPCMBuffer? {
        let samples = SceneTone.samples(kind: kind, slot: slot, sampleRate: Int(format.sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for i in samples.indices { channel[i] = samples[i] }
        return buffer
    }

    static func attitude(_ attitude: CMAttitude) -> simd_quatd {
        let q = attitude.quaternion
        // Core Motion reports reference-to-device attitude; scene points need device-to-reference.
        return simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w).inverse
    }
}
