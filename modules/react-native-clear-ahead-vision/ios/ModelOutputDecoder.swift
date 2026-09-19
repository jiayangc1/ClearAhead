import CoreGraphics
import CoreML
import Foundation

struct CAYOLODetection {
    let classIdentifier: Int
    let confidence: Double
    let box: CGRect
}

struct CADepthMap {
    let width: Int
    let height: Int
    let values: [Double]

    init?(array: MLMultiArray) {
        let shape = array.shape.map(\.intValue)
        guard shape.count >= 2 else { return nil }
        let height = shape[shape.count - 2]
        let width = shape[shape.count - 1]
        guard width > 1, height > 1 else { return nil }

        let yStride = array.strides[shape.count - 2].intValue
        let xStride = array.strides[shape.count - 1].intValue
        var decoded = [Double](repeating: .nan, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let value = array[y * yStride + x * xStride].doubleValue
                if value.isFinite, value > 0 {
                    decoded[y * width + x] = value
                }
            }
        }
        self.width = width
        self.height = height
        values = decoded
    }

    func samples(in normalizedBox: CGRect, step: Int = 2) -> [Double] {
        let clamped = normalizedBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return [] }
        let startX = max(0, min(width - 1, Int(clamped.minX * CGFloat(width))))
        let endX = max(startX + 1, min(width, Int(ceil(clamped.maxX * CGFloat(width)))))
        let startY = max(0, min(height - 1, Int(clamped.minY * CGFloat(height))))
        let endY = max(startY + 1, min(height, Int(ceil(clamped.maxY * CGFloat(height)))))
        var result: [Double] = []
        for y in stride(from: startY, to: endY, by: max(step, 1)) {
            for x in stride(from: startX, to: endX, by: max(step, 1)) {
                let value = values[y * width + x]
                if value.isFinite { result.append(value) }
            }
        }
        return result
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

    static func percentile(_ values: [Double], fraction: Double) -> Double {
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))
        return sorted[index]
    }
}

enum CAModelOutputDecoder {
    static func detections(from array: MLMultiArray, inputSize: Double = 640) -> [CAYOLODetection] {
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
            let classIdentifier = Int(value(5).rounded())
            guard confidence.isFinite, confidence > 0.05, classIdentifier >= 0 else { return nil }
            var x1 = value(0)
            var y1 = value(1)
            var x2 = value(2)
            var y2 = value(3)
            guard [x1, y1, x2, y2].allSatisfy({ $0.isFinite }) else { return nil }
            if max(x2, y2) > 2 {
                x1 /= inputSize
                y1 /= inputSize
                x2 /= inputSize
                y2 /= inputSize
            }
            x1 = min(max(x1, 0), 1)
            y1 = min(max(y1, 0), 1)
            x2 = min(max(x2, 0), 1)
            y2 = min(max(y2, 0), 1)
            guard x2 > x1, y2 > y1 else { return nil }
            return CAYOLODetection(
                classIdentifier: classIdentifier,
                confidence: confidence,
                box: CGRect(x: x1, y: 1 - y2, width: x2 - x1, height: y2 - y1)
            )
        }
    }
}
