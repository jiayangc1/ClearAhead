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
        var label: String
        var box: CGRect
        var lastObservedBox: CGRect
        var distanceMeters: Double?
        var lastDepthDistance: Double?
        var lastDepthTime: TimeInterval?
        var confidence: Double
        var lateralVelocity = 0.0
        var verticalVelocity = 0.0
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
            lastObservedBox = detection.box
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
        var updatedTracks: [Track] = []
        let observations = Array(detections.sorted { $0.confidence > $1.confidence }.prefix(32))
        let existingCount = tracks.count
        let costs = observations.map { detection in
            tracks.map { track in
                track.kind == detection.kind ? associationCost(track: track, detection: detection, now: now) : 1000
            } + [Double](repeating: 0.72, count: observations.count)
        }
        let assignment = minimumCostAssignment(costs)
        for (index, detection) in observations.enumerated() {
            let column = assignment[index]
            let track: Track
            if column < existingCount, costs[index][column] < 0.72 {
                track = tracks[column]
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
        let predictedBox = track.lastObservedBox.offsetBy(dx: track.lateralVelocity * elapsedTime,
                                                        dy: track.verticalVelocity * elapsedTime)
        let centerDistance = hypot(Double(predictedBox.midX - detection.box.midX), Double(predictedBox.midY - detection.box.midY))
        let overlap = intersectionOverUnion(predictedBox, detection.box)
        let scaleDifference = abs(log(max(Double(detection.box.height), 0.02) / max(Double(track.box.height), 0.02)))
        let predictedDepth = track.distanceMeters.map { max(0, $0 - track.signedClosingSpeed * elapsedTime) }
        let depthDifference: Double
        if let predictedDepth, let depth = detection.depth {
            depthDifference = min(abs(predictedDepth - depth.distanceMeters) / max(predictedDepth, 1), 1)
        } else { depthDifference = 0 }
        return (1 - overlap) * 0.35 + min(centerDistance / 0.35, 1) * 0.35
            + min(scaleDifference, 1) * 0.15 + depthDifference * 0.15
    }

    private func apply(_ detection: ObjectDetection, to track: Track, now: TimeInterval) {
        let elapsedTime = max(now - track.lastSeen, 0.04)
        let smoothingFactor = 0.4
        let observedLateralVelocity = (Double(detection.box.midX) - Double(track.lastObservedBox.midX)) / elapsedTime
        track.lateralVelocity = mix(track.lateralVelocity, observedLateralVelocity, smoothingFactor: smoothingFactor)
        let observedVerticalVelocity = Double(detection.box.midY - track.lastObservedBox.midY) / elapsedTime
        track.verticalVelocity = mix(track.verticalVelocity, observedVerticalVelocity, smoothingFactor: smoothingFactor)

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
        track.lastObservedBox = detection.box
        track.label = detection.label
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
        let currentLeft = Double(track.box.minX)
        let currentRight = Double(track.box.maxX)
        let corridorEntry: Double?
        if track.lateralVelocity > 0.08, currentRight < corridor.lowerBound {
            corridorEntry = (corridor.lowerBound - currentRight) / track.lateralVelocity
        } else if track.lateralVelocity < -0.08, currentLeft > corridor.upperBound {
            corridorEntry = (corridor.upperBound - currentLeft) / track.lateralVelocity
        } else if currentRight >= corridor.lowerBound && currentLeft <= corridor.upperBound {
            corridorEntry = abs(track.lateralVelocity) > 0.08 ? 0 : nil
        } else { corridorEntry = nil }
        let crossesSoon = corridorEntry.map { $0 >= 0 && $0 <= 1.5 } ?? false
        let cameraStable = rotationRate < 0.9
        let observationConfidence = min(Double(track.observations) / 3, 1)
        let trajectoryConfidence = min(track.confidence * observationConfidence * (cameraStable ? 1 : 0.25), 1)

        let motionState: MotionState
        if approachSpeed > 0.15 {
            motionState = .approaching
        } else if depthIsFresh && track.signedClosingSpeed < -0.15 {
            motionState = .receding
        } else if abs(track.lateralVelocity) > 0.08 && (corridorOverlap > 0.25 || crossesSoon) {
            motionState = .crossing
        } else {
            motionState = .stationary
        }

        let minimumConfidence = 0.75 - configuration.sensitivity * 0.15
        var detectedRisk: CollisionRisk = .none
        if cameraStable,
           track.observations >= 3,
           trajectoryConfidence >= minimumConfidence,
           distance != nil {
            if let timeToCollision, timeToCollision <= 1.5, corridorOverlap >= 0.25 {
                detectedRisk = .imminent
            } else if let timeToCollision, timeToCollision <= 3, corridorOverlap >= 0.25 {
                detectedRisk = .caution
            } else if crossesSoon, let distance, distance <= min(configuration.warningDistanceMeters, 3),
                      abs(track.signedClosingSpeed) <= 0.15 {
                // Angular corridor entry supports caution, not a physical TTC.
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

    // Hungarian assignment. Dummy columns allow every detection to remain
    // unmatched without forcing an implausible identity swap.
    private func minimumCostAssignment(_ costs: [[Double]]) -> [Int] {
        let rows = costs.count
        guard rows > 0 else { return [] }
        let columns = costs[0].count
        var rowPotential = [Double](repeating: 0, count: rows + 1)
        var columnPotential = [Double](repeating: 0, count: columns + 1)
        var matchedRow = [Int](repeating: 0, count: columns + 1)
        var previousColumn = [Int](repeating: 0, count: columns + 1)
        for row in 1...rows {
            matchedRow[0] = row
            var column = 0
            var minimum = [Double](repeating: .infinity, count: columns + 1)
            var used = [Bool](repeating: false, count: columns + 1)
            repeat {
                used[column] = true
                let currentRow = matchedRow[column]
                var delta = Double.infinity
                var nextColumn = 0
                for candidate in 1...columns where !used[candidate] {
                    let cost = costs[currentRow - 1][candidate - 1] - rowPotential[currentRow] - columnPotential[candidate]
                    if cost < minimum[candidate] {
                        minimum[candidate] = cost
                        previousColumn[candidate] = column
                    }
                    if minimum[candidate] < delta { delta = minimum[candidate]; nextColumn = candidate }
                }
                for candidate in 0...columns {
                    if used[candidate] {
                        rowPotential[matchedRow[candidate]] += delta
                        columnPotential[candidate] -= delta
                    } else { minimum[candidate] -= delta }
                }
                column = nextColumn
            } while matchedRow[column] != 0
            repeat {
                let previous = previousColumn[column]
                matchedRow[column] = matchedRow[previous]
                column = previous
            } while column != 0
        }
        var result = [Int](repeating: columns, count: rows)
        for column in 1...columns where matchedRow[column] != 0 { result[matchedRow[column] - 1] = column - 1 }
        return result
    }

    private func isPersistentlyNear(_ track: Track, corridor: ClosedRange<Double>) -> Bool {
        let center = Double(track.box.midX)
        guard corridor.contains(center) else { return false }
        // Low objects are trip hazards a few steps before anything would be hit.
        let limit = track.kind == .obstacle ? GroundHazardTracker.warningRangeMeters : 1.25
        return track.distanceMeters.map { $0 <= limit } ?? false
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

/// Turns per-frame ground hazard observations into a cautioned event once the
/// same low obstacle has persisted. A trip hazard needs no closing speed.
struct GroundHazardTracker {
    static let warningRangeMeters = 2.5

    private var previous: PathObstacleObservation?
    private var previousTime: TimeInterval = 0
    private var observations = 0
    private var firstSeen: TimeInterval = 0
    private var identifier = 0

    mutating func reset() { self = GroundHazardTracker() }

    mutating func update(
        _ observation: PathObstacleObservation?,
        now: TimeInterval,
        cameraStable: Bool
    ) -> SpatialEvent? {
        guard let observation else {
            if now - previousTime > 0.8 { previous = nil; observations = 0 }
            return nil
        }
        if let previous, now - previousTime <= 0.8,
           abs(previous.box.midX - observation.box.midX) <= 0.15,
           abs(previous.distanceMeters - observation.distanceMeters)
               <= max(0.5, previous.distanceMeters * 0.35) {
            // Frames taken while the phone swings are kept but do not count as evidence.
            if cameraStable { observations += 1 }
        } else {
            observations = 1
            firstSeen = now
            identifier += 1
        }
        previous = observation
        previousTime = now
        // Persistence is measured in time too: three frames alone can span
        // well under half a second.
        let confirmed = cameraStable && observations >= 3 && now - firstSeen >= 0.5
        return SpatialEvent(
            id: "depth:ground-\(identifier)",
            kind: .obstacle,
            label: "low obstacle",
            direction: Direction.from(horizontalMidpoint: observation.box.midX),
            proximity: Proximity.from(distance: observation.distanceMeters),
            approximateDistanceMeters: (observation.distanceMeters * 10).rounded() / 10,
            approachSpeed: 0,
            collisionRisk: confirmed ? .caution : .none,
            trajectoryConfidence: min(Double(observations) / 3, 1) * 0.8,
            confidence: 0.8,
            urgency: 0,
            timestamp: now,
            box: observation.box
        )
    }
}
