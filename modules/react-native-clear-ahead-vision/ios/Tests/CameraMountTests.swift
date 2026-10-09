import CoreVideo
import XCTest
import simd
@testable import ClearAheadVision

final class CameraMountTests: XCTestCase {
    private let upright = SIMD3<Double>(0, -1, 0)
    private let topLeft = SIMD3<Double>(-1, 0, 0)
    private let topRight = SIMD3<Double>(1, 0, 0)

    func testFirstReadingSettlesTheMountAtOnce() {
        var detector = MountDetector()
        XCTAssertNil(detector.mount)
        XCTAssertEqual(detector.update(gravity: topLeft, now: 0), .sidewaysLeft)
        var other = MountDetector()
        XCTAssertEqual(other.update(gravity: topRight, now: 0), .sidewaysRight)
        var third = MountDetector()
        XCTAssertEqual(third.update(gravity: upright, now: 0), .upright)
    }

    func testBriefTiltDoesNotFlipTheMountButAHeldOneDoes() {
        var detector = MountDetector()
        detector.update(gravity: upright, now: 0)
        detector.update(gravity: topRight, now: 1)
        XCTAssertEqual(detector.update(gravity: topRight, now: 1.3), .upright)
        XCTAssertEqual(detector.update(gravity: upright, now: 1.4), .upright)
        detector.update(gravity: topRight, now: 2)
        XCTAssertEqual(detector.update(gravity: topRight, now: 2 + MountDetector.settleSeconds), .sidewaysRight)
    }

    func testHalfwayTiltAndLyingFlatKeepTheMount() {
        var detector = MountDetector()
        detector.update(gravity: upright, now: 0)
        let tilted = SIMD3(sin(50 * Double.pi / 180), -cos(50 * Double.pi / 180), 0)
        detector.update(gravity: tilted, now: 1)
        XCTAssertEqual(detector.update(gravity: tilted, now: 3), .upright)
        detector.update(gravity: SIMD3(0, 0, -1), now: 4)
        XCTAssertEqual(detector.update(gravity: SIMD3(0, 0, -1), now: 6), .upright)
    }

    func testGravityPointsDownThePictureWhicheverWayThePhoneSits() {
        for (mount, gravity) in [(CameraMount.upright, upright), (.sidewaysLeft, topLeft), (.sidewaysRight, topRight)] {
            let down = mount.phoneToPicture.act(gravity)
            XCTAssertEqual(down.x, 0, accuracy: 1e-9, "\(mount)")
            XCTAssertEqual(down.y, -1, accuracy: 1e-9, "\(mount)")
            XCTAssertEqual(down.z, 0, accuracy: 1e-9, "\(mount)")
        }
    }

    func testSkyShowsTowardThePhonesTopEdgeOnScreen() {
        let left = CameraMount.sidewaysLeft.screenPoint(x: 0.5, y: 0)
        XCTAssertEqual(left.x, 1)
        XCTAssertEqual(left.y, 0.5)
        let right = CameraMount.sidewaysRight.screenPoint(x: 0.5, y: 0)
        XCTAssertEqual(right.x, 0)
        XCTAssertEqual(right.y, 0.5)
        let box = CameraMount.sidewaysLeft.screenBox(CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        XCTAssertEqual(box.minX, 0.4, accuracy: 1e-9)
        XCTAssertEqual(box.minY, 0.1, accuracy: 1e-9)
        XCTAssertEqual(box.width, 0.4, accuracy: 1e-9)
        XCTAssertEqual(box.height, 0.3, accuracy: 1e-9)
    }

    func testDepthMapTurnsToTheScreen() {
        let map = DepthMap(width: 3, height: 2, values: [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(map.turned(toScreen: .upright).values, map.values)
        let left = map.turned(toScreen: .sidewaysLeft)
        XCTAssertEqual(left.width, 2)
        XCTAssertEqual(left.height, 3)
        XCTAssertEqual(left.values, [3, 0, 4, 1, 5, 2])
        XCTAssertEqual(map.turned(toScreen: .sidewaysRight).values, [2, 5, 1, 4, 0, 3])
    }

    func testPathGridReadsTheUprightPictureForEachMount() throws {
        // The left half of the landscape buffer is bright.
        let buffer = try XCTUnwrap(pixelBuffer(width: 256, height: 192) { x, _ in x < 128 ? 240 : 10 })
        let feet = WalkablePath.rows - 1
        let edge = WalkablePath.columns - 1

        // Upright, the buffer's x runs down the picture: the bright half is above the ground rows.
        let uprightCells = try XCTUnwrap(WalkablePath.grid(from: buffer, mount: .upright))
        XCTAssertLessThan(uprightCells[feet * WalkablePath.columns].luma, 50)
        XCTAssertLessThan(uprightCells[feet * WalkablePath.columns + edge].luma, 50)

        // Top edge left, the buffer is already upright: the bright half is on the left.
        let leftCells = try XCTUnwrap(WalkablePath.grid(from: buffer, mount: .sidewaysLeft))
        XCTAssertGreaterThan(leftCells[feet * WalkablePath.columns].luma, 200)
        XCTAssertLessThan(leftCells[feet * WalkablePath.columns + edge].luma, 50)

        // Top edge right, the buffer is upside down: the bright half is on the right.
        let rightCells = try XCTUnwrap(WalkablePath.grid(from: buffer, mount: .sidewaysRight))
        XCTAssertLessThan(rightCells[feet * WalkablePath.columns].luma, 50)
        XCTAssertGreaterThan(rightCells[feet * WalkablePath.columns + edge].luma, 200)
    }

    private func pixelBuffer(width: Int, height: Int, luma: (Int, Int) -> UInt8) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  nil, &created) == kCVReturnSuccess, let buffer = created else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let lumaPlane = lumaBase.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width { lumaPlane[y * lumaStride + x] = luma(x, y) }
        }
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        memset(chromaBase, 128, chromaStride * chromaHeight)
        return buffer
    }
}
