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
        let rankedEvents = events.compactMap { candidate -> SpatialEvent? in
            // Scene tones use every selected source; this priority remains for speech and the status card.
            guard candidate.confidence >= configuration.minimumConfidence(for: candidate.kind) else {
                return nil
            }
            if candidate.collisionRisk == .none,
               let distance = candidate.approximateDistanceMeters,
               distance > configuration.warningDistanceMeters { return nil }
            if candidate.id == "depth:path", let box = candidate.box,
               events.contains(where: { named in
                   guard named.id != candidate.id, named.collisionRisk >= candidate.collisionRisk,
                         named.confidence >= configuration.minimumConfidence(for: named.kind), let namedBox = named.box else { return false }
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
           retainedCandidate.collisionRisk == highestPriorityEvent.collisionRisk,
           retainedCandidate.urgency > highestPriorityEvent.urgency - 0.08 {
            // Urgency saturates at 1, so it cannot be trusted to rank across risk tiers.
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

/// Decides what is worth saying aloud. It keys on what the listener hears,
/// the name of the thing, rather than on track ids: ids change whenever
/// tracking hiccups, and each new id used to be announced again.
final class SpeechGate {
    struct Utterance {
        let event: SpatialEvent
        let text: String
        let key: String
        let priority: Double
        let interrupts: Bool
        let cooldown: TimeInterval
    }

    private struct Spoken {
        let time: TimeInterval
        let risk: CollisionRisk
        let direction: Direction
        let distance: Double?
    }

    private var spoken: [String: Spoken] = [:]
    private var lastSpoken = -Double.infinity

    func reset() {
        spoken.removeAll()
        lastSpoken = -.infinity
    }

    /// The most pressing event that has something new to say, if any.
    func next(from events: [SpatialEvent], configuration: FeedbackConfiguration, now: TimeInterval) -> Utterance? {
        spoken = spoken.filter { now - $0.value.time < 60 }
        let ranked = events.sorted { lhs, rhs in
            if lhs.collisionRisk != rhs.collisionRisk { return lhs.collisionRisk > rhs.collisionRisk }
            return (lhs.approximateDistanceMeters ?? 100) < (rhs.approximateDistanceMeters ?? 100)
        }
        guard let event = ranked.first(where: { isNews($0, configuration: configuration, now: now) }) else {
            return nil
        }
        let name = Self.name(event)
        spoken[name] = Spoken(time: now, risk: event.collisionRisk, direction: event.direction,
                              distance: event.approximateDistanceMeters)
        lastSpoken = now
        return Utterance(
            event: event,
            text: Self.text(for: event),
            key: "\(name)|\(event.collisionRisk.rawValue)",
            priority: event.collisionRisk == .imminent ? 2 : event.collisionRisk == .caution ? 1 : 0.3,
            interrupts: event.collisionRisk == .imminent,
            cooldown: event.collisionRisk == .imminent ? 3 : 5
        )
    }

    private func isNews(_ event: SpatialEvent, configuration: FeedbackConfiguration, now: TimeInterval) -> Bool {
        let previous = spoken[Self.name(event)]
        let since = previous.map { now - $0.time } ?? .infinity
        switch event.collisionRisk {
        case .imminent:
            // A stop is never held back, and repeats only while it still applies.
            return (previous?.risk ?? .none) < .imminent || since >= 4
        case .caution:
            guard now - lastSpoken >= 1.5 else { return false }
            return (previous?.risk ?? .none) < .caution || since >= 10
        case .none:
            guard configuration.spokenCategories.contains(event.kind.rawValue), now - lastSpoken >= 3,
                  let distance = event.approximateDistanceMeters else { return false }
            // By default only what stands in the way is named; scenery to the
            // sides is left to the tones.
            if configuration.speechDetail != "everything" {
                guard event.direction == .center,
                      distance <= min(configuration.warningDistanceMeters, GroundHazardTracker.warningRangeMeters) else { return false }
            }
            guard let previous else { return true }
            if since >= 30 { return true }
            let muchCloser = previous.distance.map { distance <= $0 * 0.6 } ?? false
            return since >= 8 && (event.direction != previous.direction || muchCloser)
        }
    }

    private static func name(_ event: SpatialEvent) -> String {
        let label = event.label ?? event.kind.rawValue
        return label == "surface" ? "obstacle" : label
    }

    static func text(for event: SpatialEvent) -> String {
        let name = name(event)
        let subject = name.prefix(1).uppercased() + name.dropFirst()
        let place = event.direction == .center ? "ahead" : "on your \(event.direction.rawValue)"
        if event.isRemembered {
            return event.collisionRisk == .imminent
                ? "Stop. \(subject) at your feet."
                : "Careful. \(subject) \(place), out of view."
        }
        let distance = event.approximateDistanceMeters.map { ", \(spokenDistance($0))" } ?? ""
        switch event.collisionRisk {
        case .imminent: return "Stop. \(subject) \(place)."
        case .caution: return "Careful. \(subject) \(place)\(distance)."
        case .none: return "\(subject) \(place)\(distance)."
        }
    }

    static func spokenDistance(_ meters: Double) -> String {
        if meters < 0.75 { return "very close" }
        let rounded = Int(meters.rounded())
        return rounded == 1 ? "1 meter" : "\(rounded) meters"
    }
}
