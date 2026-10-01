import Foundation

/// The sound character of a cue. Each kind of hazard keeps its own voice so it
/// can be told apart without speech.
enum CueTimbre: Equatable {
    /// Soft rounded tone: a person.
    case voice
    /// Bright short tick: a wall or unlabeled obstacle.
    case click
    /// Low hollow buzz: a vehicle.
    case buzz
    /// Woody knock: furniture.
    case knock
    /// Deep thump: something low on the ground.
    case thud

    /// Pitch of the cue at the edge of the warning range.
    var register: Double {
        switch self {
        case .voice: 523.25
        case .click: 440
        case .knock: 329.63
        case .buzz: 196
        case .thud: 146.83
        }
    }

    /// Frequency ratio and level of each partial.
    var partials: [(ratio: Double, level: Double)] {
        switch self {
        case .voice: [(1, 1), (2, 0.35), (3, 0.12)]
        case .click: [(1, 1), (2, 0.5), (3, 0.33), (4, 0.2)]
        case .knock: [(1, 1), (2.76, 0.55), (5.4, 0.2)]
        case .buzz: [(1, 1), (3, 0.5), (5, 0.3), (7, 0.2)]
        case .thud: [(1, 1), (1.5, 0.4)]
        }
    }

    /// Struck sounds start instantly and ring out; the rest swell and fade.
    var percussive: Bool {
        switch self {
        case .click, .knock, .thud: true
        case .voice, .buzz: false
        }
    }

    init(event: SpatialEvent) {
        if event.id.hasPrefix("depth:ground") {
            self = .thud
            return
        }
        switch event.kind {
        case .person: self = .voice
        case .vehicle: self = .buzz
        case .furniture: self = .knock
        case .obstacle: self = .click
        }
    }
}

/// How one hazard sounds. Every property of the event has its own audible
/// dimension:
///
/// - where it is: stereo position, or the pitch contour on a mono speaker
/// - how close: pitch (up to an octave higher), loudness and repetition rate
/// - what it is: timbre and register
/// - how dangerous: pulses per burst, and a rough edge when imminent
/// - how it moves on headphones: rising pitch when approaching, falling when
///   receding, wavering when crossing
struct AudioCueProfile {
    let timbre: CueTimbre
    let startFrequency: Double
    let endFrequency: Double
    /// Pitch waver as a fraction of the frequency.
    let vibratoDepth: Double
    /// Depth of the rough amplitude flutter that marks an imminent collision.
    let roughness: Double
    let pulseCount: Int
    let pulseDuration: TimeInterval
    let pulseGap: TimeInterval
    /// Silence before the burst repeats while the hazard remains.
    let repeatRest: TimeInterval
    let pan: Float
    let gain: Float

    var duration: TimeInterval {
        Double(pulseCount) * pulseDuration + Double(pulseCount - 1) * pulseGap
    }

    init(event: SpatialEvent, configuration: FeedbackConfiguration, stereo: Bool = true) {
        let distanceCloseness: Double
        if let distance = event.approximateDistanceMeters {
            distanceCloseness = 1 - min(max(distance / configuration.warningDistanceMeters, 0), 1)
        } else {
            switch event.proximity {
            case .near: distanceCloseness = 0.88
            case .medium: distanceCloseness = 0.56
            case .far: distanceCloseness = 0.24
            case .unknown: distanceCloseness = 0.16
            }
        }
        // A fast approach from far away is as pressing as something already near.
        let timeCloseness = event.timeToCollisionSeconds.map { 1 - min(max($0 / 3, 0), 1) } ?? 0
        let closeness = max(distanceCloseness, timeCloseness)

        timbre = CueTimbre(event: event)
        let pitch = timbre.register * pow(2, closeness)
        if stereo {
            switch event.motionState {
            case .approaching:
                startFrequency = pitch
                endFrequency = pitch * 1.26
            case .receding:
                startFrequency = pitch
                endFrequency = pitch * 0.8
            case .stationary, .crossing:
                startFrequency = pitch
                endFrequency = pitch
            }
        } else {
            // One speaker cannot place a sound, so the contour carries direction.
            switch event.direction {
            case .left:
                startFrequency = pitch * 1.12
                endFrequency = pitch * 0.88
            case .center:
                startFrequency = pitch
                endFrequency = pitch
            case .right:
                startFrequency = pitch * 0.88
                endFrequency = pitch * 1.12
            }
        }
        vibratoDepth = event.motionState == .crossing ? 0.05 : 0

        switch event.collisionRisk {
        case .imminent:
            pulseCount = 3
            pulseDuration = 0.05
            pulseGap = 0.04
            roughness = 0.55
            repeatRest = 0.22 - closeness * 0.16
        case .caution:
            pulseCount = 2
            pulseDuration = 0.065
            pulseGap = 0.06
            roughness = 0
            repeatRest = 0.9 - closeness * 0.68
        case .none:
            pulseCount = 1
            pulseDuration = 0.08
            pulseGap = 0
            roughness = 0
            repeatRest = 1.2 - closeness * 0.7
        }

        pan = stereo ? event.pan : 0
        let urgency = min(max(event.urgency, 0), 1)
        let intensity = max(closeness, urgency, event.collisionRisk == .imminent ? 0.8 : 0)
        // Hazards straight ahead are the loudest; uncertain ones are softer.
        let centering = 1 - 0.18 * Double(abs(event.pan))
        let certainty = 0.8 + 0.2 * min(max(event.confidence, 0), 1)
        gain = Float(min(max(
            configuration.audioVolume * (0.3 + 0.7 * intensity) * centering * certainty, 0
        ), 1))
    }
}

enum AudioCueRenderer {
    /// Largest delay between the ears, for a sound fully to one side.
    private static let maximumInterauralDelay = 0.00063

    /// Renders one burst as stereo samples. The far ear is both quieter and
    /// slightly late, which is what places a sound outside the head on headphones.
    static func render(_ profile: AudioCueProfile, sampleRate: Double) -> (left: [Float], right: [Float]) {
        let pulseFrames = max(Int(profile.pulseDuration * sampleRate), 1)
        let gapFrames = Int(profile.pulseGap * sampleRate)
        let pan = Double(min(max(profile.pan, -1), 1)) * 0.9
        let delayFrames = Int(abs(pan) * maximumInterauralDelay * sampleRate)
        let frameCount = profile.pulseCount * pulseFrames + (profile.pulseCount - 1) * gapFrames + delayFrames
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)

        let angle = (pan + 1) / 2 * Double.pi / 2
        let leftGain = cos(angle) * Double(profile.gain)
        let rightGain = sin(angle) * Double(profile.gain)
        let leftDelay = pan > 0 ? delayFrames : 0
        let rightDelay = pan < 0 ? delayFrames : 0

        let partials = profile.timbre.partials
        let level = 0.5 / partials.reduce(0) { $0 + $1.level }
        let edgeFrames = max(Int(0.003 * sampleRate), 1)
        for pulse in 0..<profile.pulseCount {
            let pulseStart = pulse * (pulseFrames + gapFrames)
            var phase = 0.0
            for frame in 0..<pulseFrames {
                let progress = Double(frame) / Double(max(pulseFrames - 1, 1))
                let elapsed = Double(frame) / sampleRate
                let vibrato = 1 + profile.vibratoDepth * sin(2 * Double.pi * 14 * elapsed)
                let frequency = (profile.startFrequency
                    + (profile.endFrequency - profile.startFrequency) * progress) * vibrato
                phase += 2 * Double.pi * frequency / sampleRate

                var envelope: Double
                if profile.timbre.percussive {
                    let attack = min(Double(frame) / Double(edgeFrames), 1)
                    let release = min(Double(pulseFrames - 1 - frame) / Double(edgeFrames), 1)
                    envelope = attack * release * exp(-5 * progress)
                } else {
                    envelope = pow(sin(Double.pi * progress), 2)
                }
                envelope *= 1 - profile.roughness * 0.5 * (1 - cos(2 * Double.pi * 45 * elapsed))

                var sample = 0.0
                for partial in partials {
                    sample += partial.level * sin(phase * partial.ratio)
                }
                sample *= envelope * level
                left[pulseStart + frame + leftDelay] = Float(sample * leftGain)
                right[pulseStart + frame + rightDelay] = Float(sample * rightGain)
            }
        }
        return (left, right)
    }
}
