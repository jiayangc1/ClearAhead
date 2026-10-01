import CoreML
import UIKit
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

    func testDepthCopyPreservesSupportedFloatingPointTypesAndInvalidPixels() throws {
        for dataType in [MLMultiArrayDataType.float16, .float32, .double] {
            let array = try MLMultiArray(shape: [1, 1, 8, 8], dataType: dataType)
            for index in 0..<64 { array[index] = NSNumber(value: 2.5) }
            array[0] = NSNumber(value: Double.nan)
            array[1] = NSNumber(value: -1)
            let map = try XCTUnwrap(DepthMap(array: array))
            XCTAssertTrue(map.values[0].isNaN)
            XCTAssertTrue(map.values[1].isNaN)
            XCTAssertEqual(map.values[2], 2.5, accuracy: 0.001)
        }
    }

    func testDepthCopyRespectsNoncontiguousStrides() throws {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        pointer.initialize(repeating: 99, count: 128)
        defer { pointer.deinitialize(count: 128); pointer.deallocate() }
        for row in 0..<8 {
            for column in 0..<8 { pointer[row * 16 + column * 2] = Float(row + 1) }
        }
        let array = try MLMultiArray(dataPointer: UnsafeMutableRawPointer(pointer), shape: [1, 1, 8, 8], dataType: .float32,
                                     strides: [128, 128, 16, 2], deallocator: nil)
        let map = try XCTUnwrap(DepthMap(array: array))
        XCTAssertEqual(map.values[0], 1)
        XCTAssertEqual(map.values[63], 8)
        XCTAssertFalse(map.values.contains(99))
    }

    func testSparseSideObstructionDoesNotBecomeObstacleAhead() throws {
        let array = try MLMultiArray(shape: [1, 1, 192, 256], dataType: .float32)
        for index in 0..<array.count { array[index] = NSNumber(value: 8) }
        for row in 40..<130 {
            for column in 65..<100 { array[row * 256 + column] = NSNumber(value: 0.6) }
        }
        let map = try XCTUnwrap(DepthMap(array: array))
        XCTAssertNil(map.pathObstacle(within: 3))
    }

    func testPathCollisionRequiresStablePersistentEvidence() {
        let obstacle = PathObstacleObservation(distanceMeters: 1.2,
                                               box: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.5), coverage: 0.3)
        XCTAssertEqual(obstacle.collisionRisk(observations: 3, duration: 1, closingSpeed: 1, stable: true), .none)
        XCTAssertEqual(obstacle.collisionRisk(observations: 4, duration: 0.5, closingSpeed: 1, stable: true), .none)
        XCTAssertEqual(obstacle.collisionRisk(observations: 4, duration: 0.8, closingSpeed: 1, stable: false), .none)
        XCTAssertEqual(obstacle.collisionRisk(observations: 4, duration: 0.8, closingSpeed: 1, stable: true), .imminent)
        XCTAssertEqual(obstacle.collisionRisk(observations: 4, duration: 0.8, closingSpeed: 0.5, stable: true), .caution)
        XCTAssertEqual(obstacle.collisionRisk(observations: 5, duration: 1.5, closingSpeed: 0, stable: true), .none)
        let close = PathObstacleObservation(distanceMeters: 0.5, box: obstacle.box, coverage: 0.3)
        XCTAssertEqual(close.collisionRisk(observations: 5, duration: 1.5, closingSpeed: 0, stable: true), .caution)
        let sparse = PathObstacleObservation(distanceMeters: 0.5, box: obstacle.box, coverage: 0.1)
        XCTAssertEqual(sparse.collisionRisk(observations: 5, duration: 1.5, closingSpeed: 1, stable: true), .none)
    }

    func testBoundingBoxVerbosityFiltersUnnecessaryObjects() {
        let pathBox = CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.4)
        let person = YOLODetection(classIdentifier: 0, confidence: 0.9, box: pathBox)
        let cup = YOLODetection(classIdentifier: 41, confidence: 0.9, box: pathBox)
        let weakPerson = YOLODetection(classIdentifier: 0, confidence: 0.3, box: pathBox)
        let sideChair = YOLODetection(classIdentifier: 56, confidence: 0.9, box: CGRect(x: 0, y: 0.2, width: 0.15, height: 0.4))
        XCTAssertTrue(person.shouldDisplay(verbosity: "standard"))
        XCTAssertFalse(cup.shouldDisplay(verbosity: "standard"))
        XCTAssertFalse(weakPerson.shouldDisplay(verbosity: "standard"))
        XCTAssertFalse(sideChair.shouldDisplay(verbosity: "standard"))
        XCTAssertTrue(cup.shouldDisplay(verbosity: "verbose"))
        XCTAssertTrue(weakPerson.shouldDisplay(verbosity: "verbose"))
        XCTAssertFalse(person.shouldDisplay(verbosity: "less"))
    }

    func testDepthPreviewIsBoundedAndKeepsFullDepthValues() throws {
        let array = try MLMultiArray(shape: [1, 1, 48, 64], dataType: .float32)
        for index in 0..<array.count { array[index] = NSNumber(value: 2.5) }
        let map = try XCTUnwrap(DepthMap(array: array))
        let url = try XCTUnwrap(map.heatmapDataURL(maxDimension: 16, farDistance: 6))
        let data = try XCTUnwrap(Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count))))
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertEqual(image.width, 16)
        XCTAssertEqual(image.height, 12)
        XCTAssertEqual(map.values.count, 48 * 64)
        XCTAssertEqual(try XCTUnwrap(map.distance(inVisionBox: CGRect(x: 0, y: 0, width: 1, height: 1))), 2.5, accuracy: 0.001)
    }
}
