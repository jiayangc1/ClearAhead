import Foundation

struct DepthMeasurement {
    let distanceMeters: Double
    let timestamp: TimeInterval
}

struct ObjectDetection {
    let kind: EventKind
    let label: String
    let box: CGRect
    let depth: DepthMeasurement?
    let confidence: Double

    init(kind: EventKind, label: String? = nil, box: CGRect, depth: DepthMeasurement?, confidence: Double) {
        self.kind = kind
        self.label = label ?? kind.rawValue
        self.box = box
        self.depth = depth
        self.confidence = confidence
    }
}

final class CollisionTracker {
    private final class Track {
        let id: String
        let kind: EventKind
        let label: String
        var box: CGRect
        var distanceMeters: Double?
        var lastDepthDistance: Double?
        var lastDepthTime: TimeInterval?
        var confidence: Double
        var lateralVelocity = 0.0
        var signedClosingSpeed = 0.0
        var observations = 1
        var lastSeen: TimeInterval
        var collisionRisk: CollisionRisk = .none
        var lastCollisionEvidence: TimeInterval = 0

        init(id: String, detection: ObjectDetection, now: TimeInterval) {
            self.id = id
            kind = detection.kind
            label = detection.label
            box = detection.box
            distanceMeters = detection.depth?.distanceMeters
            lastDepthDistance = detection.depth?.distanceMeters
            lastDepthTime = detection.depth?.timestamp
            confidence = detection.confidence
            lastSeen = now
        }
    }

    private var tracks: [Track] = []
    private var nextIdentifier = 1

    func reset() {
        tracks.removeAll()
        nextIdentifier = 1
    }

    func update(
        detections: [ObjectDetection],
        now: TimeInterval,
        configuration: FeedbackConfiguration,
        rotationRate: Double
    ) -> [SpatialEvent] {
        tracks.removeAll { now - $0.lastSeen > 0.8 }
        var unmatched = Set(tracks.indices)
        var updatedTracks: [Track] = []

        for detection in detections.sorted(by: { $0.confidence > $1.confidence }) {
            let closestMatch = unmatched
                .filter { tracks[$0].label == detection.label }
                .map { index in (index, associationCost(track: tracks[index], detection: detection, now: now)) }
                .filter { $0.1 < 0.72 }
                .min { $0.1 < $1.1 }

            let track: Track
            if let closestMatch {
                track = tracks[closestMatch.0]
                unmatched.remove(closestMatch.0)
                apply(detection, to: track, now: now)
            } else {
                track = Track(id: "track-\(nextIdentifier)", detection: detection, now: now)
                nextIdentifier += 1
                tracks.append(track)
            }
            updatedTracks.append(track)
        }

        return updatedTracks.map {
            event(for: $0, now: now, configuration: configuration, rotationRate: rotationRate)
        }
    }

    private func associationCost(
        track: Track,
        detection: ObjectDetection,
        now: TimeInterval
    ) -> Double {
        let elapsedTime = min(max(now - track.lastSeen, 0), 0.8)
        let predictedCenter = Double(track.box.midX) + track.lateralVelocity * elapsedTime
        let centerDistance = abs(predictedCenter - Double(detection.box.midX))
        let overlap = intersectionOverUnion(track.box, detection.box)
        let scaleDifference = abs(log(max(Double(detection.box.height), 0.02) / max(Double(track.box.height), 0.02)))
        return (1 - overlap) * 0.5 + min(centerDistance / 0.35, 1) * 0.35 + min(scaleDifference, 1) * 0.15
    }

    private func apply(_ detection: ObjectDetection, to track: Track, now: TimeInterval) {
        let elapsedTime = max(now - track.lastSeen, 0.04)
        let smoothingFactor = 0.4
        let observedLateralVelocity = (Double(detection.box.midX) - Double(track.box.midX)) / elapsedTime
        track.lateralVelocity = mix(track.lateralVelocity, observedLateralVelocity, smoothingFactor: smoothingFactor)

        if let depth = detection.depth,
           depth.timestamp > (track.lastDepthTime ?? -Double.infinity) {
            if let previousTime = track.lastDepthTime,
               depth.timestamp - previousTime > 0.8 {
                track.signedClosingSpeed = 0
                track.collisionRisk = .none
            } else if let previousDistance = track.lastDepthDistance,
               let previousTime = track.lastDepthTime,
               depth.timestamp - previousTime >= 0.04 {
                let observedClosingSpeed = (previousDistance - depth.distanceMeters) / (depth.timestamp - previousTime)
                track.signedClosingSpeed = mix(track.signedClosingSpeed, observedClosingSpeed, smoothingFactor: smoothingFactor)
            }
            track.distanceMeters = depth.distanceMeters
            track.lastDepthDistance = depth.distanceMeters
            track.lastDepthTime = depth.timestamp
        }

        track.box = interpolate(track.box, detection.box, smoothingFactor: smoothingFactor)
        track.confidence = mix(track.confidence, detection.confidence, smoothingFactor: smoothingFactor)
        track.observations += 1
        track.lastSeen = now
    }

    private func event(
        for track: Track,
        now: TimeInterval,
        configuration: FeedbackConfiguration,
        rotationRate: Double
    ) -> SpatialEvent {
        let depthIsFresh = track.lastDepthTime.map { now - $0 <= 0.5 } ?? false
        if !depthIsFresh { track.collisionRisk = .none }
        let distance = depthIsFresh ? track.distanceMeters : nil
        let approachSpeed = depthIsFresh ? max(0, track.signedClosingSpeed) : 0
        let timeToCollision = distance.flatMap {
            approachSpeed > 0.15 ? $0 / approachSpeed : nil
        }
        let horizon = min(timeToCollision ?? 3, 3)
        let projectedCenter = Double(track.box.midX) + track.lateralVelocity * horizon
        let projectedWidth = Double(track.box.width)
        let corridor = configuration.mountingMode == "chest" ? 0.34...0.66 : 0.30...0.70
        let projectedRange = (projectedCenter - projectedWidth / 2)...(projectedCenter + projectedWidth / 2)
        let corridorOverlap = overlapFraction(projectedRange, corridor)
        let cameraStable = rotationRate < 0.9
        let observationConfidence = min(Double(track.observations) / 3, 1)
        let trajectoryConfidence = min(track.confidence * observationConfidence * (cameraStable ? 1 : 0.25), 1)

        let motionState: MotionState
        if approachSpeed > 0.15 {
            motionState = .approaching
        } else if depthIsFresh && track.signedClosingSpeed < -0.15 {
            motionState = .receding
        } else if abs(track.lateralVelocity) > 0.08 && corridorOverlap > 0.25 {
            motionState = .crossing
        } else {
            motionState = .stationary
        }

        let minimumConfidence = 0.75 - configuration.sensitivity * 0.15
        var detectedRisk: CollisionRisk = .none
        if cameraStable,
           track.observations >= 3,
           trajectoryConfidence >= minimumConfidence,
           corridorOverlap >= 0.25,
           distance != nil {
            if let timeToCollision, timeToCollision <= 1.5 {
                detectedRisk = .imminent
            } else if let timeToCollision, timeToCollision <= 3 {
                detectedRisk = .caution
            } else if isPersistentlyNear(track, corridor: corridor) {
                detectedRisk = .caution
            }
        }

        if detectedRisk > track.collisionRisk {
            track.collisionRisk = detectedRisk
            track.lastCollisionEvidence = now
        } else if detectedRisk == track.collisionRisk {
            if detectedRisk != .none {
                track.lastCollisionEvidence = now
            }
        } else if now - track.lastCollisionEvidence > 0.55 {
            track.collisionRisk = detectedRisk
            if detectedRisk != .none {
                track.lastCollisionEvidence = now
            }
        }

        return SpatialEvent(
            id: track.id,
            kind: track.kind,
            label: track.label,
            direction: Direction.from(horizontalMidpoint: track.box.midX),
            proximity: Proximity.from(distance: distance),
            approximateDistanceMeters: distance,
            approachSpeed: approachSpeed,
            motionState: motionState,
            collisionRisk: track.collisionRisk,
            timeToCollisionSeconds: timeToCollision,
            trajectoryConfidence: trajectoryConfidence,
            confidence: track.confidence,
            urgency: 0,
            timestamp: now,
            box: track.box
        )
    }

    private func isPersistentlyNear(_ track: Track, corridor: ClosedRange<Double>) -> Bool {
        let center = Double(track.box.midX)
        guard corridor.contains(center) else { return false }
        return track.distanceMeters.map { $0 <= 1.25 } ?? false
    }

    private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = Double(intersection.width * intersection.height)
        let unionArea = Double(lhs.width * lhs.height + rhs.width * rhs.height) - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }

    private func overlapFraction(_ lhs: ClosedRange<Double>, _ rhs: ClosedRange<Double>) -> Double {
        let overlap = max(0, min(lhs.upperBound, rhs.upperBound) - max(lhs.lowerBound, rhs.lowerBound))
        return overlap / max(min(lhs.upperBound - lhs.lowerBound, rhs.upperBound - rhs.lowerBound), 0.001)
    }

    private func interpolate(_ lhs: CGRect, _ rhs: CGRect, smoothingFactor: Double) -> CGRect {
        CGRect(
            x: mix(Double(lhs.minX), Double(rhs.minX), smoothingFactor: smoothingFactor),
            y: mix(Double(lhs.minY), Double(rhs.minY), smoothingFactor: smoothingFactor),
            width: mix(Double(lhs.width), Double(rhs.width), smoothingFactor: smoothingFactor),
            height: mix(Double(lhs.height), Double(rhs.height), smoothingFactor: smoothingFactor)
        )
    }

    private func mix(_ lhs: Double, _ rhs: Double, smoothingFactor: Double) -> Double {
        lhs + (rhs - lhs) * smoothingFactor
    }
}
