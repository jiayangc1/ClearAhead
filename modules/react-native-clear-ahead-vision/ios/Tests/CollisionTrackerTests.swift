import XCTest
@testable import ClearAheadVision

final class CollisionTrackerTests: XCTestCase {
    private var configuration = FeedbackConfiguration()

    override func setUp() {
        super.setUp()
        configuration.sensitivity = 1
    }

    func testVehicleClassJitterKeepsIdentity() {
        let tracker = CollisionTracker()
        let car = ObjectDetection(kind: .vehicle, label: "car", box: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.4),
                                  depth: DepthMeasurement(distanceMeters: 3, timestamp: 1), confidence: 0.95)
        let truck = ObjectDetection(kind: .vehicle, label: "truck", box: car.box,
                                    depth: DepthMeasurement(distanceMeters: 2.8, timestamp: 1.2), confidence: 0.95)
        let first = tracker.update(detections: [car], now: 1, configuration: configuration, rotationRate: 0).first
        let second = tracker.update(detections: [truck], now: 1.2, configuration: configuration, rotationRate: 0).first
        XCTAssertEqual(first?.id, second?.id)
        XCTAssertEqual(second?.label, "truck")
    }

    func testGlobalAssignmentPreservesConstrainedTrack() {
        let tracker = CollisionTracker()
        let first = tracker.update(detections: [detection(x: 0.1), detection(x: 0.35)],
                                   now: 1, configuration: configuration, rotationRate: 0)
        let next = tracker.update(detections: [detection(x: 0.2, confidence: 0.99), detection(x: 0.08, confidence: 0.8)],
                                  now: 1.2, configuration: configuration, rotationRate: 0)
        XCTAssertEqual(next[0].id, first[1].id)
        XCTAssertEqual(next[1].id, first[0].id)
    }

    func testShortOcclusionKeepsTrackIdentity() {
        let tracker = CollisionTracker()
        let first = tracker.update(detections: [detection(x: 0.4)], now: 1,
                                   configuration: configuration, rotationRate: 0).first
        _ = tracker.update(detections: [], now: 1.2, configuration: configuration, rotationRate: 0)
        let next = tracker.update(detections: [detection(x: 0.42, depthTime: 1.4)], now: 1.4,
                                  configuration: configuration, rotationRate: 0).first
        XCTAssertEqual(first?.id, next?.id)
    }

    func testConstantDepthCrossingProducesCorridorEntryCaution() {
        let tracker = CollisionTracker()
        var latest: SpatialEvent?
        for (index, x) in [0.02, 0.08, 0.14].enumerated() {
            let now = 1 + Double(index) * 0.2
            latest = tracker.update(detections: [detection(x: x, distance: 2, depthTime: now)],
                                    now: now, configuration: configuration, rotationRate: 0).first
        }
        XCTAssertEqual(latest?.motionState, .crossing)
        XCTAssertEqual(latest?.collisionRisk, .caution)
        // Corridor entry is not a measured physical time-to-impact.
        XCTAssertNil(latest?.timeToCollisionSeconds)
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
        var latest: SpatialEvent?
        for (index, distance) in [4.0, 3.0, 2.0, 1.0].enumerated() {
            latest = tracker.update(
                detections: [detection(x: 0.41, distance: distance, depthTime: 1 + Double(index) * 0.5)],
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

    func testRepeatedDepthFrameDoesNotCreateClosingSpeed() {
        let tracker = CollisionTracker()
        _ = tracker.update(
            detections: [detection(x: 0.41, distance: 3, depthTime: 1)],
            now: 1,
            configuration: configuration,
            rotationRate: 0
        )
        let repeated = tracker.update(
            detections: [detection(x: 0.41, distance: 3, depthTime: 1)],
            now: 1.1,
            configuration: configuration,
            rotationRate: 0
        ).first
        let fresh = tracker.update(
            detections: [detection(x: 0.41, distance: 2, depthTime: 1.5)],
            now: 1.55,
            configuration: configuration,
            rotationRate: 0
        ).first

        XCTAssertEqual(repeated?.approachSpeed, 0)
        XCTAssertGreaterThan(fresh?.approachSpeed ?? 0, 0)
        XCTAssertLessThan(fresh?.approachSpeed ?? 99, 1)
    }

    func testNamedDetectionWithoutDepthHasNoCollisionTiming() {
        let tracker = CollisionTracker()
        var latest: SpatialEvent?
        for (index, height) in [0.2, 0.3, 0.5, 0.8].enumerated() {
            latest = tracker.update(
                detections: [ObjectDetection(
                    kind: .person,
                    box: CGRect(x: 0.4, y: 0.1, width: 0.2, height: height),
                    depth: nil,
                    confidence: 0.95
                )],
                now: 1 + Double(index) * 0.2,
                configuration: configuration,
                rotationRate: 0
            ).first
        }

        XCTAssertEqual(latest?.kind, .person)
        XCTAssertNil(latest?.timeToCollisionSeconds)
        XCTAssertEqual(latest?.collisionRisk, .none)
    }

    func testRapidCameraRotationSuppressesCollisionRisk() {
        let tracker = CollisionTracker()
        var latest: SpatialEvent?
        for (index, distance) in [3.0, 2.0, 1.0].enumerated() {
            latest = tracker.update(
                detections: [detection(x: 0.41, distance: distance, depthTime: 1 + Double(index) * 0.4)],
                now: 1 + Double(index) * 0.4,
                configuration: configuration,
                rotationRate: 1.4
            ).first
        }

        XCTAssertEqual(latest?.collisionRisk, .none)
        XCTAssertLessThan(latest?.trajectoryConfidence ?? 1, 0.65)
    }

    func testDistantLateralTrajectoryIsClassifiedAsCrossing() {
        let tracker = CollisionTracker()
        var latest: SpatialEvent?
        for (index, x) in [0.05, 0.14, 0.23].enumerated() {
            latest = tracker.update(
                detections: [detection(x: x, distance: 5)],
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
                detections: [detection(x: 0.41, distance: distance, depthTime: 1 + Double(index) * 0.4)],
                now: 1 + Double(index) * 0.4,
                configuration: configuration,
                rotationRate: 0
            )
        }
        let retained = tracker.update(
            detections: [detection(x: 0.41, distance: 2.5, depthTime: 1.9)],
            now: 1.9,
            configuration: configuration,
            rotationRate: 0
        ).first

        XCTAssertNotEqual(retained?.collisionRisk, .none)
    }

    func testDepthTimeoutClearsCollisionTiming() {
        let tracker = CollisionTracker()
        for (index, distance) in [3.0, 2.0, 1.0].enumerated() {
            let time = 1 + Double(index) * 0.2
            _ = tracker.update(
                detections: [detection(x: 0.41, distance: distance, depthTime: time)],
                now: time,
                configuration: configuration,
                rotationRate: 0
            )
        }
        let stale = tracker.update(
            detections: [ObjectDetection(
                kind: .person,
                box: CGRect(x: 0.41, y: 0.2, width: 0.16, height: 0.46),
                depth: nil,
                confidence: 0.95
            )],
            now: 2,
            configuration: configuration,
            rotationRate: 0
        ).first
        XCTAssertNil(stale?.timeToCollisionSeconds)
        XCTAssertEqual(stale?.collisionRisk, .none)
    }

    func testFirstDepthAfterOutageResetsClosingSpeed() {
        let tracker = CollisionTracker()
        _ = tracker.update(
            detections: [detection(x: 0.41, distance: 3, depthTime: 1)],
            now: 1, configuration: configuration, rotationRate: 0
        )
        for time in stride(from: 1.5, through: 3.5, by: 0.5) {
            _ = tracker.update(
                detections: [ObjectDetection(
                    kind: .person,
                    box: CGRect(x: 0.41, y: 0.2, width: 0.16, height: 0.46),
                    depth: nil,
                    confidence: 0.95
                )],
                now: time, configuration: configuration, rotationRate: 0
            )
        }
        let recovered = tracker.update(
            detections: [detection(x: 0.41, distance: 1, depthTime: 4)],
            now: 4, configuration: configuration, rotationRate: 0
        ).first
        XCTAssertEqual(recovered?.approachSpeed, 0)
        XCTAssertNil(recovered?.timeToCollisionSeconds)
        XCTAssertNotEqual(recovered?.motionState, .approaching)

        let next = tracker.update(
            detections: [detection(x: 0.41, distance: 0.8, depthTime: 4.3)],
            now: 4.3, configuration: configuration, rotationRate: 0
        ).first
        XCTAssertGreaterThan(next?.approachSpeed ?? 0, 0)
    }

    private func detection(
        x: CGFloat,
        distance: Double = 3,
        depthTime: TimeInterval? = nil,
        confidence: Double = 0.95
    ) -> ObjectDetection {
        ObjectDetection(
            kind: .person,
            box: CGRect(x: x, y: 0.2, width: 0.16, height: 0.46),
            depth: DepthMeasurement(distanceMeters: distance, timestamp: depthTime ?? 1),
            confidence: confidence
        )
    }
}
