import AVFoundation
import CoreHaptics
import Foundation
import OSLog
import UIKit
import simd

final class Feedback: NSObject, AVSpeechSynthesizerDelegate {
    private struct PendingSpeech {
        let generation: Int
        let text: String
        let key: String
        let priority: Double
        let createdAt: TimeInterval
    }

    private var hapticEngine: CHHapticEngine?
    private var hapticPlayer: (any CHHapticPatternPlayer)?
    private let deliveryLock = NSLock()
    private let audioEngine = AVAudioEngine()
    private lazy var sceneAudio = SpatialAudio(engine: audioEngine)
    private var urgencyHaptics = UrgencyHaptics()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let audioQueue = DispatchQueue(label: "com.clearahead.feedback.audio", qos: .userInitiated)
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
        _ = sceneAudio
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
        urgencyHaptics = UrgencyHaptics()
        audioQueue.sync { sceneAudio.start(queue: audioQueue) }
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
            silenceTones()
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
                silenceTones()
                audioEngine.stop()
                audioSessionActive = false
            }
        } else {
            audioQueue.sync { sceneAudio.start(queue: audioQueue) }
        }
    }

    private func silenceTones() { sceneAudio.stop() }

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
        if Self.shouldSpeak(event, configuration: configuration, voiceOverRunning: UIAccessibility.isVoiceOverRunning) {
            if event.collisionRisk != .none {
                speakCollision(event)
            } else if configuration.spokenCategories.contains(event.kind.rawValue) {
                speak(event)
            }
        }
    }

    func updateScene(_ sources: [SceneSource], configuration: FeedbackConfiguration,
                     camera: simd_quatd?, earCalibrated: Bool) {
        let token = generation.current
        audioQueue.async { [weak self] in
            guard let self, acceptsAudio(token) else { return }
            guard activateAudioEngine() else { return }
            sceneAudio.update(sources, configuration: configuration, camera: camera, earCalibrated: earCalibrated)
        }
        let risk = sources.max { $0.event.collisionRisk < $1.event.collisionRisk }?.event.collisionRisk ?? .none
        deliveryLock.lock()
        let play = generation.accepts(token) && urgencyHaptics.shouldPlay(risk, now: ProcessInfo.processInfo.systemUptime)
        if play, configuration.hapticsEnabled, let event = sources.first(where: { $0.event.collisionRisk == risk })?.event {
            playHaptic(direction: event.direction, urgency: event.urgency, collisionRisk: risk, intensity: configuration.hapticIntensity)
        }
        deliveryLock.unlock()
    }

    var spatialCapability: String { audioQueue.sync { sceneAudio.capability } }

    func clearTracking() {
        audioQueue.async { [weak self] in self?.sceneAudio.clear() }
    }

    static func shouldSpeak(_ event: SpatialEvent, configuration: FeedbackConfiguration, voiceOverRunning: Bool) -> Bool {
        configuration.speechEnabled && !voiceOverRunning
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
        case .none: return
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
            guard let self, acceptsAudio(token), force || !audioEngine.isRunning else { return }
            if force, currentAudioRoute() == lastAudioRoute { return }
            audioEngine.stop()
            audioEngine.reset()
            sceneAudio.recover()
            sceneAudio.start(queue: audioQueue)
            audioSessionActive = false
            lastAudioRoute = currentAudioRoute()
            _ = activateAudioEngine()
        }
    }

    private func currentAudioRoute() -> String {
        let session = AVAudioSession.sharedInstance()
        return session.currentRoute.outputs.map {
            "\($0.uid):\($0.channels?.count ?? 0)"
        }.joined(separator: ",") + ":\(session.sampleRate)"
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
        utterance.volume = 0.75
        utterance.preUtteranceDelay = 0
        activeUtterance = utterance
        audioQueue.async { [weak self] in self?.sceneAudio.duck(true) }
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
            audioQueue.async { [weak self] in self?.sceneAudio.duck(false) }
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
