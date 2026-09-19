import Foundation

struct CAObjectDetection {
    let kind: CAEventKind
    let label: String
    let box: CGRect
    let distanceMeters: Double?
    let confidence: Double

    init(kind: CAEventKind, label: String? = nil, box: CGRect, distanceMeters: Double?, confidence: Double) {
        self.kind = kind
        self.label = label ?? kind.rawValue
        self.box = box
        self.distanceMeters = distanceMeters
        self.confidence = confidence
    }
}

final class CollisionTracker {
    private final class Track {
        let id: String
        let kind: CAEventKind
        let label: String
        var box: CGRect
        var distanceMeters: Double?
        var confidence: Double
        var lateralVelocity = 0.0
        var scaleRate = 0.0
        var signedClosingSpeed = 0.0
        var observations = 1
        var lastSeen: TimeInterval
        var collisionRisk: CACollisionRisk = .none
        var lastCollisionEvidence: TimeInterval = 0

        init(id: String, detection: CAObjectDetection, now: TimeInterval) {
            self.id = id
            kind = detection.kind
            label = detection.label
            box = detection.box
            distanceMeters = detection.distanceMeters
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
        detections: [CAObjectDetection],
        now: TimeInterval,
        configuration: CAFeedbackConfiguration,
        rotationRate: Double
    ) -> [CASpatialEvent] {
        tracks.removeAll { now - $0.lastSeen > 0.8 }
        var unmatched = Set(tracks.indices)
        var updated: [Track] = []

        for detection in detections.sorted(by: { $0.confidence > $1.confidence }) {
            let match = unmatched
                .filter { tracks[$0].label == detection.label }
                .map { index in (index, associationCost(track: tracks[index], detection: detection, now: now)) }
                .filter { $0.1 < 0.72 }
                .min { $0.1 < $1.1 }

            let track: Track
            if let match {
                track = tracks[match.0]
                unmatched.remove(match.0)
                apply(detection, to: track, now: now)
            } else {
                track = Track(id: "track-\(nextIdentifier)", detection: detection, now: now)
                nextIdentifier += 1
                tracks.append(track)
            }
            updated.append(track)
        }

        return updated.map {
            event(for: $0, now: now, configuration: configuration, rotationRate: rotationRate)
        }
    }

    private func associationCost(
        track: Track,
        detection: CAObjectDetection,
        now: TimeInterval
    ) -> Double {
        let elapsed = min(max(now - track.lastSeen, 0), 0.8)
        let predictedCenter = Double(track.box.midX) + track.lateralVelocity * elapsed
        let centerDistance = abs(predictedCenter - Double(detection.box.midX))
        let overlap = intersectionOverUnion(track.box, detection.box)
        let scaleDifference = abs(log(max(Double(detection.box.height), 0.02) / max(Double(track.box.height), 0.02)))
        return (1 - overlap) * 0.5 + min(centerDistance / 0.35, 1) * 0.35 + min(scaleDifference, 1) * 0.15
    }

    private func apply(_ detection: CAObjectDetection, to track: Track, now: TimeInterval) {
        let elapsed = max(now - track.lastSeen, 0.04)
        let alpha = 0.4
        let observedLateralVelocity = (Double(detection.box.midX) - Double(track.box.midX)) / elapsed
        let observedScaleRate = log(max(Double(detection.box.height), 0.02) / max(Double(track.box.height), 0.02)) / elapsed
        track.lateralVelocity = mix(track.lateralVelocity, observedLateralVelocity, alpha: alpha)
        track.scaleRate = mix(track.scaleRate, observedScaleRate, alpha: alpha)

        if let previousDistance = track.distanceMeters, let distance = detection.distanceMeters {
            let observedClosingSpeed = (previousDistance - distance) / elapsed
            track.signedClosingSpeed = mix(track.signedClosingSpeed, observedClosingSpeed, alpha: alpha)
            track.distanceMeters = mix(previousDistance, distance, alpha: alpha)
        } else {
            track.distanceMeters = detection.distanceMeters
        }

        track.box = interpolate(track.box, detection.box, alpha: alpha)
        track.confidence = mix(track.confidence, detection.confidence, alpha: alpha)
        track.observations += 1
        track.lastSeen = now
    }

    private func event(
        for track: Track,
        now: TimeInterval,
        configuration: CAFeedbackConfiguration,
        rotationRate: Double
    ) -> CASpatialEvent {
        let approachSpeed = max(0, track.signedClosingSpeed)
        var timeCandidates: [Double] = []
        if let distance = track.distanceMeters, approachSpeed > 0.15 {
            timeCandidates.append(distance / approachSpeed)
        }
        if track.scaleRate > 0.12 {
            timeCandidates.append(1 / track.scaleRate)
        }
        let timeToCollision = timeCandidates.filter { $0.isFinite && $0 > 0 }.min()
        let horizon = min(timeToCollision ?? 3, 3)
        let projectedCenter = Double(track.box.midX) + track.lateralVelocity * horizon
        let projectedWidth = min(Double(track.box.width) * exp(max(track.scaleRate, 0) * horizon), 1)
        let corridor = configuration.mountingMode == "chest" ? 0.34...0.66 : 0.30...0.70
        let projectedRange = (projectedCenter - projectedWidth / 2)...(projectedCenter + projectedWidth / 2)
        let corridorOverlap = overlapFraction(projectedRange, corridor)
        let cameraStable = rotationRate < 0.9
        let observationConfidence = min(Double(track.observations) / 3, 1)
        let trajectoryConfidence = min(track.confidence * observationConfidence * (cameraStable ? 1 : 0.25), 1)

        let motionState: CAMotionState
        if approachSpeed > 0.15 || track.scaleRate > 0.12 {
            motionState = .approaching
        } else if track.signedClosingSpeed < -0.15 || track.scaleRate < -0.12 {
            motionState = .receding
        } else if abs(track.lateralVelocity) > 0.08 && corridorOverlap > 0.25 {
            motionState = .crossing
        } else {
            motionState = .stationary
        }

        let minimumConfidence = 0.75 - configuration.sensitivity * 0.15
        var calculatedRisk: CACollisionRisk = .none
        if cameraStable,
           track.observations >= 3,
           trajectoryConfidence >= minimumConfidence,
           corridorOverlap >= 0.25 {
            if let timeToCollision, timeToCollision <= 1.5 {
                calculatedRisk = .imminent
            } else if let timeToCollision, timeToCollision <= 3 {
                calculatedRisk = .caution
            } else if isPersistentlyNear(track, corridor: corridor) {
                calculatedRisk = .caution
            }
        }

        if calculatedRisk > track.collisionRisk {
            track.collisionRisk = calculatedRisk
            track.lastCollisionEvidence = now
        } else if calculatedRisk == track.collisionRisk {
            if calculatedRisk != .none {
                track.lastCollisionEvidence = now
            }
        } else if now - track.lastCollisionEvidence > 0.55 {
            track.collisionRisk = calculatedRisk
            if calculatedRisk != .none {
                track.lastCollisionEvidence = now
            }
        }

        return CASpatialEvent(
            id: track.id,
            kind: track.kind,
            label: track.label,
            direction: CADirection.from(horizontalMidpoint: track.box.midX),
            proximity: CAProximity.from(distance: track.distanceMeters),
            approximateDistanceMeters: track.distanceMeters,
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
        if let distance = track.distanceMeters, distance <= 1.25 { return true }
        return track.box.height >= 0.55
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

    private func interpolate(_ lhs: CGRect, _ rhs: CGRect, alpha: Double) -> CGRect {
        CGRect(
            x: mix(Double(lhs.minX), Double(rhs.minX), alpha: alpha),
            y: mix(Double(lhs.minY), Double(rhs.minY), alpha: alpha),
            width: mix(Double(lhs.width), Double(rhs.width), alpha: alpha),
            height: mix(Double(lhs.height), Double(rhs.height), alpha: alpha)
        )
    }

    private func mix(_ lhs: Double, _ rhs: Double, alpha: Double) -> Double {
        lhs + (rhs - lhs) * alpha
    }
}
