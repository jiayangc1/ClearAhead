import AVFoundation
import CoreHaptics
import Foundation
import OSLog
import UIKit

final class Feedback: NSObject, AVSpeechSynthesizerDelegate {
    private struct PendingSpeech {
        let generation: Int
        let text: String
        let key: String
        let priority: Double
        let createdAt: TimeInterval
    }

    private struct PendingTone {
        let generation: Int
        let event: SpatialEvent
        let configuration: FeedbackConfiguration
        let priority: Double
        let createdAt: TimeInterval
    }

    private var hapticEngine: CHHapticEngine?
    private var hapticPlayer: (any CHHapticPatternPlayer)?
    private let deliveryLock = NSLock()
    private let audioEngine = AVAudioEngine()
    private let audioPlayer = AVAudioPlayerNode()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let audioQueue = DispatchQueue(label: "com.clearahead.feedback.audio", qos: .userInitiated)
    private var audioFormat: AVAudioFormat?
    private var tonePlaying = false
    private var tonePlaybackGeneration = 0
    private var pendingTone: PendingTone?
    private var activeTone: PendingTone?
    private var lastAudioRoute: String?
    private var pendingSpeech: PendingSpeech?
    private var activeSpeech: PendingSpeech?
    private var activeUtterance: AVSpeechUtterance?
    private var lastSpeechTimes: [String: TimeInterval] = [:]
    private var audioSessionActive = false
    private let logger = Logger(subsystem: "com.clearahead.vision", category: "feedback")
    private var observers: [NSObjectProtocol] = []
    private let generation = FeedbackGeneration()
    private let availabilityLock = NSLock()
    private var audioAvailable = true

    override init() {
        super.init()
        speechSynthesizer.delegate = self
        prepareHaptics()
        prepareAudio()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.recoverAudioOutput(force: true)
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: nil) { [weak self] _ in
            self?.recoverAudioOutput(force: false)
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func start(audioAvailable: Bool = true) {
        precondition(Thread.isMainThread)
        generation.start()
        availabilityLock.lock()
        self.audioAvailable = audioAvailable
        availabilityLock.unlock()
    }

    func stop() {
        generation.stop()
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        // Module lifecycle and watchdog calls run on main. Never synchronously
        // dispatch from frame processing to main while it may wait for frameLock.
        precondition(Thread.isMainThread)
        pendingSpeech = nil
        activeSpeech = nil
        activeUtterance = nil
        lastSpeechTimes.removeAll()
        speechSynthesizer.stopSpeaking(at: .immediate)
        audioQueue.sync {
            pendingTone = nil
            activeTone = nil
            tonePlaying = false
            tonePlaybackGeneration += 1
            audioPlayer.stop()
            audioEngine.stop()
            audioSessionActive = false
        }
        try? hapticPlayer?.stop(atTime: 0)
        hapticPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func setAudioAvailable(_ available: Bool) {
        precondition(Thread.isMainThread)
        availabilityLock.lock()
        audioAvailable = available
        availabilityLock.unlock()
        if !available {
            if generation.accepts(generation.current) { generation.start() }
            pendingSpeech = nil
            activeSpeech = nil
            activeUtterance = nil
            speechSynthesizer.stopSpeaking(at: .immediate)
            audioQueue.sync {
                pendingTone = nil
                activeTone = nil
                tonePlaying = false
                tonePlaybackGeneration += 1
                audioPlayer.stop()
                audioEngine.stop()
                audioSessionActive = false
            }
        }
    }

    private func acceptsAudio(_ token: Int) -> Bool {
        availabilityLock.lock()
        let available = audioAvailable
        availabilityLock.unlock()
        return available && generation.accepts(token)
    }

    func deliver(_ event: SpatialEvent, configuration: FeedbackConfiguration) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        guard generation.accepts(generation.current) else { return }
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
        if Self.shouldSpeak(event, configuration: configuration, voiceOverRunning: UIAccessibility.isVoiceOverRunning) {
            if event.collisionRisk != .none {
                speakCollision(event)
            } else if configuration.spokenCategories.contains(event.kind.rawValue) {
                speak(event)
            }
        }
    }

    static func shouldSpeak(_ event: SpatialEvent, configuration: FeedbackConfiguration, voiceOverRunning: Bool) -> Bool {
        configuration.speechEnabled && !voiceOverRunning
            && (event.urgency >= 0.68 || event.approximateDistanceMeters == nil)
            && (event.collisionRisk != .none || configuration.spokenCategories.contains(event.kind.rawValue))
    }

    func speakWarning(_ message: String, configuration: FeedbackConfiguration) {
        guard configuration.speechEnabled, !UIAccessibility.isVoiceOverRunning else { return }
        requestSpeech(text: message, key: "warning:\(message)", priority: 0.5, mayInterrupt: false)
    }

    private func prepareHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            engine.resetHandler = { [weak self, weak engine] in
                guard let self else { return }
                deliveryLock.lock()
                defer { deliveryLock.unlock() }
                guard generation.accepts(generation.current) else { return }
                hapticPlayer = nil
                try? engine?.start()
            }
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
        try? hapticPlayer?.stop(atTime: 0)
        try? hapticEngine.start()
        hapticPlayer = try? hapticEngine.makePlayer(with: pattern)
        try? hapticPlayer?.start(atTime: 0)
    }

    private func prepareAudio() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) else { return }
        audioFormat = format
        audioEngine.attach(audioPlayer)
        audioEngine.connect(audioPlayer, to: audioEngine.mainMixerNode, format: format)
    }

    static let playbackOptions: AVAudioSession.CategoryOptions = [.mixWithOthers, .duckOthers]

    private func activateAudioSession() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            // Playback routes to Bluetooth automatically and to the speaker without headphones.
            // Bluetooth input options are invalid for this output-only category on newer iOS.
            if session.category != .playback || session.mode != .default || session.categoryOptions != Self.playbackOptions {
                try session.setCategory(.playback, mode: .default, options: Self.playbackOptions)
                audioSessionActive = false
            }
            if !audioSessionActive {
                try session.setActive(true)
                audioSessionActive = true
            }
            return true
        } catch {
            audioSessionActive = false
            logger.error("Audio activation failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func activateAudioEngine() -> Bool {
        guard activateAudioSession() else { return false }
        if audioEngine.isRunning { return true }
        do {
            try audioEngine.start()
            return true
        } catch {
            logger.error("Audio engine failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func recoverAudioOutput(force: Bool) {
        let token = generation.current
        audioQueue.async { [weak self] in
            guard let self, acceptsAudio(token), force || (tonePlaying && !audioEngine.isRunning) else { return }
            if force, currentAudioRoute() == lastAudioRoute { return }
            let interruptedTone = activeTone
            pendingTone = nil
            activeTone = nil
            tonePlaying = false
            tonePlaybackGeneration += 1
            audioPlayer.stop()
            audioEngine.stop()
            audioEngine.reset()
            audioEngine.disconnectNodeOutput(audioPlayer)
            audioEngine.connect(audioPlayer, to: audioEngine.mainMixerNode, format: audioFormat)
            audioSessionActive = false
            lastAudioRoute = currentAudioRoute()
            // Replay a still-current interrupted cue on the new route; otherwise start lazily.
            if let interruptedTone { playTone(interruptedTone) }
        }
    }

    private func currentAudioRoute() -> String {
        let session = AVAudioSession.sharedInstance()
        return session.currentRoute.outputs.map {
            "\($0.uid):\($0.channels?.count ?? 0)"
        }.joined(separator: ",") + ":\(session.sampleRate)"
    }

    private func enqueueTone(for event: SpatialEvent, configuration: FeedbackConfiguration) {
        let pending = PendingTone(
            generation: generation.current,
            event: event,
            configuration: configuration,
            priority: event.urgency + (event.collisionRisk == .imminent ? 1 : 0),
            createdAt: ProcessInfo.processInfo.systemUptime
        )
        audioQueue.async { [weak self] in
            guard let self, acceptsAudio(pending.generation) else { return }
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
        guard acceptsAudio(pending.generation), ProcessInfo.processInfo.systemUptime - pending.createdAt <= 0.8,
              activateAudioEngine() else { return }
        lastAudioRoute = currentAudioRoute()
        // Read the active route at playback so queued cues follow output changes.
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let stereo = !outputs.isEmpty && outputs.allSatisfy {
            $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver
                && ($0.channels?.count ?? 0) >= 2
        }
        let profile = AudioCueProfile(
            event: pending.event, configuration: pending.configuration, stereo: stereo
        )
        guard let audioBuffer = makeAudioBuffer(profile: profile) else { return }
        tonePlaying = true
        activeTone = pending
        tonePlaybackGeneration += 1
        let playbackGeneration = tonePlaybackGeneration
        audioPlayer.scheduleBuffer(
            audioBuffer,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            self?.audioQueue.async {
                guard let self, self.acceptsAudio(pending.generation),
                      self.tonePlaybackGeneration == playbackGeneration else { return }
                self.tonePlaying = false
                self.activeTone = nil
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
        let motion = event.motionState == .approaching ? ", approaching" : ""
        requestSpeech(
            text: "\(label), \(distance), \(clock)\(motion)",
            key: "event:\(event.id):\(event.proximity.rawValue):\(event.motionState.rawValue)",
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
        let token = generation.current
        DispatchQueue.main.async { [weak self] in
            guard let self, acceptsAudio(token), !UIAccessibility.isVoiceOverRunning else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard key != activeSpeech?.key, key != pendingSpeech?.key,
                  now - (lastSpeechTimes[key] ?? -Double.infinity) >= (priority >= 2 ? 4 : 6) else { return }
            let speech = PendingSpeech(generation: token, text: text, key: key, priority: priority, createdAt: now)
            if let current = activeSpeech,
               Self.shouldInterruptSpeech(currentPriority: current.priority, incomingPriority: priority, mayInterrupt: mayInterrupt) {
                pendingSpeech = nil
                activeSpeech = nil
                activeUtterance = nil
                speechSynthesizer.stopSpeaking(at: .immediate)
                startSpeech(speech)
            } else if activeSpeech != nil || speechSynthesizer.isSpeaking {
                if priority >= (pendingSpeech?.priority ?? -1) {
                    pendingSpeech = speech
                }
            } else {
                startSpeech(speech)
            }
        }
    }

    private func startSpeech(_ speech: PendingSpeech) {
        guard acceptsAudio(speech.generation), !UIAccessibility.isVoiceOverRunning else { return }
        guard audioQueue.sync(execute: { activateAudioSession() }) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lastSpeechTimes = lastSpeechTimes.filter { now - $0.value < 10 }
        lastSpeechTimes[speech.key] = now
        activeSpeech = speech
        let utterance = AVSpeechUtterance(string: speech.text)
        utterance.rate = 0.58
        utterance.preUtteranceDelay = 0
        activeUtterance = utterance
        speechSynthesizer.speak(utterance)
    }

    static func shouldInterruptSpeech(currentPriority: Double, incomingPriority: Double, mayInterrupt: Bool) -> Bool {
        mayInterrupt && incomingPriority >= 2 && incomingPriority > currentPriority
    }

    private func finishSpeech(_ utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, utterance === activeUtterance else { return }
            activeSpeech = nil
            activeUtterance = nil
            guard let pendingSpeech else { return }
            self.pendingSpeech = nil
            if acceptsAudio(pendingSpeech.generation), ProcessInfo.processInfo.systemUptime - pendingSpeech.createdAt <= 3 {
                startSpeech(pendingSpeech)
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishSpeech(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finishSpeech(utterance)
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

    init(event: SpatialEvent, configuration: FeedbackConfiguration, stereo: Bool = true) {
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

        let baseFrequency = event.collisionRisk == .none
            ? 360 + closeness * 720
            : (event.collisionRisk == .imminent ? 970.0 : 820.0)
        if event.collisionRisk != .none && stereo {
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
        pan = stereo ? event.pan : 0
        gain = Float(min(max(configuration.audioVolume * (0.72 + urgency * 0.28), 0), 1))
    }
}
