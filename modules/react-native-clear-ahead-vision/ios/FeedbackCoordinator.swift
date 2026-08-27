import AVFoundation
import CoreHaptics
import Foundation

final class FeedbackCoordinator: NSObject, AVSpeechSynthesizerDelegate {
    private var hapticEngine: CHHapticEngine?
    private let audioEngine = AVAudioEngine()
    private let audioPlayer = AVAudioPlayerNode()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var audioBuffer: AVAudioPCMBuffer?

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
            playHaptic(direction: event.direction, urgency: event.urgency, intensity: configuration.hapticIntensity)
        }
        if configuration.audioEnabled {
            playTone(direction: event.direction, urgency: event.urgency, volume: configuration.audioVolume)
        }
        if configuration.speechEnabled,
           configuration.spokenCategories.contains(event.kind.rawValue),
           event.urgency >= 0.68 {
            speak(event)
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

    private func playHaptic(direction: CADirection, urgency: Double, intensity: Double) {
        guard let hapticEngine else { return }
        let strength = Float(min(max(intensity * (0.45 + urgency * 0.55), 0.1), 1))
        let timings: [TimeInterval]
        switch direction {
        case .left: timings = [0, 0.09, 0.24]
        case .center: timings = [0, 0.12]
        case .right: timings = [0, 0.15, 0.24]
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
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let frameCount = AVAudioFrameCount(44_100 * 0.085)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            let envelope = sin(Double(frame) / Double(frameCount) * .pi)
            let sample = Float(sin(2 * .pi * 880 * Double(frame) / 44_100) * envelope * 0.34)
            buffer.floatChannelData?[0][frame] = sample
            buffer.floatChannelData?[1][frame] = sample
        }
        audioBuffer = buffer
        audioEngine.attach(audioPlayer)
        audioEngine.connect(audioPlayer, to: audioEngine.mainMixerNode, format: format)
    }

    private func playTone(direction: CADirection, urgency: Double, volume: Double) {
        guard let audioBuffer else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.mixWithOthers, .duckOthers, .allowBluetoothA2DP]
            )
            try session.setActive(true)
            if !audioEngine.isRunning { try audioEngine.start() }
            audioPlayer.pan = direction.pan
            audioPlayer.volume = Float(min(max(volume * (0.5 + urgency * 0.5), 0), 1))
            audioPlayer.stop()
            audioPlayer.scheduleBuffer(audioBuffer, at: nil, options: [], completionHandler: nil)
            audioPlayer.play()
        } catch {
            // Audio failures are surfaced by session quality elsewhere; never block haptics.
        }
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
}
