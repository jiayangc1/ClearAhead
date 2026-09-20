import AVFoundation
import CoreHaptics
import Foundation

final class Feedback: NSObject, AVSpeechSynthesizerDelegate {
    private struct PendingSpeech {
        let text: String
        let key: String
        let priority: Double
        let createdAt: TimeInterval
    }

    private struct PendingTone {
        let profile: AudioCueProfile
        let priority: Double
    }

    private var hapticEngine: CHHapticEngine?
    private let audioEngine = AVAudioEngine()
    private let audioPlayer = AVAudioPlayerNode()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let audioQueue = DispatchQueue(label: "com.clearahead.feedback.audio", qos: .userInitiated)
    private var audioFormat: AVAudioFormat?
    private var tonePlaying = false
    private var pendingTone: PendingTone?
    private var pendingSpeech: PendingSpeech?
    private var lastSpokenKey: String?
    private var lastSpokenTime: TimeInterval = 0

    override init() {
        super.init()
        speechSynthesizer.delegate = self
        prepareHaptics()
        prepareAudio()
    }

    func stop() {
        audioQueue.async { [weak self] in
            self?.pendingTone = nil
            self?.tonePlaying = false
            self?.audioPlayer.stop()
            self?.audioEngine.stop()
        }
        DispatchQueue.main.async { [weak self] in
            self?.pendingSpeech = nil
            self?.speechSynthesizer.stopSpeaking(at: .immediate)
        }
        hapticEngine?.stop(completionHandler: nil)
    }

    func deliver(_ event: SpatialEvent, configuration: FeedbackConfiguration) {
        if configuration.hapticsEnabled {
            playHaptic(
                direction: event.direction,
                urgency: event.urgency,
                collisionRisk: event.collisionRisk,
                intensity: configuration.hapticIntensity
            )
        }
        if configuration.audioEnabled {
            enqueueTone(for: event, configuration: configuration)
        }
        if configuration.speechEnabled, event.urgency >= 0.68 {
            if event.collisionRisk != .none {
                speakCollision(event)
            } else if configuration.spokenCategories.contains(event.kind.rawValue) {
                speak(event)
            }
        }
    }

    func speakWarning(_ message: String, configuration: FeedbackConfiguration) {
        guard configuration.speechEnabled else { return }
        requestSpeech(text: message, key: "warning:\(message)", priority: 2, mayInterrupt: true)
    }

    private func prepareHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true
            engine.resetHandler = { [weak engine] in try? engine?.start() }
            try engine.start()
            hapticEngine = engine
        } catch {
            hapticEngine = nil
        }
    }

    private func playHaptic(
        direction: Direction,
        urgency: Double,
        collisionRisk: CollisionRisk,
        intensity: Double
    ) {
        guard let hapticEngine else { return }
        let strength = Float(min(max(intensity * (0.45 + urgency * 0.55), 0.1), 1))
        let timings: [TimeInterval]
        switch collisionRisk {
        case .imminent: timings = [0, 0.065, 0.13, 0.195]
        case .caution: timings = [0, 0.08, 0.19]
        case .none:
            switch direction {
            case .left: timings = [0, 0.09, 0.24]
            case .center: timings = [0, 0.12]
            case .right: timings = [0, 0.15, 0.24]
            }
        }
        let events = timings.map { time in
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: strength),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(0.45 + urgency * 0.45)),
                ],
                relativeTime: time
            )
        }
        guard let pattern = try? CHHapticPattern(events: events, parameters: []) else { return }
        try? hapticEngine.start()
        try? hapticEngine.makePlayer(with: pattern).start(atTime: 0)
    }

    private func prepareAudio() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) else { return }
        audioFormat = format
        audioEngine.attach(audioPlayer)
        audioEngine.connect(audioPlayer, to: audioEngine.mainMixerNode, format: format)
        activateAudioEngine()
    }

    private func activateAudioEngine() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers, .duckOthers, .allowBluetoothA2DP]
            )
            try session.setActive(true)
            if !audioEngine.isRunning { try audioEngine.start() }
        } catch {
            // A later cue retries activation and engine startup.
        }
    }

    private func enqueueTone(for event: SpatialEvent, configuration: FeedbackConfiguration) {
        let pending = PendingTone(
            profile: AudioCueProfile(event: event, configuration: configuration),
            priority: event.urgency + (event.collisionRisk == .imminent ? 1 : 0)
        )
        audioQueue.async { [weak self] in
            guard let self else { return }
            if tonePlaying {
                if pending.priority >= (pendingTone?.priority ?? -1) {
                    pendingTone = pending
                }
                return
            }
            playTone(pending)
        }
    }

    private func playTone(_ pending: PendingTone) {
        guard let audioBuffer = makeAudioBuffer(profile: pending.profile) else { return }
        activateAudioEngine()
        guard audioEngine.isRunning else { return }
        tonePlaying = true
        audioPlayer.scheduleBuffer(
            audioBuffer,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            self?.audioQueue.async {
                guard let self else { return }
                self.tonePlaying = false
                if let next = self.pendingTone {
                    self.pendingTone = nil
                    self.playTone(next)
                }
            }
        }
        if !audioPlayer.isPlaying { audioPlayer.play() }
    }

    private func makeAudioBuffer(profile: AudioCueProfile) -> AVAudioPCMBuffer? {
        guard let audioFormat else { return nil }
        let sampleRate = audioFormat.sampleRate
        let pulseFrames = Int(profile.pulseDuration * sampleRate)
        let gapFrames = Int(profile.pulseGap * sampleRate)
        let frameCount = profile.pulseCount * pulseFrames + (profile.pulseCount - 1) * gapFrames
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let channels = buffer.floatChannelData else { return nil }
        for frame in 0..<frameCount {
            channels[0][frame] = 0
            channels[1][frame] = 0
        }

        let normalizedPan = min(max((Double(profile.pan) + 1) / 2, 0), 1)
        let leftGain = Float(sqrt(1 - normalizedPan)) * profile.gain
        let rightGain = Float(sqrt(normalizedPan)) * profile.gain
        for pulse in 0..<profile.pulseCount {
            let pulseStart = pulse * (pulseFrames + gapFrames)
            for frame in 0..<pulseFrames {
                let progress = Double(frame) / Double(max(pulseFrames - 1, 1))
                let elapsed = Double(frame) / sampleRate
                let sweepRate = (profile.endFrequency - profile.startFrequency) / profile.pulseDuration
                let phase = 2 * Double.pi
                    * (profile.startFrequency * elapsed + 0.5 * sweepRate * elapsed * elapsed)
                let envelope = pow(sin(Double.pi * progress), 2)
                let sample = Float((sin(phase) + 0.12 * sin(phase * 2)) * envelope * 0.3)
                channels[0][pulseStart + frame] = sample * leftGain
                channels[1][pulseStart + frame] = sample * rightGain
            }
        }
        return buffer
    }

    private func speak(_ event: SpatialEvent) {
        let label = event.label ?? event.kind.rawValue
        let distance = event.approximateDistanceMeters.map { String(format: "about %.1f meters", $0) }
            ?? event.proximity.rawValue
        let clock = event.direction == .left ? "10 o'clock" : event.direction == .right ? "2 o'clock" : "12 o'clock"
        requestSpeech(
            text: "\(label), \(distance), \(clock)",
            key: "event:\(event.id):\(event.proximity.rawValue)",
            priority: event.urgency,
            mayInterrupt: false
        )
    }

    private func speakCollision(_ event: SpatialEvent) {
        let label = event.label ?? event.kind.rawValue
        let direction = event.direction == .center ? "ahead" : "to the \(event.direction.rawValue)"
        let instruction = event.collisionRisk == .imminent ? "Stop." : "Caution."
        requestSpeech(
            text: "\(instruction) \(label) \(direction).",
            key: "collision:\(event.id):\(event.collisionRisk.rawValue)",
            priority: event.collisionRisk == .imminent ? 2 : 1,
            mayInterrupt: event.collisionRisk == .imminent
        )
    }

    private func requestSpeech(text: String, key: String, priority: Double, mayInterrupt: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard key != lastSpokenKey || now - lastSpokenTime >= 2.5 else { return }
            let speech = PendingSpeech(text: text, key: key, priority: priority, createdAt: now)
            if mayInterrupt, speechSynthesizer.isSpeaking {
                pendingSpeech = nil
                speechSynthesizer.stopSpeaking(at: .immediate)
                startSpeech(speech)
            } else if speechSynthesizer.isSpeaking {
                if priority >= (pendingSpeech?.priority ?? -1) {
                    pendingSpeech = speech
                }
            } else {
                startSpeech(speech)
            }
        }
    }

    private func startSpeech(_ speech: PendingSpeech) {
        lastSpokenKey = speech.key
        lastSpokenTime = ProcessInfo.processInfo.systemUptime
        let utterance = AVSpeechUtterance(string: speech.text)
        utterance.rate = 0.58
        utterance.preUtteranceDelay = 0
        speechSynthesizer.speak(utterance)
    }

    private func drainPendingSpeech() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !speechSynthesizer.isSpeaking, let pendingSpeech else { return }
            self.pendingSpeech = nil
            if ProcessInfo.processInfo.systemUptime - pendingSpeech.createdAt <= 1.5 {
                startSpeech(pendingSpeech)
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        drainPendingSpeech()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        drainPendingSpeech()
    }
}

struct AudioCueProfile {
    let startFrequency: Double
    let endFrequency: Double
    let pulseCount: Int
    let pulseDuration: TimeInterval
    let pulseGap: TimeInterval
    let pan: Float
    let gain: Float

    init(event: SpatialEvent, configuration: FeedbackConfiguration) {
        let closeness: Double
        if let distance = event.approximateDistanceMeters {
            closeness = 1 - min(max(distance / configuration.warningDistanceMeters, 0), 1)
        } else {
            switch event.proximity {
            case .near: closeness = 0.88
            case .medium: closeness = 0.56
            case .far: closeness = 0.24
            case .unknown: closeness = 0.16
            }
        }

        let baseFrequency = 360 + closeness * 720
        if event.collisionRisk != .none {
            startFrequency = 520
            endFrequency = event.collisionRisk == .imminent ? 1_420 : 1_120
        } else {
            switch event.direction {
            case .left:
                startFrequency = baseFrequency * 1.12
                endFrequency = baseFrequency * 0.88
            case .center:
                startFrequency = baseFrequency
                endFrequency = baseFrequency
            case .right:
                startFrequency = baseFrequency * 0.88
                endFrequency = baseFrequency * 1.12
            }
        }

        let urgency = min(max(event.urgency, 0), 1)
        if event.collisionRisk == .imminent {
            pulseCount = 4
        } else if event.collisionRisk == .caution || urgency >= 0.75 {
            pulseCount = 3
        } else if urgency >= 0.4 {
            pulseCount = 2
        } else {
            pulseCount = 1
        }
        pulseDuration = event.collisionRisk == .none ? 0.075 - urgency * 0.02 : 0.045
        pulseGap = event.collisionRisk == .none ? 0.18 - urgency * 0.11 : 0.05
        pan = event.direction.pan
        gain = Float(min(max(configuration.audioVolume * (0.72 + urgency * 0.28), 0), 1))
    }
}
