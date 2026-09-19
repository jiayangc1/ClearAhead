import CoreVideo
import Foundation

struct CALoomingObservation {
    let timeToCollisionSeconds: Double
    let confidence: Double
    let collisionRisk: CACollisionRisk
}

final class OpticalFlowAnalyzer {
    private let gridWidth = 48
    private let gridHeight = 36
    private var previousGrid: [UInt8]?
    private var previousTime: TimeInterval?
    private var smoothedDivergence = 0.0
    private var consistentEvidence = 0
    private var retainedRisk: CACollisionRisk = .none
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
    ) -> CALoomingObservation? {
        guard let grid = luminanceGrid(from: pixelBuffer) else { return nil }
        defer {
            previousGrid = grid
            previousTime = now
        }
        guard let previousGrid, let previousTime else { return nil }
        let elapsed = now - previousTime
        guard elapsed >= 0.06, elapsed <= 0.45 else {
            consistentEvidence = 0
            return nil
        }
        guard rotationRate < 0.9 else {
            consistentEvidence = 0
            return nil
        }

        var vectors: [(x: Double, y: Double, centerX: Double, centerY: Double)] = []
        for y in stride(from: 5, to: gridHeight - 4, by: 5) {
            for x in stride(from: 5, to: gridWidth - 4, by: 5) {
                guard localTexture(grid, x: x, y: y) >= 18 else { continue }
                var bestDifference = Int.max
                var bestDX = 0
                var bestDY = 0
                for dy in -2...2 {
                    for dx in -2...2 {
                        let difference = patchDifference(
                            current: grid,
                            previous: previousGrid,
                            x: x,
                            y: y,
                            previousX: x + dx,
                            previousY: y + dy
                        )
                        if difference < bestDifference {
                            bestDifference = difference
                            bestDX = dx
                            bestDY = dy
                        }
                    }
                }
                guard bestDifference < 310 else { continue }
                vectors.append((
                    x: -Double(bestDX) / Double(gridWidth) / elapsed,
                    y: -Double(bestDY) / Double(gridHeight) / elapsed,
                    centerX: Double(x) / Double(gridWidth) - 0.5,
                    centerY: Double(y) / Double(gridHeight) - 0.5
                ))
            }
        }
        guard vectors.count >= 12 else {
            consistentEvidence = max(0, consistentEvidence - 1)
            return retained(now: now)
        }

        let globalX = median(vectors.map(\.x))
        let globalY = median(vectors.map(\.y))
        guard hypot(globalX, globalY) < 0.85 else {
            consistentEvidence = 0
            return nil
        }

        let corridorVectors = vectors.filter {
            abs($0.centerX) <= 0.28 && $0.centerY >= -0.2
        }
        guard corridorVectors.count >= 6 else {
            consistentEvidence = max(0, consistentEvidence - 1)
            return retained(now: now)
        }
        var numerator = 0.0
        var denominator = 0.0
        var expandingVectors = 0
        for vector in corridorVectors {
            let correctedX = vector.x - globalX
            let correctedY = vector.y - globalY
            let radial = correctedX * vector.centerX + correctedY * vector.centerY
            numerator += radial
            denominator += vector.centerX * vector.centerX + vector.centerY * vector.centerY
            if radial > 0 { expandingVectors += 1 }
        }
        guard denominator > 0 else { return retained(now: now) }
        let divergence = max(0, numerator / denominator)
        smoothedDivergence += (divergence - smoothedDivergence) * 0.35
        guard smoothedDivergence > 0.02 else {
            consistentEvidence = max(0, consistentEvidence - 1)
            return retained(now: now)
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
            return CALoomingObservation(
                timeToCollisionSeconds: timeToCollision,
                confidence: confidence,
                collisionRisk: retainedRisk
            )
        }
        return retained(now: now)
    }

    private func retained(now: TimeInterval) -> CALoomingObservation? {
        guard retainedRisk != .none,
              now - lastEvidenceTime <= 0.55,
              smoothedDivergence > 0 else {
            retainedRisk = .none
            return nil
        }
        return CALoomingObservation(
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
        let source = baseAddress.assumingMemoryBound(to: UInt8.self)
        var result = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        for y in 0..<gridHeight {
            let sourceY = min(height - 1, y * height / gridHeight)
            for x in 0..<gridWidth {
                let sourceX = min(width - 1, x * width / gridWidth)
                result[y * gridWidth + x] = source[sourceY * bytesPerRow + sourceX]
            }
        }
        return result
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
