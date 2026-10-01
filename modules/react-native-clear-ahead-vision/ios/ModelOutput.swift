import CoreGraphics
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

    func collisionRisk(observations: Int, duration: TimeInterval, closingSpeed: Double, stable: Bool) -> CollisionRisk {
        guard stable, observations >= 4, duration >= 0.7, coverage >= 0.15,
              distanceMeters.isFinite, distanceMeters > 0, closingSpeed.isFinite else { return .none }
        if closingSpeed >= 0.35 {
            let timeToCollision = distanceMeters / closingSpeed
            if timeToCollision <= 1.5 { return .imminent }
            if timeToCollision <= 2.5 { return .caution }
        }
        // Stationary depth alone requires a broad obstruction closer than one step.
        if observations >= 5, duration >= 1, coverage >= 0.28, distanceMeters <= 0.65 {
            return .caution
        }
        return .none
    }
}

struct DepthMap: Sendable {
    let width: Int
    let height: Int
    let values: [Double]

    init?(array: MLMultiArray) {
        let shape = array.shape.map(\.intValue)
        guard shape.count >= 2 else { return nil }
        let height = shape[shape.count - 2]
        let width = shape[shape.count - 1]
        guard width > 1, height > 1 else { return nil }

        let rowStride = array.strides[shape.count - 2].intValue
        let columnStride = array.strides[shape.count - 1].intValue
        var depthValues = [Double](repeating: .nan, count: width * height)
        func copy<T: BinaryFloatingPoint>(_ pointer: UnsafePointer<T>) {
            for row in 0..<height {
                for column in 0..<width {
                    let value = Double(pointer[row * rowStride + column * columnStride])
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
                    let value = array[row * rowStride + column * columnStride].doubleValue
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
            guard component.count >= 116,
                  centerCount >= 32,
                  maxColumn - minColumn >= 7,
                  maxRow - minRow >= 6,
                  Double(path.minY) + Double(minRow) * Double(path.height) / Double(rows) <= 0.5 else { continue }
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

    static func percentile(_ values: [Double], fraction: Double) -> Double {
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))
        return sorted[index]
    }

    func heatmapDataURL(maxDimension: Int = 128, farDistance: Double = 6) -> String? {
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
                pixels[offset] = UInt8((1 - distance) * 255)
                pixels[offset + 1] = UInt8((1 - abs(distance - 0.5) * 2) * 72)
                pixels[offset + 2] = UInt8(distance * 255)
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
              ),
              let png = UIImage(cgImage: image).pngData() else { return nil }
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
        return (0..<rowCount).compactMap { row in
            func value(_ column: Int) -> Double {
                array[row * rowStride + column * columnStride].doubleValue
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
