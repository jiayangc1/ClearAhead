import Foundation

final class EventPrioritizer {
    private(set) var hasActiveEvent = false
    private var lastEventKey: String?
    private var lastEmissionTime: TimeInterval = 0
    private var retainedEvent: CASpatialEvent?

    func reset() {
        lastEventKey = nil
        lastEmissionTime = 0
        retainedEvent = nil
        hasActiveEvent = false
    }

    func select(
        from events: [CASpatialEvent],
        configuration: CAFeedbackConfiguration,
        now: TimeInterval
    ) -> CASpatialEvent? {
        let ranked = events.compactMap { candidate -> CASpatialEvent? in
            guard candidate.confidence >= 0.42 + (1 - configuration.sensitivity) * 0.24 else {
                return nil
            }
            if let distance = candidate.approximateDistanceMeters,
               distance > configuration.warningDistanceMeters {
                return nil
            }

            let proximity: Double
            if let distance = candidate.approximateDistanceMeters {
                proximity = 1 - min(distance / configuration.warningDistanceMeters, 1)
            } else {
                switch candidate.proximity {
                case .near: proximity = 0.9
                case .medium: proximity = 0.55
                case .far: proximity = 0.25
                case .unknown: proximity = 0.18
                }
            }
            let approach = min(candidate.approachSpeed / 2.5, 1)
            let collision: Double
            switch candidate.collisionRisk {
            case .none: collision = 0
            case .caution: collision = 0.32
            case .imminent: collision = 0.55
            }
            let centerBias = candidate.direction == .center ? 0.13 : 0
            var ranked = candidate
            ranked.urgency = min(
                proximity * 0.47
                    + approach * 0.18
                    + collision
                    + candidate.kind.risk * 0.15
                    + candidate.confidence * 0.07
                    + centerBias
                    + configuration.sensitivity * 0.1,
                1
            )
            return ranked
        }
        .sorted { lhs, rhs in
            if lhs.collisionRisk != rhs.collisionRisk {
                return lhs.collisionRisk > rhs.collisionRisk
            }
            if lhs.urgency == rhs.urgency {
                return (lhs.approximateDistanceMeters ?? 100) < (rhs.approximateDistanceMeters ?? 100)
            }
            return lhs.urgency > rhs.urgency
        }

        guard var best = ranked.first else {
            retainedEvent = nil
            hasActiveEvent = false
            return nil
        }
        hasActiveEvent = true

        if let retainedEvent,
           retainedEvent.id == best.id,
           retainedEvent.collisionRisk == best.collisionRisk,
           retainedEvent.urgency > best.urgency - 0.08 {
            best = retainedEvent
        }
        retainedEvent = best

        let key = "\(best.kind.rawValue):\(best.direction.rawValue)"
        let minimumCooldown = max(0.32, 1.35 - configuration.feedbackFrequency)
        let urgentCooldown: TimeInterval
        switch best.collisionRisk {
        case .imminent: urgentCooldown = 0.22
        case .caution: urgentCooldown = 0.34
        case .none: urgentCooldown = best.urgency >= 0.78 ? 0.34 : minimumCooldown
        }
        guard key != lastEventKey || now - lastEmissionTime >= urgentCooldown else {
            return nil
        }
        lastEventKey = key
        lastEmissionTime = now
        return best
    }
}
