import CoreVideo
import Foundation

struct ObjectDetection {
    let kind: EventKind
    let label: String
    let box: CGRect
    let distanceMeters: Double?
    let confidence: Double

    init(kind: EventKind, label: String? = nil, box: CGRect, distanceMeters: Double?, confidence: Double) {
        self.kind = kind
        self.label = label ?? kind.rawValue
        self.box = box
        self.distanceMeters = distanceMeters
        self.confidence = confidence
    }
}

struct LoomingObservation {
    let timeToCollisionSeconds: Double
    let confidence: Double
    let collisionRisk: CollisionRisk
}

final class OpticalFlowAnalyzer {
    private let gridWidth = 48
    private let gridHeight = 36
    private var previousGrid: [UInt8]?
    private var previousTime: TimeInterval?
    private var smoothedDivergence = 0.0
    private var consistentEvidence = 0
    private var retainedRisk: CollisionRisk = .none
    private var lastEvidenceTime: TimeInterval = 0

    func reset() {
        previousGrid = nil
        previousTime = nil
        smoothedDivergence = 0
        consistentEvidence = 0
        retainedRisk = .none
        lastEvidenceTime = 0
    }

    func analyze(
        pixelBuffer: CVPixelBuffer,
        now: TimeInterval,
        rotationRate: Double,
        depthSupport: Double
    ) -> LoomingObservation? {
        guard let grid = luminanceGrid(from: pixelBuffer) else { return nil }
        defer {
            previousGrid = grid
            previousTime = now
        }
        guard let previousGrid, let previousTime else { return nil }
        let elapsedTime = now - previousTime
        guard elapsedTime >= 0.06, elapsedTime <= 0.45 else {
            consistentEvidence = 0
            return nil
        }
        guard rotationRate < 0.9 else {
            consistentEvidence = 0
            return nil
        }

        var flowVectors: [(
            horizontalVelocity: Double,
            verticalVelocity: Double,
            horizontalPosition: Double,
            verticalPosition: Double
        )] = []
        for row in stride(from: 5, to: gridHeight - 4, by: 5) {
            for column in stride(from: 5, to: gridWidth - 4, by: 5) {
                guard localTexture(grid, x: column, y: row) >= 18 else { continue }
                var bestDifference = Int.max
                var bestHorizontalOffset = 0
                var bestVerticalOffset = 0
                for verticalOffset in -2...2 {
                    for horizontalOffset in -2...2 {
                        let difference = patchDifference(
                            current: grid,
                            previous: previousGrid,
                            x: column,
                            y: row,
                            previousX: column + horizontalOffset,
                            previousY: row + verticalOffset
                        )
                        if difference < bestDifference {
                            bestDifference = difference
                            bestHorizontalOffset = horizontalOffset
                            bestVerticalOffset = verticalOffset
                        }
                    }
                }
                guard bestDifference < 310 else { continue }
                flowVectors.append((
                    horizontalVelocity: -Double(bestHorizontalOffset) / Double(gridWidth) / elapsedTime,
                    verticalVelocity: -Double(bestVerticalOffset) / Double(gridHeight) / elapsedTime,
                    horizontalPosition: Double(column) / Double(gridWidth) - 0.5,
                    verticalPosition: Double(row) / Double(gridHeight) - 0.5
                ))
            }
        }
        guard flowVectors.count >= 12 else {
            consistentEvidence = max(0, consistentEvidence - 1)
            return retainedObservation(now: now)
        }

        let cameraHorizontalMotion = median(flowVectors.map(\.horizontalVelocity))
        let cameraVerticalMotion = median(flowVectors.map(\.verticalVelocity))
        guard hypot(cameraHorizontalMotion, cameraVerticalMotion) < 0.85 else {
            consistentEvidence = 0
            return nil
        }

        let corridorVectors = flowVectors.filter {
            abs($0.horizontalPosition) <= 0.28 && $0.verticalPosition >= -0.2
        }
        guard corridorVectors.count >= 6 else {
            consistentEvidence = max(0, consistentEvidence - 1)
            return retainedObservation(now: now)
        }
        var numerator = 0.0
        var denominator = 0.0
        var expandingVectors = 0
        for vector in corridorVectors {
            let correctedHorizontalVelocity = vector.horizontalVelocity - cameraHorizontalMotion
            let correctedVerticalVelocity = vector.verticalVelocity - cameraVerticalMotion
            let radialExpansion = correctedHorizontalVelocity * vector.horizontalPosition
                + correctedVerticalVelocity * vector.verticalPosition
            numerator += radialExpansion
            denominator += vector.horizontalPosition * vector.horizontalPosition
                + vector.verticalPosition * vector.verticalPosition
            if radialExpansion > 0 { expandingVectors += 1 }
        }
        guard denominator > 0 else { return retainedObservation(now: now) }
        let divergence = max(0, numerator / denominator)
        smoothedDivergence += (divergence - smoothedDivergence) * 0.35
        guard smoothedDivergence > 0.02 else {
            consistentEvidence = max(0, consistentEvidence - 1)
            return retainedObservation(now: now)
        }

        let timeToCollision = 1 / smoothedDivergence
        let agreement = Double(expandingVectors) / Double(corridorVectors.count)
        let textureCoverage = min(Double(corridorVectors.count) / 12, 1)
        let rawConfidence = min(agreement * 0.65 + textureCoverage * 0.2 + depthSupport * 0.15, 1)
        if timeToCollision <= 3.2 && rawConfidence >= 0.58 {
            consistentEvidence += 1
        } else {
            consistentEvidence = max(0, consistentEvidence - 1)
        }

        let confidence = rawConfidence * min(Double(consistentEvidence) / 3, 1)
        if consistentEvidence >= 3, confidence >= 0.65, timeToCollision <= 3 {
            retainedRisk = timeToCollision <= 1.5 ? .imminent : .caution
            lastEvidenceTime = now
            return LoomingObservation(
                timeToCollisionSeconds: timeToCollision,
                confidence: confidence,
                collisionRisk: retainedRisk
            )
        }
        return retainedObservation(now: now)
    }

    private func retainedObservation(now: TimeInterval) -> LoomingObservation? {
        guard retainedRisk != .none,
              now - lastEvidenceTime <= 0.55,
              smoothedDivergence > 0 else {
            retainedRisk = .none
            return nil
        }
        return LoomingObservation(
            timeToCollisionSeconds: 1 / smoothedDivergence,
            confidence: 0.65,
            collisionRisk: retainedRisk
        )
    }

    private func luminanceGrid(from pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let plane = CVPixelBufferGetPlaneCount(pixelBuffer) > 0 ? 0 : 0
        guard let baseAddress = CVPixelBufferGetPlaneCount(pixelBuffer) > 0
            ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetPlaneCount(pixelBuffer) > 0
            ? CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetPlaneCount(pixelBuffer) > 0
            ? CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetPlaneCount(pixelBuffer) > 0
            ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        let luminanceBytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var luminanceGrid = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        for y in 0..<gridHeight {
            let sourceY = min(height - 1, y * height / gridHeight)
            for x in 0..<gridWidth {
                let sourceX = min(width - 1, x * width / gridWidth)
                luminanceGrid[y * gridWidth + x] = luminanceBytes[sourceY * bytesPerRow + sourceX]
            }
        }
        return luminanceGrid
    }

    private func localTexture(_ grid: [UInt8], x: Int, y: Int) -> Int {
        abs(Int(grid[y * gridWidth + x - 1]) - Int(grid[y * gridWidth + x + 1]))
            + abs(Int(grid[(y - 1) * gridWidth + x]) - Int(grid[(y + 1) * gridWidth + x]))
    }

    private func patchDifference(
        current: [UInt8],
        previous: [UInt8],
        x: Int,
        y: Int,
        previousX: Int,
        previousY: Int
    ) -> Int {
        var difference = 0
        for offsetY in -1...1 {
            for offsetX in -1...1 {
                let currentValue = Int(current[(y + offsetY) * gridWidth + x + offsetX])
                let previousValue = Int(previous[(previousY + offsetY) * gridWidth + previousX + offsetX])
                difference += abs(currentValue - previousValue)
            }
        }
        return difference
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

final class CollisionTracker {
    private final class Track {
        let id: String
        let kind: EventKind
        let label: String
        var box: CGRect
        var distanceMeters: Double?
        var confidence: Double
        var lateralVelocity = 0.0
        var scaleRate = 0.0
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
        let observedScaleRate = log(max(Double(detection.box.height), 0.02) / max(Double(track.box.height), 0.02)) / elapsedTime
        track.lateralVelocity = mix(track.lateralVelocity, observedLateralVelocity, smoothingFactor: smoothingFactor)
        track.scaleRate = mix(track.scaleRate, observedScaleRate, smoothingFactor: smoothingFactor)

        if let previousDistance = track.distanceMeters, let distance = detection.distanceMeters {
            let observedClosingSpeed = (previousDistance - distance) / elapsedTime
            track.signedClosingSpeed = mix(track.signedClosingSpeed, observedClosingSpeed, smoothingFactor: smoothingFactor)
            track.distanceMeters = mix(previousDistance, distance, smoothingFactor: smoothingFactor)
        } else {
            track.distanceMeters = detection.distanceMeters
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

        let motionState: MotionState
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
        var detectedRisk: CollisionRisk = .none
        if cameraStable,
           track.observations >= 3,
           trajectoryConfidence >= minimumConfidence,
           corridorOverlap >= 0.25 {
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
            proximity: Proximity.from(distance: track.distanceMeters),
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
