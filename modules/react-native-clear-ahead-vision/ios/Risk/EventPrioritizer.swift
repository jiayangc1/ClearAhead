import Foundation

final class EventPrioritizer {
    private(set) var hasActiveEvent = false
    private var lastEventKey: String?
    private var lastEmissionTime: TimeInterval = 0
    private var retainedEvent: SpatialEvent?

    func reset() {
        lastEventKey = nil
        lastEmissionTime = 0
        retainedEvent = nil
        hasActiveEvent = false
    }

    func select(
        from events: [SpatialEvent],
        configuration: FeedbackConfiguration,
        now: TimeInterval
    ) -> SpatialEvent? {
        let rankedEvents = events.compactMap { candidate -> SpatialEvent? in
            guard candidate.confidence >= 0.42 + (1 - configuration.sensitivity) * 0.24 else {
                return nil
            }
            if let distance = candidate.approximateDistanceMeters,
               distance > configuration.warningDistanceMeters {
                return nil
            }

            let proximityScore: Double
            if let distance = candidate.approximateDistanceMeters {
                proximityScore = 1 - min(distance / configuration.warningDistanceMeters, 1)
            } else {
                switch candidate.proximity {
                case .near: proximityScore = 0.9
                case .medium: proximityScore = 0.55
                case .far: proximityScore = 0.25
                case .unknown: proximityScore = 0.18
                }
            }
            let approachScore = min(candidate.approachSpeed / 2.5, 1)
            let collisionScore: Double
            switch candidate.collisionRisk {
            case .none: collisionScore = 0
            case .caution: collisionScore = 0.32
            case .imminent: collisionScore = 0.55
            }
            let centerBias = candidate.direction == .center ? 0.13 : 0
            var scoredEvent = candidate
            scoredEvent.urgency = min(
                proximityScore * 0.47
                    + approachScore * 0.18
                    + collisionScore
                    + candidate.kind.risk * 0.15
                    + candidate.confidence * 0.07
                    + centerBias
                    + configuration.sensitivity * 0.1,
                1
            )
            return scoredEvent
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

        guard var highestPriorityEvent = rankedEvents.first else {
            retainedEvent = nil
            hasActiveEvent = false
            return nil
        }
        hasActiveEvent = true

        if let retainedEvent,
           let retainedCandidate = rankedEvents.first(where: {
               $0.id == retainedEvent.id && $0.collisionRisk == retainedEvent.collisionRisk
           }),
           retainedCandidate.urgency > highestPriorityEvent.urgency - 0.08 {
            // Retain the selection, not last frame's stale distance, box, or timestamp.
            highestPriorityEvent = retainedCandidate
        }
        retainedEvent = highestPriorityEvent

        let key = "\(highestPriorityEvent.kind.rawValue):\(highestPriorityEvent.direction.rawValue)"
        let minimumCooldown = max(0.32, 1.35 - configuration.feedbackFrequency)
        let urgentCooldown: TimeInterval
        switch highestPriorityEvent.collisionRisk {
        case .imminent: urgentCooldown = 0.22
        case .caution: urgentCooldown = 0.34
        case .none: urgentCooldown = highestPriorityEvent.urgency >= 0.78 ? 0.34 : minimumCooldown
        }
        guard key != lastEventKey || now - lastEmissionTime >= urgentCooldown else {
            return nil
        }
        lastEventKey = key
        lastEmissionTime = now
        return highestPriorityEvent
    }
}
