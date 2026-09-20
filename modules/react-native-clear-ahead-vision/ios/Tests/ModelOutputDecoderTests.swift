import CoreML
import XCTest
@testable import ClearAheadVision

final class ModelOutputDecoderTests: XCTestCase {
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

        let detections = ModelOutputDecoder.detections(from: array)

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
        XCTAssertTrue(ModelOutputDecoder.detections(from: array).isEmpty)
    }
}
