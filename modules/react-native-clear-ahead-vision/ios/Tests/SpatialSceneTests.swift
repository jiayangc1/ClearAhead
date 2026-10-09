import XCTest
import simd
@testable import ClearAheadVision

final class SpatialSceneTests: XCTestCase {
    private let geometry = CameraGeometry(fx: 1, fy: 1, cx: 0.5, cy: 0.5)
    private let gravity = SIMD3<Double>(0, -1, 0)
    private let configuration = FeedbackConfiguration()

    func testWallPersonAndLowChairRemainSimultaneous() throws {
        var values = [Double](repeating: 9, count: 32 * 48)
        paint(&values, x: 25..<32, y: 0..<48, depth: 2.2)
        paint(&values, x: 4..<9, y: 8..<31, depth: 1.8)
        paint(&values, x: 12..<18, y: 32..<46, depth: 0.9)
        let person = event("person", kind: .person, box: box(x: 4..<9, y: 8..<31), distance: 1.8)
        let chair = event("chair", kind: .furniture, box: box(x: 12..<18, y: 32..<46), distance: 0.9)
        let scene = build(values, objects: [person, chair])
        let selected = SceneSelector().select(scene, now: 10, range: 6)
        XCTAssertEqual(selected.count, 3)
        XCTAssertEqual(Set(selected.map { $0.event.kind.rawValue }), Set(["person", "furniture", "obstacle"]))
        let wall = try XCTUnwrap(selected.first { $0.isSurface })
        let visiblePerson = try XCTUnwrap(selected.first { $0.event.kind == .person })
        let visibleChair = try XCTUnwrap(selected.first { $0.event.kind == .furniture })
        XCTAssertGreaterThan(wall.position!.x, 0)
        XCTAssertLessThan(visiblePerson.position!.x, 0)
        XCTAssertLessThan(visibleChair.position!.y, visiblePerson.position!.y)
        XCTAssertEqual(wall.contours.count, 1)
        XCTAssertGreaterThan(wall.event.box!.height, 0.95)
    }

    func testChairHiddenByTableNeverAddsGeometryOrLabel() {
        var values = [Double](repeating: 9, count: 32 * 48)
        paint(&values, x: 8..<24, y: 20..<43, depth: 1.2)
        let table = event("table", kind: .furniture, box: box(x: 8..<24, y: 20..<43), distance: 1.2)
        let chair = event("chair", kind: .furniture, box: box(x: 10..<20, y: 22..<40), distance: 3)
        let scene = build(values, objects: [table, chair])
        XCTAssertEqual(scene.count, 1)
        XCTAssertEqual(scene.first?.event.label, "table")
        XCTAssertFalse(scene.contains { $0.event.label == "chair" })
    }

    func testVisibleContoursKeepOcclusionHoleAndDoNotTileWallIntoManySources() {
        var values = [Double](repeating: 2.2, count: 32 * 48)
        paint(&values, x: 10..<22, y: 12..<36, depth: 1)
        let scene = build(values)
        XCTAssertEqual(scene.count, 2)
        let wall = scene.max { $0.event.box!.width * $0.event.box!.height < $1.event.box!.width * $1.event.box!.height }!
        XCTAssertEqual(wall.contours.count, 2)
        XCTAssertTrue(wall.contours.allSatisfy { $0.count == 4 })
    }

    func testSelectionKeepsIdentityAndDoesNotSwitchForTinyRankChanges() {
        let selector = SceneSelector()
        let candidates = (0..<7).map { i in
            source(box: CGRect(x: Double(i) * 0.13, y: 0.2, width: 0.1, height: 0.3), distance: 2 + Double(i) * 0.02)
        }
        let first = selector.select(candidates, now: 10, range: 6)
        XCTAssertEqual(first.count, 6)
        let reversed = selector.select(Array(candidates.reversed()), now: 10.3, range: 6)
        XCTAssertEqual(Set(first.map { $0.event.id }), Set(reversed.map { $0.event.id }))
        XCTAssertTrue(selector.select([], now: 10.6, range: 6).isEmpty)
        // Disappearing/occluded candidates never remain selected merely for hysteresis.
    }

    func testUrgentNewSourceDisplacesOrdinaryScenery() {
        let selector = SceneSelector()
        var candidates = (0..<6).map { i in source(box: CGRect(x: Double(i) * 0.14, y: 0.3, width: 0.1, height: 0.2), distance: 1) }
        _ = selector.select(candidates, now: 10, range: 6)
        candidates.append(source(box: CGRect(x: 0.86, y: 0.3, width: 0.1, height: 0.2), distance: 4, risk: .imminent))
        XCTAssertTrue(selector.select(candidates, now: 10.3, range: 6).contains { $0.event.collisionRisk == .imminent })
    }

    func testCameraAndHeadTransformsPreserveObservedDirection() {
        let headphoneUp = SceneAudioMath.audioToHeadphoneAxes.act(SIMD3<Double>(0, 1, 0))
        XCTAssertEqual(headphoneUp.z, 1, accuracy: 0.001)
        let headphoneForward = SceneAudioMath.audioToHeadphoneAxes.act(SIMD3<Double>(0, 0, -1))
        XCTAssertEqual(headphoneForward.y, 1, accuracy: 0.001)
        let identity = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))
        let ahead = SIMD3<Double>(0, 0, -2)
        let leftTurn = simd_quatd(angle: .pi / 2, axis: SIMD3(0, 1, 0))
        let heard = SceneAudioMath.listenerPoint(ahead, camera: identity, head: leftTurn, alignment: identity)
        XCTAssertEqual(heard.x, 2, accuracy: 0.001)
        XCTAssertEqual(heard.z, 0, accuracy: 0.001)
        let bothTurn = SceneAudioMath.listenerPoint(ahead, camera: leftTurn, head: leftTurn, alignment: identity)
        XCTAssertEqual(bothTurn.z, -2, accuracy: 0.001)
        let behind = SceneAudioMath.listenerPoint(ahead, camera: identity,
                                                  head: simd_quatd(angle: .pi, axis: SIMD3(0, 1, 0)), alignment: identity)
        XCTAssertGreaterThan(behind.z, 0)
        let low = geometry.point(x: 0.5, y: 0.8, depth: 1)
        XCTAssertLessThan(low.y, 0)
    }

    func testListenerOriginUsesMeasuredCameraToEarOffset() {
        var configuration = FeedbackConfiguration()
        configuration.cameraHeightMeters = 1.2
        configuration.earHeightMeters = 1.7
        configuration.cameraForwardOffsetMeters = 0.25
        configuration.cameraRightOffsetMeters = -0.1
        let point = SceneAudioMath.earPoint(SIMD3(0, 0, -2), gravity: gravity, configuration: configuration)
        XCTAssertEqual(point.x, -0.1, accuracy: 0.001)
        XCTAssertEqual(point.y, -0.5, accuracy: 0.001)
        XCTAssertEqual(point.z, -2.25, accuracy: 0.001)
    }

    func testPlaneAloneNeverChangesAbsoluteScaleAndHeightCalibrationSlews() throws {
        let map = floor(height: 1.2)
        var ground = GroundNormalizer()
        for _ in 0..<4 { ground.update(map: map, geometry: geometry, gravity: gravity, cameraHeight: 0, stable: true) }
        XCTAssertEqual(try XCTUnwrap(ground.plane).height, 1.2, accuracy: 0.02)
        XCTAssertEqual(ground.scale, 1)
        XCTAssertEqual(ground.status, "ground-consistent-model-estimate")
        for _ in 0..<12 {
            let previous = ground.scale
            ground.update(map: map, geometry: geometry, gravity: gravity, cameraHeight: 1.44, stable: true)
            XCTAssertLessThanOrEqual(abs(ground.scale - previous), 0.010001)
        }
        XCTAssertGreaterThan(ground.scale, 1)
        XCTAssertLessThan(ground.scale, 1.2)
    }

    func testMissingGroundStairsSlopeAndTiltNeverInventNormalization() {
        var ground = GroundNormalizer()
        for _ in 0..<4 { ground.update(map: floor(height: 1.2), geometry: geometry, gravity: gravity, cameraHeight: 1.4, stable: true) }
        let scale = ground.scale
        let wall = DepthMap(width: 32, height: 48, values: [Double](repeating: 3, count: 32 * 48))
        ground.update(map: wall, geometry: geometry, gravity: gravity, cameraHeight: 1.4, stable: true)
        XCTAssertNil(ground.plane)
        XCTAssertEqual(ground.scale, scale)
        ground.update(map: floor(height: 1.2), geometry: nil, gravity: nil, cameraHeight: 1.4, stable: true)
        XCTAssertNil(ground.plane)
        ground.update(map: floor(height: 1.2), geometry: geometry, gravity: gravity, cameraHeight: 1.4, stable: false)
        XCTAssertNil(ground.plane)
        for _ in 0..<4 { ground.update(map: floor(height: 1.2, slope: 20), geometry: geometry, gravity: gravity, cameraHeight: 1.4, stable: true) }
        XCTAssertNil(ground.plane)
        XCTAssertEqual(ground.scale, scale)
        let stairs = floor(height: 1.2, stairs: true)
        for _ in 0..<4 { ground.update(map: stairs, geometry: geometry, gravity: gravity, cameraHeight: 1.4, stable: true) }
        XCTAssertNil(ground.plane)
        XCTAssertEqual(ground.scale, scale)
    }

    private func floor(height: Double, slope: Double = 0, stairs: Bool = false) -> DepthMap {
        let radians = slope * .pi / 180
        let values = (0..<(32 * 48)).map { index -> Double in
            let row = index / 32
            let y = (Double(row) + 0.5) / 48
            guard y > 0.5 else { return 15 }
            let h = stairs ? height + Double((row - 24) / 6) * 0.4 : height
            return h / ((y - 0.5) * cos(radians) + sin(radians))
        }
        return DepthMap(width: 32, height: 48, values: values)
    }

    private func build(_ values: [Double], objects: [SpatialEvent] = []) -> [SceneSource] {
        SceneBuilder.build(map: DepthMap(width: 32, height: 48, values: values), objects: objects, hazards: [],
                           geometry: geometry, gravity: gravity, ground: GroundNormalizer(), configuration: configuration, now: 10)
    }

    private func paint(_ values: inout [Double], x: Range<Int>, y: Range<Int>, depth: Double) {
        for row in y { for column in x { values[row * 32 + column] = depth } }
    }

    private func box(x: Range<Int>, y: Range<Int>) -> CGRect {
        CGRect(x: Double(x.lowerBound) / 32, y: 1 - Double(y.upperBound) / 48,
               width: Double(x.count) / 32, height: Double(y.count) / 48)
    }

    private func event(_ id: String, kind: EventKind = .obstacle, box: CGRect, distance: Double, risk: CollisionRisk = .none) -> SpatialEvent {
        SpatialEvent(id: id, kind: kind, label: id, direction: .from(horizontalMidpoint: box.midX),
                     proximity: .from(distance: distance), approximateDistanceMeters: distance, approachSpeed: 0,
                     collisionRisk: risk, confidence: 0.9, urgency: 0, timestamp: 10, box: box)
    }

    private func source(box: CGRect, distance: Double, risk: CollisionRisk = .none) -> SceneSource {
        SceneSource(event: event("surface", box: box, distance: distance, risk: risk), position: nil,
                    contours: [], visibility: 1, isSurface: true)
    }
}
