import CoreGraphics
import AVFoundation
import CoreML
import Foundation
import UIKit

struct YOLODetection {
    let classIdentifier: Int
    let confidence: Double
    let box: CGRect

    var kind: EventKind? {
        switch classIdentifier {
        case 0: return .person
        case 1, 2, 3, 5, 6, 7: return .vehicle
        case 13, 56, 57, 59, 60, 61: return .furniture
        // Low things that sit on the ground and trip people: hydrant, cat, dog,
        // backpack, handbag, suitcase, sports ball, skateboard, potted plant.
        case 10, 15, 16, 24, 26, 28, 32, 36, 58: return .obstacle
        // Small clutter matters only underfoot: umbrella, bottle, cup, bowl,
        // book, vase, teddy bear. The same bottle up on a table is not in the way.
        case 25, 39, 41, 45, 73, 75, 77: return box.maxY <= 0.5 ? .obstacle : nil
        default: return nil
        }
    }

    func shouldDisplay(verbosity: String) -> Bool {
        if verbosity == "verbose" { return confidence >= 0.25 }
        guard verbosity == "standard", confidence >= 0.6, let kind else { return false }
        return kind != .furniture || (box.maxX >= 0.34 && box.minX <= 0.66 && box.height >= 0.12)
    }
}

struct PathObstacleObservation {
    let distanceMeters: Double
    let box: CGRect
    let coverage: Double

    func collisionRisk(observations: Int, closingSpeed: Double, stable: Bool) -> CollisionRisk {
        guard stable, observations >= 3,
              distanceMeters.isFinite, distanceMeters > 0, closingSpeed.isFinite else { return .none }
        if closingSpeed > 0.2 {
            let timeToCollision = distanceMeters / closingSpeed
            if timeToCollision <= 1.5 { return .imminent }
            if timeToCollision <= 3 { return .caution }
        }
        // Too slow to measure a closing speed, but the path is blocked within a step.
        return distanceMeters <= 1 ? .caution : .none
    }
}

struct DepthMap: Sendable {
    let width: Int
    let height: Int
    let values: [Double]

    var hasUsableCoverage: Bool {
        var usable = 0
        for value in values where value.isFinite && value > 0.15 && value < 100 { usable += 1 }
        return Double(usable) / Double(values.count) >= 0.65
    }

    init?(lidar: AVDepthData, maxDimension: Int = 160) {
        guard lidar.depthDataAccuracy == .absolute, lidar.depthDataQuality == .high else { return nil }
        // Match Vision's clockwise portrait rotation; LiDAR and color share the same field of view.
        let buffer = lidar.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            .applyingExifOrientation(.right).depthDataMap
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(buffer)
        let sourceHeight = CVPixelBufferGetHeight(buffer)
        guard sourceWidth > 1, sourceHeight > 1 else { return nil }
        let step = max(1, (max(sourceWidth, sourceHeight) + max(maxDimension, 2) - 1) / max(maxDimension, 2))
        let width = (sourceWidth + step - 1) / step
        let height = (sourceHeight + step - 1) / step
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.stride
        let pointer = base.assumingMemoryBound(to: Float.self)
        var values = [Double](repeating: .nan, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                let value = Double(pointer[row * step * stride + column * step])
                // shortcut: LiDAR is used only through 5 m; extend after device range validation.
                if value.isFinite, value > 0.15, value <= 5 { values[row * width + column] = value }
            }
        }
        guard values.contains(where: { $0.isFinite }) else { return nil }
        self.init(width: width, height: height, values: values)
    }

    func mergingCloseDepth(_ lidar: DepthMap?) -> DepthMap {
        guard let lidar else { return self }
        var merged = values
        for row in 0..<height {
            for column in 0..<width {
                let x = min(lidar.width - 1, Int((Double(column) + 0.5) / Double(width) * Double(lidar.width)))
                let y = min(lidar.height - 1, Int((Double(row) + 0.5) / Double(height) * Double(lidar.height)))
                let measurement = lidar.values[y * lidar.width + x]
                let index = row * width + column
                if measurement.isFinite, measurement > 0.15, measurement <= 5,
                   measurement <= 2 || !merged[index].isFinite {
                    merged[index] = measurement
                }
            }
        }
        return DepthMap(width: width, height: height, values: merged)
    }

    init(width: Int, height: Int, values: [Double]) {
        precondition(width > 1 && height > 1 && values.count == width * height)
        self.width = width
        self.height = height
        self.values = values
    }

    // Hazard analysis samples coarse grids, so parsing keeps at most
    // maxDimension values per side instead of the model's full output.
    init?(array: MLMultiArray, maxDimension: Int = 160) {
        let shape = array.shape.map(\.intValue)
        guard shape.count >= 2 else { return nil }
        let sourceHeight = shape[shape.count - 2]
        let sourceWidth = shape[shape.count - 1]
        guard sourceWidth > 1, sourceHeight > 1 else { return nil }

        let rowStride = array.strides[shape.count - 2].intValue
        let columnStride = array.strides[shape.count - 1].intValue
        let limit = max(maxDimension, 2)
        let step = max(1, (max(sourceWidth, sourceHeight) + limit - 1) / limit)
        let width = (sourceWidth + step - 1) / step
        let height = (sourceHeight + step - 1) / step
        var depthValues = [Double](repeating: .nan, count: width * height)
        func copy<T: BinaryFloatingPoint>(_ pointer: UnsafePointer<T>) {
            for row in 0..<height {
                for column in 0..<width {
                    let value = Double(pointer[row * step * rowStride + column * step * columnStride])
                    if value.isFinite, value > 0 {
                        depthValues[row * width + column] = value
                    }
                }
            }
        }
        // Avoid an NSNumber allocation and Objective-C subscript for every depth pixel.
        switch array.dataType {
        case .float16: copy(array.dataPointer.assumingMemoryBound(to: Float16.self))
        case .float32: copy(array.dataPointer.assumingMemoryBound(to: Float.self))
        case .double: copy(array.dataPointer.assumingMemoryBound(to: Double.self))
        default:
            for row in 0..<height {
                for column in 0..<width {
                    let value = array[row * step * rowStride + column * step * columnStride].doubleValue
                    if value.isFinite, value > 0 { depthValues[row * width + column] = value }
                }
            }
        }
        self.width = width
        self.height = height
        values = depthValues
    }

    func samples(in normalizedBox: CGRect, step: Int = 2) -> [Double] {
        let clamped = normalizedBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return [] }
        let startX = max(0, min(width - 1, Int(clamped.minX * CGFloat(width))))
        let endX = max(startX + 1, min(width, Int(ceil(clamped.maxX * CGFloat(width)))))
        let startY = max(0, min(height - 1, Int(clamped.minY * CGFloat(height))))
        let endY = max(startY + 1, min(height, Int(ceil(clamped.maxY * CGFloat(height)))))
        var sampledValues: [Double] = []
        sampledValues.reserveCapacity(((endX - startX) / max(step, 1) + 1) * ((endY - startY) / max(step, 1) + 1))
        for row in stride(from: startY, to: endY, by: max(step, 1)) {
            for column in stride(from: startX, to: endX, by: max(step, 1)) {
                let value = values[row * width + column]
                if value.isFinite { sampledValues.append(value) }
            }
        }
        return sampledValues
    }

    func distance(inVisionBox box: CGRect) -> Double? {
        // Vision boxes use a bottom-left origin; dense model output uses top-left.
        let depthBox = CGRect(
            x: box.minX,
            y: 1 - box.maxY,
            width: box.width,
            height: box.height
        ).insetBy(dx: box.width * 0.18, dy: box.height * 0.18)
        let values = samples(in: depthBox)
        guard values.count >= 4 else { return nil }
        return Self.percentile(values, fraction: 0.35)
    }

    func pathObstacle(within warningDistance: Double) -> PathObstacleObservation? {
        let columns = 32
        let rows = 24
        let path = CGRect(x: 0.26, y: 0.18, width: 0.48, height: 0.58)
        var distances = [Double](repeating: .nan, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let x = min(width - 1, Int((Double(path.minX) + (Double(column) + 0.5) * Double(path.width) / Double(columns)) * Double(width)))
                let y = min(height - 1, Int((Double(path.minY) + (Double(row) + 0.5) * Double(path.height) / Double(rows)) * Double(height)))
                let distance = values[y * width + x]
                if distance.isFinite, distance > 0, distance <= warningDistance {
                    distances[row * columns + column] = distance
                }
            }
        }

        var visited = [Bool](repeating: false, count: distances.count)
        var best: PathObstacleObservation?
        for start in distances.indices where distances[start].isFinite && !visited[start] {
            var queue = [start]
            var offset = 0
            var component: [Double] = []
            var minColumn = columns
            var maxColumn = 0
            var minRow = rows
            var maxRow = 0
            var centerCount = 0
            visited[start] = true
            while offset < queue.count {
                let index = queue[offset]
                offset += 1
                let row = index / columns
                let column = index % columns
                component.append(distances[index])
                if (12...19).contains(column), row < 18 { centerCount += 1 }
                minColumn = min(minColumn, column)
                maxColumn = max(maxColumn, column)
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
                for neighbor in [
                    row > 0 ? index - columns : -1,
                    row + 1 < rows ? index + columns : -1,
                    column > 0 ? index - 1 : -1,
                    column + 1 < columns ? index + 1 : -1,
                ] where neighbor >= 0 && !visited[neighbor] && distances[neighbor].isFinite {
                    let maximumJump = max(0.3, min(distances[index], distances[neighbor]) * 0.2)
                    guard abs(distances[index] - distances[neighbor]) <= maximumJump else { continue }
                    visited[neighbor] = true
                    queue.append(neighbor)
                }
            }
            // The size limits admit a doorframe or a pole; the center share
            // keeps something purely off to one side from reading as ahead.
            guard component.count >= 38,
                  centerCount >= 12,
                  maxColumn - minColumn >= 4,
                  maxRow - minRow >= 4,
                  Double(path.minY) + Double(minRow) * Double(path.height) / Double(rows) <= 0.55 else { continue }
            let distance = Self.percentile(component, fraction: 0.35)
            let coverage = Double(component.count) / Double(columns * rows)
            let top = Double(path.minY) + Double(minRow) * Double(path.height) / Double(rows)
            let bottom = Double(path.minY) + Double(maxRow + 1) * Double(path.height) / Double(rows)
            let box = CGRect(
                x: Double(path.minX) + Double(minColumn) * Double(path.width) / Double(columns),
                y: 1 - bottom,
                width: Double(maxColumn - minColumn + 1) * Double(path.width) / Double(columns),
                height: bottom - top
            )
            let observation = PathObstacleObservation(distanceMeters: distance, box: box, coverage: coverage)
            if let currentBest = best {
                if distance < currentBest.distanceMeters { best = observation }
            } else {
                best = observation
            }
        }
        return best
    }

    /// Finds something low on the ground ahead: a region in the lower half of
    /// the view that sits closer than the floor visible beside it. Tall
    /// obstacles are left to `pathObstacle`.
    func groundHazard(within maximumDistance: Double) -> PathObstacleObservation? {
        let columns = 32
        let rows = 20
        let region = CGRect(x: 0.18, y: 0.5, width: 0.64, height: 0.48)
        var distances = [Double](repeating: .nan, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let x = min(width - 1, Int((Double(region.minX) + (Double(column) + 0.5) * Double(region.width) / Double(columns)) * Double(width)))
                let y = min(height - 1, Int((Double(region.minY) + (Double(row) + 0.5) * Double(region.height) / Double(rows)) * Double(height)))
                distances[row * columns + column] = values[y * width + x]
            }
        }

        // At one image row the floor is the farthest surface in view; anything
        // resting on it is hit by the same ray sooner.
        var floor = [Double](repeating: .nan, count: rows)
        for row in 0..<rows {
            let valid = distances[(row * columns)..<((row + 1) * columns)].filter(\.isFinite)
            if valid.count >= columns / 2 { floor[row] = Self.percentile(valid, fraction: 0.7) }
        }
        // Without a floor receding toward the horizon this is a wall or an
        // unreadable view, not ground with something on it.
        let upperFloor = floor.prefix(rows / 2).filter(\.isFinite)
        let lowerFloor = floor.suffix(rows / 2).filter(\.isFinite)
        guard upperFloor.count >= 3, lowerFloor.count >= 3,
              Self.percentile(Array(upperFloor), fraction: 0.5)
                >= Self.percentile(Array(lowerFloor), fraction: 0.5) * 1.25 else { return nil }

        var raised = [Bool](repeating: false, count: distances.count)
        for row in 0..<rows where floor[row].isFinite {
            for column in 0..<columns {
                let distance = distances[row * columns + column]
                guard distance.isFinite, distance <= maximumDistance else { continue }
                // Seen from standing height, a 20 cm object sits only about
                // 15% nearer than the floor behind it.
                raised[row * columns + column] = floor[row] - distance >= max(0.2, floor[row] * 0.13)
            }
        }

        var visited = [Bool](repeating: false, count: distances.count)
        var best: PathObstacleObservation?
        for start in distances.indices where raised[start] && !visited[start] {
            var queue = [start]
            var offset = 0
            var component: [Double] = []
            var minColumn = columns
            var maxColumn = 0
            var minRow = rows
            var maxRow = 0
            visited[start] = true
            while offset < queue.count {
                let index = queue[offset]
                offset += 1
                let row = index / columns
                let column = index % columns
                component.append(distances[index])
                minColumn = min(minColumn, column)
                maxColumn = max(maxColumn, column)
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
                for neighbor in [
                    row > 0 ? index - columns : -1,
                    row + 1 < rows ? index + columns : -1,
                    column > 0 ? index - 1 : -1,
                    column + 1 < columns ? index + 1 : -1,
                ] where neighbor >= 0 && !visited[neighbor] && raised[neighbor] {
                    let maximumJump = max(0.3, min(distances[index], distances[neighbor]) * 0.2)
                    guard abs(distances[index] - distances[neighbor]) <= maximumJump else { continue }
                    visited[neighbor] = true
                    queue.append(neighbor)
                }
            }
            // A region reaching the top of the scan continues upward: that is a
            // tall obstacle or a side wall, not something to trip over.
            guard component.count >= 6,
                  maxColumn - minColumn >= 1,
                  maxRow - minRow >= 1,
                  minRow > 0 else { continue }
            let distance = Self.percentile(component, fraction: 0.35)
            let top = Double(region.minY) + Double(minRow) * Double(region.height) / Double(rows)
            let bottom = Double(region.minY) + Double(maxRow + 1) * Double(region.height) / Double(rows)
            let observation = PathObstacleObservation(
                distanceMeters: distance,
                box: CGRect(
                    x: Double(region.minX) + Double(minColumn) * Double(region.width) / Double(columns),
                    y: 1 - bottom,
                    width: Double(maxColumn - minColumn + 1) * Double(region.width) / Double(columns),
                    height: bottom - top
                ),
                coverage: Double(component.count) / Double(columns * rows)
            )
            if distance < (best?.distanceMeters ?? .infinity) { best = observation }
        }
        return best
    }

    /// Finds a step up that spans the path: a ledge, a curb, the edge of a
    /// raised platform. Nothing in its image row sits nearer than the rest, so
    /// `groundHazard` cannot see it. Each column is read from the feet outward
    /// instead. Over flat ground inverse depth falls along a straight line
    /// toward the horizon; raised ground jumps nearer than that line at its
    /// edge and stays nearer while it goes on receding.
    func groundStep(within maximumDistance: Double) -> PathObstacleObservation? {
        let columns = 32
        let rows = 32
        // A phone tilted toward the ground shows floor well above mid-height.
        let region = CGRect(x: 0.18, y: 0.34, width: 0.64, height: 0.65)
        var sampled = [Double](repeating: .nan, count: columns * rows)
        for row in 0..<rows {
            let startY = min(height - 1, Int((Double(region.minY) + Double(row) * Double(region.height) / Double(rows)) * Double(height)))
            let endY = min(height, max(startY + 1, Int((Double(region.minY) + Double(row + 1) * Double(region.height) / Double(rows)) * Double(height))))
            for column in 0..<columns {
                let startX = min(width - 1, Int((Double(region.minX) + Double(column) * Double(region.width) / Double(columns)) * Double(width)))
                let endX = min(width, max(startX + 1, Int((Double(region.minX) + Double(column + 1) * Double(region.width) / Double(columns)) * Double(width))))
                var sum = 0.0
                var count = 0.0
                for y in startY..<endY {
                    for x in startX..<endX {
                        let value = values[y * width + x]
                        if value.isFinite, value > 0.15 { sum += 1 / value; count += 1 }
                    }
                }
                if count > 0 { sampled[row * columns + column] = sum / count }
            }
        }
        // A median across three columns drops single-cell depth noise.
        var inverse = sampled
        for row in 0..<rows {
            for column in 1..<(columns - 1) {
                let index = row * columns + column
                let trio = [sampled[index - 1], sampled[index], sampled[index + 1]].filter(\.isFinite).sorted()
                inverse[index] = trio.count == 3 ? trio[1] : .nan
            }
        }

        // A 6 cm step seen from standing height is about 4.5% nearer than the
        // ground it rises from. Past 60% it is a tall obstacle, not a step.
        let raisedRatio = 1.045...1.6
        var edges = [Int](repeating: -1, count: columns)
        for column in 0..<columns {
            // The nearest edge is the one that matters, so start at the feet.
            search: for edge in stride(from: rows - 5, through: 2, by: -1) {
                let near = (edge + 1)...min(edge + 8, rows - 1)
                var sumY = 0.0, sumQ = 0.0, sumYY = 0.0, sumYQ = 0.0
                for row in near {
                    let value = inverse[row * columns + column]
                    guard value.isFinite else { continue search }
                    sumY += Double(row); sumQ += value
                    sumYY += Double(row * row); sumYQ += Double(row) * value
                }
                let count = Double(near.count)
                let slope = (count * sumYQ - sumY * sumQ) / (count * sumYY - sumY * sumY)
                let intercept = (sumQ - slope * sumY) / count
                // Ground comes nearer toward the feet, and it must really be flat.
                guard slope > 0 else { continue }
                for row in near {
                    let expected = intercept + slope * Double(row)
                    guard expected > 0, abs(inverse[row * columns + column] / expected - 1) <= 0.02 else { continue search }
                }
                // The riser itself may fill a row or two before the raised ground begins.
                for gap in 0...2 where edge - gap - 2 >= 0 {
                    let first = edge - gap
                    var lowest = Double.infinity, highest = 0.0
                    for row in (first - 2)...first {
                        let expected = intercept + slope * Double(row)
                        let ratio = expected > 0 ? inverse[row * columns + column] / expected : .nan
                        lowest = min(lowest, ratio.isFinite ? ratio : 0)
                        highest = max(highest, ratio.isFinite ? ratio : .infinity)
                    }
                    // Level raised ground is nearer by the same share at every
                    // row. A wall or a box keeps one depth going up the image
                    // instead of receding.
                    guard raisedRatio.contains(lowest), raisedRatio.contains(highest), highest <= lowest * 1.06,
                          inverse[(first - 2) * columns + column] <= inverse[first * columns + column] * 0.96,
                          1 / inverse[first * columns + column] <= maximumDistance else { continue }
                    edges[column] = first
                    break search
                }
            }
        }

        // One column proves nothing. The edge has to run across a walking
        // width, at about the same height from column to column.
        var best: PathObstacleObservation?
        var start = 0
        while start < columns {
            guard edges[start] >= 0 else { start += 1; continue }
            var end = start
            while end + 1 < columns, edges[end + 1] >= 0, abs(edges[end + 1] - edges[end]) <= 2 { end += 1 }
            defer { start = end + 1 }
            guard end - start + 1 >= 8 else { continue }
            let run = start...end
            let distance = Self.percentile(run.map { 1 / inverse[edges[$0] * columns + $0] }, fraction: 0.35)
            let top = Double(region.minY) + Double(max(run.map { edges[$0] }.min()! - 1, 0)) * Double(region.height) / Double(rows)
            let bottom = Double(region.minY) + Double(min(run.map { edges[$0] }.max()! + 2, rows)) * Double(region.height) / Double(rows)
            let observation = PathObstacleObservation(
                distanceMeters: distance,
                box: CGRect(
                    x: Double(region.minX) + Double(start) * Double(region.width) / Double(columns),
                    y: 1 - bottom,
                    width: Double(run.count) * Double(region.width) / Double(columns),
                    height: bottom - top
                ),
                coverage: Double(run.count) / Double(columns)
            )
            if distance < (best?.distanceMeters ?? .infinity) { best = observation }
        }
        return best
    }

    static func percentile(_ values: [Double], fraction: Double) -> Double {
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))
        return sorted[index]
    }

    func heatmapDataURL(maxDimension: Int = 128, farDistance: Double = 6, imageAspect: Double? = nil) -> String? {
        // Fixed metric colors do not flicker as scene percentiles change. Convert only preview pixels.
        let near = 0.25
        let scale = max(farDistance - near, 0.001)
        let sampleStep = max(1, Int(ceil(Double(max(width, height)) / Double(max(maxDimension, 1)))))
        let outputWidth = max(1, width / sampleStep)
        let outputHeight = max(1, height / sampleStep)
        var pixels = [UInt8](repeating: 0, count: outputWidth * outputHeight * 4)

        for row in 0..<outputHeight {
            for column in 0..<outputWidth {
                let value = values[min(row * sampleStep, height - 1) * width + min(column * sampleStep, width - 1)]
                let offset = (row * outputWidth + column) * 4
                guard value.isFinite, value > 0 else {
                    pixels[offset + 3] = 255
                    continue
                }
                let distance = min(max((value - near) / scale, 0), 1)
                // Walk the spectrum from near to far: red, yellow, green, cyan, blue.
                let hue = distance * 4
                pixels[offset] = UInt8(min(max(2 - hue, 0), 1) * 255)
                pixels[offset + 1] = UInt8(min(hue, 4 - hue, 1) * 255)
                pixels[offset + 2] = UInt8(min(max(hue - 2, 0), 1) * 255)
                pixels[offset + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: outputWidth,
                height: outputHeight,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: outputWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }
        let aspect = imageAspect ?? Double(width) / Double(height)
        guard aspect.isFinite, aspect > 0 else { return nil }
        let size = CGSize(width: 480 * aspect, height: 480)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let preview = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
            for y in [0.2, 0.5, 0.8] {
                for x in [0.2, 0.5, 0.8] {
                    let samples = self.samples(in: CGRect(x: x - 0.04, y: y - 0.04, width: 0.08, height: 0.08), step: 1)
                    let distance: Double? = samples.count >= 4 ? Self.percentile(samples, fraction: 0.35) : nil
                    let label = distance.map { String(format: "~%.1f m", $0) } ?? "Unknown"
                    let text = NSAttributedString(string: label, attributes: [
                        .font: UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                        .foregroundColor: UIColor.white, .backgroundColor: UIColor.black.withAlphaComponent(0.7),
                    ])
                    text.draw(at: CGPoint(x: x * size.width - text.size().width / 2,
                                          y: y * size.height - text.size().height / 2))
                }
            }
        }
        guard let png = preview.pngData() else { return nil }
        return "data:image/png;base64,\(png.base64EncodedString())"
    }
}

enum ModelOutput {
    static func detections(from array: MLMultiArray, inputSize: Double = 640) -> [YOLODetection] {
        let shape = array.shape.map(\.intValue)
        guard shape.count >= 2 else { return [] }
        let rowCount = shape[shape.count - 2]
        let columnCount = shape[shape.count - 1]
        guard columnCount == 6, rowCount > 0 else { return [] }

        let rowStride = array.strides[shape.count - 2].intValue
        let columnStride = array.strides[shape.count - 1].intValue
        // Read the buffer directly; the subscript allocates an NSNumber per value.
        let read: (Int) -> Double
        switch array.dataType {
        case .float16:
            let pointer = array.dataPointer.assumingMemoryBound(to: Float16.self)
            read = { Double(pointer[$0]) }
        case .float32:
            let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
            read = { Double(pointer[$0]) }
        case .double:
            let pointer = array.dataPointer.assumingMemoryBound(to: Double.self)
            read = { pointer[$0] }
        default:
            read = { array[$0].doubleValue }
        }
        return (0..<rowCount).compactMap { row in
            func value(_ column: Int) -> Double {
                read(row * rowStride + column * columnStride)
            }
            let confidence = value(4)
            let classValue = value(5)
            guard confidence.isFinite, confidence > 0.05,
                  classValue.isFinite, classValue >= 0, classValue < 80 else { return nil }
            let classIdentifier = Int(classValue.rounded())
            guard classIdentifier < 80 else { return nil }
            var left = value(0)
            var top = value(1)
            var right = value(2)
            var bottom = value(3)
            guard [left, top, right, bottom].allSatisfy({ $0.isFinite }) else { return nil }
            if max(right, bottom) > 2 {
                left /= inputSize
                top /= inputSize
                right /= inputSize
                bottom /= inputSize
            }
            left = min(max(left, 0), 1)
            top = min(max(top, 0), 1)
            right = min(max(right, 0), 1)
            bottom = min(max(bottom, 0), 1)
            guard right > left, bottom > top else { return nil }
            return YOLODetection(
                classIdentifier: classIdentifier,
                confidence: confidence,
                box: CGRect(x: left, y: 1 - bottom, width: right - left, height: bottom - top)
            )
        }
    }
}
