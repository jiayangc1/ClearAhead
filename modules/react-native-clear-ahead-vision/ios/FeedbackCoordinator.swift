import AVFoundation
import CoreHaptics
import Foundation

final class FeedbackCoordinator: NSObject, AVSpeechSynthesizerDelegate {
    private var hapticEngine: CHHapticEngine?
    private let audioEngine = AVAudioEngine()
    private let audioPlayer = AVAudioPlayerNode()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var audioFormat: AVAudioFormat?

    override init() {
        super.init()
        speechSynthesizer.delegate = self
        prepareHaptics()
        prepareAudio()
    }

    func stop() {
        audioPlayer.stop()
        speechSynthesizer.stopSpeaking(at: .immediate)
        hapticEngine?.stop(completionHandler: nil)
    }

    func deliver(_ event: CASpatialEvent, configuration: CAFeedbackConfiguration) {
        if configuration.hapticsEnabled {
            playHaptic(
                direction: event.direction,
                urgency: event.urgency,
                collisionRisk: event.collisionRisk,
                intensity: configuration.hapticIntensity
            )
        }
        if configuration.audioEnabled {
            playTone(for: event, configuration: configuration)
        }
        if configuration.speechEnabled, event.urgency >= 0.68 {
            if event.collisionRisk != .none {
                speakCollision(event)
            } else if configuration.spokenCategories.contains(event.kind.rawValue) {
                speak(event)
            }
        }
    }

    func speakWarning(_ message: String, configuration: CAFeedbackConfiguration) {
        guard configuration.speechEnabled else { return }
        speechSynthesizer.stopSpeaking(at: .word)
        let utterance = AVSpeechUtterance(string: message)
        utterance.rate = 0.56
        utterance.preUtteranceDelay = 0
        speechSynthesizer.speak(utterance)
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
        direction: CADirection,
        urgency: Double,
        collisionRisk: CACollisionRisk,
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
    }

    private func playTone(for event: CASpatialEvent, configuration: CAFeedbackConfiguration) {
        let profile = AudioCueProfile(event: event, configuration: configuration)
        guard let audioBuffer = makeAudioBuffer(profile: profile) else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.mixWithOthers, .duckOthers, .allowBluetoothA2DP]
            )
            try session.setActive(true)
            if !audioEngine.isRunning { try audioEngine.start() }
            audioPlayer.pan = profile.pan
            audioPlayer.volume = profile.gain
            audioPlayer.stop()
            audioPlayer.scheduleBuffer(audioBuffer, at: nil, options: [], completionHandler: nil)
            audioPlayer.play()
        } catch {
            // Audio failures are surfaced by session quality elsewhere; never block haptics.
        }
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
                channels[0][pulseStart + frame] = sample
                channels[1][pulseStart + frame] = sample
            }
        }
        return buffer
    }

    private func speak(_ event: CASpatialEvent) {
        speechSynthesizer.stopSpeaking(at: .word)
        let distance: String
        if let meters = event.approximateDistanceMeters {
            distance = String(format: "about %.1f meters", meters)
        } else {
            distance = event.proximity.rawValue
        }
        let clock = event.direction == .left ? "10 o'clock" : event.direction == .right ? "2 o'clock" : "12 o'clock"
        let utterance = AVSpeechUtterance(string: "\(event.kind.rawValue), \(distance), \(clock)")
        utterance.rate = 0.58
        utterance.preUtteranceDelay = 0
        speechSynthesizer.speak(utterance)
    }

    private func speakCollision(_ event: CASpatialEvent) {
        speechSynthesizer.stopSpeaking(at: .immediate)
        let direction = event.direction == .center ? "ahead" : "to the \(event.direction.rawValue)"
        let instruction = event.collisionRisk == .imminent ? "Stop." : "Caution."
        let utterance = AVSpeechUtterance(string: "\(instruction) \(event.kind.rawValue) \(direction).")
        utterance.rate = 0.58
        utterance.preUtteranceDelay = 0
        speechSynthesizer.speak(utterance)
    }
}
