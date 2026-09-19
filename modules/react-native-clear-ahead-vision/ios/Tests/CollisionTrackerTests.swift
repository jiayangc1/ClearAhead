import XCTest
@testable import ClearAheadVision

final class CollisionTrackerTests: XCTestCase {
    private var configuration = CAFeedbackConfiguration()

    override func setUp() {
        super.setUp()
        configuration.sensitivity = 1
    }

    func testAssociatesTwoPeopleInSameSectorWithoutMergingTracks() {
        let tracker = CollisionTracker()
        let first = tracker.update(
            detections: [detection(x: 0.08), detection(x: 0.26)],
            now: 1,
            configuration: configuration,
            rotationRate: 0
        )
        let second = tracker.update(
            detections: [detection(x: 0.10), detection(x: 0.28)],
            now: 1.15,
            configuration: configuration,
            rotationRate: 0
        )

        XCTAssertEqual(Set(first.map(\.id)), Set(second.map(\.id)))
        XCTAssertEqual(Set(second.map(\.id)).count, 2)
    }

    func testClosingTrackProducesSmoothedTimeToCollisionAndImminentRisk() {
        let tracker = CollisionTracker()
        var latest: CASpatialEvent?
        for (index, distance) in [4.0, 3.0, 2.0, 1.0].enumerated() {
            latest = tracker.update(
                detections: [detection(x: 0.41, distance: distance)],
                now: 1 + Double(index) * 0.5,
                configuration: configuration,
                rotationRate: 0
            ).first
        }

        XCTAssertEqual(latest?.motionState, .approaching)
        XCTAssertEqual(latest?.collisionRisk, .imminent)
        XCTAssertGreaterThan(latest?.approachSpeed ?? 0, 0)
        XCTAssertLessThan(latest?.timeToCollisionSeconds ?? 99, 1.5)
    }

    func testRapidCameraRotationSuppressesCollisionRisk() {
        let tracker = CollisionTracker()
        var latest: CASpatialEvent?
        for (index, distance) in [3.0, 2.0, 1.0].enumerated() {
            latest = tracker.update(
                detections: [detection(x: 0.41, distance: distance)],
                now: 1 + Double(index) * 0.4,
                configuration: configuration,
                rotationRate: 1.4
            ).first
        }

        XCTAssertEqual(latest?.collisionRisk, .none)
        XCTAssertLessThan(latest?.trajectoryConfidence ?? 1, 0.65)
    }

    func testLateralTrajectoryIsClassifiedAsCrossing() {
        let tracker = CollisionTracker()
        var latest: CASpatialEvent?
        for (index, x) in [0.05, 0.14, 0.23].enumerated() {
            latest = tracker.update(
                detections: [detection(x: x, distance: 3)],
                now: 1 + Double(index) * 0.25,
                configuration: configuration,
                rotationRate: 0
            ).first
        }

        XCTAssertEqual(latest?.motionState, .crossing)
        XCTAssertEqual(latest?.collisionRisk, .none)
    }

    func testExpiredTrackGetsANewStableIdentifier() {
        let tracker = CollisionTracker()
        let first = tracker.update(
            detections: [detection(x: 0.4)],
            now: 1,
            configuration: configuration,
            rotationRate: 0
        ).first
        let replacement = tracker.update(
            detections: [detection(x: 0.4)],
            now: 2,
            configuration: configuration,
            rotationRate: 0
        ).first

        XCTAssertNotEqual(first?.id, replacement?.id)
    }

    func testCollisionRiskUsesShortExitHysteresis() {
        let tracker = CollisionTracker()
        for (index, distance) in [3.0, 2.0, 1.0].enumerated() {
            _ = tracker.update(
                detections: [detection(x: 0.41, distance: distance)],
                now: 1 + Double(index) * 0.4,
                configuration: configuration,
                rotationRate: 0
            )
        }
        let retained = tracker.update(
            detections: [detection(x: 0.41, distance: 2.5)],
            now: 1.9,
            configuration: configuration,
            rotationRate: 0
        ).first

        XCTAssertNotEqual(retained?.collisionRisk, .none)
    }

    private func detection(
        x: CGFloat,
        distance: Double = 3,
        confidence: Double = 0.95
    ) -> CAObjectDetection {
        CAObjectDetection(
            kind: .person,
            box: CGRect(x: x, y: 0.2, width: 0.16, height: 0.46),
            distanceMeters: distance,
            confidence: confidence
        )
    }
}
