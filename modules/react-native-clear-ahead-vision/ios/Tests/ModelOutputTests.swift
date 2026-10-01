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
        XCTAssertEqual(try XCTUnwrap(map.distance(inVisionBox: bottomLeftVisionBox)), 0.8, accuracy: 0.001)
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

    func testDepthMapDownsamplesLargeOutputs() throws {
        let array = try MLMultiArray(shape: [1, 1, 640, 640], dataType: .float32)
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        for index in 0..<(640 * 640) { pointer[index] = index / 640 < 320 ? 6 : 2 }
        let map = try XCTUnwrap(DepthMap(array: array))
        XCTAssertEqual(map.width, 160)
        XCTAssertEqual(map.height, 160)
        XCTAssertEqual(map.values[0], 6, accuracy: 0.001)
        XCTAssertEqual(map.values[159 * 160 + 159], 2, accuracy: 0.001)
    }

    func testGroundHazardFindsLowObjectOnRecedingFloor() throws {
        let map = try XCTUnwrap(DepthMap(array: floorScene { row, column in
            // A box about 1.6 m away, slightly left of center, well below the horizon.
            (70..<82).contains(row) && (36..<50).contains(column) ? 1.6 : nil
        }))
        let hazard = try XCTUnwrap(map.groundHazard(within: 2.5))
        XCTAssertEqual(hazard.distanceMeters, 1.6, accuracy: 0.05)
        XCTAssertLessThan(hazard.box.midX, 0.5)
        XCTAssertLessThan(hazard.box.maxY, 0.5)
    }

    func testGroundHazardIgnoresClearFloorWallsAndTallObjects() throws {
        let clear = try XCTUnwrap(DepthMap(array: floorScene { _, _ in nil }))
        XCTAssertNil(clear.groundHazard(within: 2.5))

        let wall = try MLMultiArray(shape: [1, 1, 100, 100], dataType: .float32)
        for index in 0..<10_000 { wall[index] = NSNumber(value: 1.2) }
        XCTAssertNil(try XCTUnwrap(DepthMap(array: wall)).groundHazard(within: 2.5))

        let tall = try XCTUnwrap(DepthMap(array: floorScene { row, column in
            row >= 20 && row < 90 && (40..<60).contains(column) ? 1.5 : nil
        }))
        XCTAssertNil(tall.groundHazard(within: 2.5))

        let distant = try XCTUnwrap(DepthMap(array: floorScene { row, column in
            (56..<62).contains(row) && (44..<56).contains(column) ? 4.0 : nil
        }))
        XCTAssertNil(distant.groundHazard(within: 2.5))
    }

    /// A 100x100 scene: far background above the horizon and a floor that
    /// recedes from 0.9 m at the bottom edge to 6 m at mid-height.
    private func floorScene(_ object: (Int, Int) -> Double?) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, 1, 100, 100], dataType: .float32)
        for row in 0..<100 {
            let floor = row < 50 ? 8.0 : 6.0 - Double(row - 50) / 49 * 5.1
            for column in 0..<100 {
                array[row * 100 + column] = NSNumber(value: object(row, column) ?? floor)
            }
        }
        return array
    }

    func testDepthCopyPreservesSupportedFloatingPointTypesAndInvalidPixels() throws {
        var dataTypes = [MLMultiArrayDataType.float32, .double]
        if #available(iOS 16.0, *) { dataTypes.append(.float16) }
        for dataType in dataTypes {
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
        XCTAssertEqual(obstacle.collisionRisk(observations: 2, closingSpeed: 1, stable: true), .none)
        XCTAssertEqual(obstacle.collisionRisk(observations: 3, closingSpeed: 1, stable: false), .none)
        XCTAssertEqual(obstacle.collisionRisk(observations: 3, closingSpeed: 1, stable: true), .imminent)
        XCTAssertEqual(obstacle.collisionRisk(observations: 3, closingSpeed: 0.5, stable: true), .caution)
        XCTAssertEqual(obstacle.collisionRisk(observations: 3, closingSpeed: 0, stable: true), .none)
        // A wall within a step warns even when the walker is too slow to measure.
        let close = PathObstacleObservation(distanceMeters: 0.9, box: obstacle.box, coverage: 0.1)
        XCTAssertEqual(close.collisionRisk(observations: 3, closingSpeed: 0, stable: true), .caution)
    }

    func testDepthPathFindsNarrowObstacleAhead() throws {
        // About a doorframe edge or pole: 6 of 32 path columns, centered.
        let array = try MLMultiArray(shape: [1, 1, 192, 256], dataType: .float32)
        for index in 0..<array.count { array[index] = NSNumber(value: 8) }
        for row in 50..<120 {
            for column in 115..<140 { array[row * 256 + column] = NSNumber(value: 1.2) }
        }
        let map = try XCTUnwrap(DepthMap(array: array))
        let obstacle = try XCTUnwrap(map.pathObstacle(within: 3))
        XCTAssertEqual(obstacle.distanceMeters, 1.2, accuracy: 0.01)
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
