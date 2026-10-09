import Foundation

final class EventPrioritizer {
    private(set) var hasActiveEvent = false
    private var lastAnnouncedId: String?
    private var lastAnnouncedRisk: CollisionRisk = .none
    private var lastAnnouncedProximity: Proximity = .unknown
    private var lastAnnouncedMotionState: MotionState = .stationary
    private var lastAnnouncedUrgency = 0.0
    private var lastEmissionTime: TimeInterval = 0
    private var absenceStartedAt: TimeInterval?
    private var retainedEvent: SpatialEvent?

    func reset() {
        lastAnnouncedId = nil
        lastAnnouncedRisk = .none
        lastAnnouncedProximity = .unknown
        lastAnnouncedMotionState = .stationary
        lastAnnouncedUrgency = 0
        lastEmissionTime = 0
        absenceStartedAt = nil
        retainedEvent = nil
        hasActiveEvent = false
    }

    func select(
        from events: [SpatialEvent],
        configuration: FeedbackConfiguration,
        now: TimeInterval
    ) -> SpatialEvent? {
        let minimumConfidence = 0.42 + (1 - configuration.sensitivity) * 0.24
        let rankedEvents = events.compactMap { candidate -> SpatialEvent? in
            // Scene tones use every selected source; this priority remains for speech and the status card.
            guard candidate.confidence >= minimumConfidence else {
                return nil
            }
            if candidate.collisionRisk == .none,
               let distance = candidate.approximateDistanceMeters,
               distance > configuration.warningDistanceMeters { return nil }
            if candidate.id == "depth:path", let box = candidate.box,
               events.contains(where: { named in
                   guard named.id != candidate.id, named.collisionRisk >= candidate.collisionRisk,
                         named.confidence >= minimumConfidence, let namedBox = named.box else { return false }
                   let intersection = box.intersection(namedBox)
                   guard !intersection.isNull else { return false }
                   let smallerArea = min(box.width * box.height, namedBox.width * namedBox.height)
                   return intersection.width * intersection.height / max(smallerArea, 0.001) >= 0.6
               }) {
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
            if absenceStartedAt == nil { absenceStartedAt = now }
            if now - (absenceStartedAt ?? now) >= 2 { lastAnnouncedId = nil }
            return nil
        }
        absenceStartedAt = nil
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

        return highestPriorityEvent
    }

    func shouldAnnounce(_ event: SpatialEvent?, now: TimeInterval) -> Bool {
        guard let event else { return false }
        let newHazard = event.id != lastAnnouncedId
        let higherRisk = event.collisionRisk > lastAnnouncedRisk
        let closer = proximityRank(event.proximity) > proximityRank(lastAnnouncedProximity)
        let becameApproaching = event.motionState == .approaching && lastAnnouncedMotionState != .approaching
        let moreUrgent = event.urgency >= lastAnnouncedUrgency + 0.2
        guard newHazard || higherRisk || closer || becameApproaching || moreUrgent else { return false }
        guard higherRisk || now - lastEmissionTime >= (event.collisionRisk == .imminent ? 0.5 : 1.2) else { return false }
        lastAnnouncedId = event.id
        lastAnnouncedRisk = event.collisionRisk
        lastAnnouncedProximity = event.proximity
        lastAnnouncedMotionState = event.motionState
        lastAnnouncedUrgency = event.urgency
        lastEmissionTime = now
        return true
    }

    private func proximityRank(_ proximity: Proximity) -> Int {
        switch proximity {
        case .unknown: return 0
        case .far: return 1
        case .medium: return 2
        case .near: return 3
        }
    }
}
