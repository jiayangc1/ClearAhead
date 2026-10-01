import CoreML
import XCTest
@testable import ClearAheadVision

final class ModelOutputTests: XCTestCase {
    func testDiscontinuousNearPixelsDoNotMergeIntoObstacle() throws {
        let array = try MLMultiArray(shape: [1, 1, 192, 256], dataType: .float32)
        for row in 0..<192 {
            for column in 0..<256 {
                // Alternating depths ensure every sampled neighbor is discontinuous.
                let pathColumn = Int((Double(column) / 256 - 0.26) / 0.48 * 32)
                let pathRow = Int((Double(row) / 192 - 0.18) / 0.58 * 24)
                array[row * 256 + column] = NSNumber(value: (pathColumn + pathRow) % 2 == 0 ? 1.0 : 4.0)
            }
        }
        let map = try XCTUnwrap(DepthMap(array: array))
        XCTAssertNil(map.pathObstacle(within: 6))
    }
    func testDecodesYOLO26EndToEndRows() throws {
        let array = try MLMultiArray(shape: [1, 2, 6], dataType: .float32)
        let rows: [[Double]] = [
            [64, 128, 320, 512, 0.91, 0],
            [0, 0, 0, 0, 0, 0],
        ]
        for row in 0..<rows.count {
            for column in 0..<rows[row].count {
                array[row * 6 + column] = NSNumber(value: rows[row][column])
            }
        }

        let detections = ModelOutput.detections(from: array)

        XCTAssertEqual(detections.count, 1)
        XCTAssertEqual(detections[0].classIdentifier, 0)
        XCTAssertEqual(detections[0].confidence, 0.91, accuracy: 0.001)
        XCTAssertEqual(detections[0].box.minX, 0.1, accuracy: 0.001)
        XCTAssertEqual(detections[0].box.minY, 0.2, accuracy: 0.001)
        XCTAssertEqual(detections[0].box.width, 0.4, accuracy: 0.001)
        XCTAssertEqual(detections[0].box.height, 0.6, accuracy: 0.001)
    }

    func testDepthMapUsesMetricValuesAndVisionCoordinates() throws {
        let array = try MLMultiArray(shape: [1, 1, 8, 8], dataType: .float32)
        for index in 0..<64 {
            array[index] = NSNumber(value: 5.0)
        }
        for y in 4..<8 {
            for x in 0..<4 {
                array[y * 8 + x] = NSNumber(value: 0.8)
            }
        }

        let map = try XCTUnwrap(DepthMap(array: array))
        let bottomLeftVisionBox = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)

        XCTAssertEqual(map.width, 8)
        XCTAssertEqual(map.height, 8)
        XCTAssertEqual(map.distance(inVisionBox: bottomLeftVisionBox), 0.8, accuracy: 0.001)
    }

    func testRejectsLegacyRawDetectionLayout() throws {
        let array = try MLMultiArray(shape: [1, 84, 8400], dataType: .float32)
        XCTAssertTrue(ModelOutput.detections(from: array).isEmpty)
    }

    func testRejectsNonfiniteDetectionClass() throws {
        let array = try MLMultiArray(shape: [1, 1, 6], dataType: .float32)
        for (index, value) in [0.1, 0.1, 0.6, 0.6, 0.9, Double.nan].enumerated() {
            array[index] = NSNumber(value: value)
        }
        XCTAssertTrue(ModelOutput.detections(from: array).isEmpty)
    }

    func testDepthPathFindsCoherentWallButIgnoresFloorOnly() throws {
        let array = try MLMultiArray(shape: [1, 1, 32, 32], dataType: .float32)
        for index in 0..<1024 { array[index] = NSNumber(value: 8.0) }
        for row in 8..<24 {
            for column in 10..<22 { array[row * 32 + column] = NSNumber(value: 1.4) }
        }
        let wall = try XCTUnwrap(DepthMap(array: array))
        XCTAssertNotNil(wall.pathObstacle(within: 3))

        for index in 0..<1024 { array[index] = NSNumber(value: 8.0) }
        for row in 20..<32 {
            for column in 6..<26 { array[row * 32 + column] = NSNumber(value: 1.4) }
        }
        let floor = try XCTUnwrap(DepthMap(array: array))
        XCTAssertNil(floor.pathObstacle(within: 3))
    }
}
