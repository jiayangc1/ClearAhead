import Foundation

struct AudioCueProfile {
    let startFrequency: Double
    let endFrequency: Double
    let pulseCount: Int
    let pulseDuration: TimeInterval
    let pulseGap: TimeInterval
    let pan: Float
    let gain: Float

    init(event: CASpatialEvent, configuration: CAFeedbackConfiguration) {
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

        let urgency = min(max(event.urgency, 0), 1)
        if urgency >= 0.75 {
            pulseCount = 3
        } else if urgency >= 0.4 {
            pulseCount = 2
        } else {
            pulseCount = 1
        }
        pulseDuration = 0.075 - urgency * 0.02
        pulseGap = 0.18 - urgency * 0.11
        pan = event.direction.pan
        gain = Float(min(max(configuration.audioVolume * (0.72 + urgency * 0.28), 0), 1))
    }
}
