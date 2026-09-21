import XCTest
@testable import ClearAheadVision

final class EventPrioritizerTests: XCTestCase {
    private var configuration = FeedbackConfiguration()

    func testFiltersLowConfidenceAndDistantEvents() {
        let prioritizer = EventPrioritizer()
        let lowConfidence = makeEvent(confidence: 0.1)
        let distant = makeEvent(distance: 10)
        configuration.warningDistanceMeters = 6

        XCTAssertNil(
            prioritizer.select(
                from: [lowConfidence, distant],
                configuration: configuration,
                now: 10
            )
        )
    }

    func testCloseCenterObstacleOutranksPeripheralPerson() {
        let prioritizer = EventPrioritizer()
        let obstacle = makeEvent(
            id: "obstacle:center",
            kind: .obstacle,
            direction: .center,
            distance: 1.2,
            confidence: 0.82
        )
        let person = makeEvent(
            id: "person:left",
            kind: .person,
            direction: .left,
            distance: 4,
            confidence: 0.95
        )

        let selected = prioritizer.select(
            from: [person, obstacle],
            configuration: configuration,
            now: 10
        )

        XCTAssertEqual(selected?.id, obstacle.id)
    }

    func testCooldownPreventsCueStorms() {
        let prioritizer = EventPrioritizer()
        let event = makeEvent(distance: 1.4)

        XCTAssertNotNil(prioritizer.select(from: [event], configuration: configuration, now: 10))
        XCTAssertNil(prioritizer.select(from: [event], configuration: configuration, now: 10.1))
        XCTAssertNotNil(prioritizer.select(from: [event], configuration: configuration, now: 12))
    }

    func testImminentCollisionPreemptsCloserOrdinaryEvent() {
        let prioritizer = EventPrioritizer()
        let ordinary = makeEvent(id: "person:center", distance: 0.8)
        let collision = makeEvent(
            id: "vehicle:right",
            kind: .vehicle,
            direction: .right,
            distance: 2.5,
            collisionRisk: .imminent
        )

        let selected = prioritizer.select(
            from: [ordinary, collision],
            configuration: configuration,
            now: 10
        )

        XCTAssertEqual(selected?.id, collision.id)
    }

    func testPrioritizerDoesNotRetainAStaleCollisionClassification() {
        let prioritizer = EventPrioritizer()
        let collision = makeEvent(collisionRisk: .imminent)
        let cleared = makeEvent(collisionRisk: .none)

        XCTAssertEqual(
            prioritizer.select(from: [collision], configuration: configuration, now: 10)?.collisionRisk,
            .imminent
        )
        XCTAssertEqual(
            prioritizer.select(from: [cleared], configuration: configuration, now: 11)?.collisionRisk,
            .none
        )
    }

    func testDepthSectorsStaySilentUntilTheyBecomeCollisionWarnings() {
        let prioritizer = EventPrioritizer()
        let ordinaryDepth = makeEvent(
            id: "depth:center",
            kind: .obstacle,
            distance: 1.5
        )
        let riskyDepth = makeEvent(
            id: "depth:center",
            kind: .obstacle,
            distance: 1.5,
            collisionRisk: .caution
        )

        XCTAssertNil(
            prioritizer.select(
                from: [ordinaryDepth],
                configuration: configuration,
                now: 10
            )
        )
        XCTAssertNotNil(
            prioritizer.select(
                from: [riskyDepth],
                configuration: configuration,
                now: 11
            )
        )
    }

    func testHysteresisRetainsSelectionButUsesFreshEventData() throws {
        let prioritizer = EventPrioritizer()
        let initial = makeEvent(id: "person:center", distance: 1.5)
        let updated = makeEvent(id: "person:center", distance: 1.8)

        _ = prioritizer.select(from: [initial], configuration: configuration, now: 10)
        let selected = try XCTUnwrap(
            prioritizer.select(from: [updated], configuration: configuration, now: 12)
        )

        XCTAssertEqual(selected.approximateDistanceMeters, 1.8)
        XCTAssertEqual(selected.id, initial.id)
    }

    func testConfigurationClampsUnsafeInputRanges() {
        let parsed = FeedbackConfiguration(dictionary: [
            "hapticIntensity": 3.0,
            "audioVolume": -1.0,
            "warningDistanceMeters": 100.0,
            "feedbackFrequency": Double.nan,
            "mountingMode": "unsupported",
            "spokenCategories": ["person", "unsupported"],
        ])

        XCTAssertEqual(parsed.hapticIntensity, 1)
        XCTAssertEqual(parsed.audioVolume, 0)
        XCTAssertEqual(parsed.warningDistanceMeters, 12)
        XCTAssertEqual(parsed.feedbackFrequency, 0.55)
        XCTAssertEqual(parsed.mountingMode, "handheld")
        XCTAssertEqual(parsed.spokenCategories, Set(["person"]))
    }

    func testAudioCuePitchRisesAsObjectsGetCloser() {
        let far = AudioCueProfile(event: makeEvent(distance: 5.5), configuration: configuration)
        let near = AudioCueProfile(event: makeEvent(distance: 1), configuration: configuration)

        XCTAssertGreaterThan(near.startFrequency, far.startFrequency)
    }

    func testAudioCueRhythmAcceleratesWithUrgency() {
        var lowUrgencyEvent = makeEvent()
        lowUrgencyEvent.urgency = 0.2
        var highUrgencyEvent = makeEvent()
        highUrgencyEvent.urgency = 0.9

        let low = AudioCueProfile(event: lowUrgencyEvent, configuration: configuration)
        let high = AudioCueProfile(event: highUrgencyEvent, configuration: configuration)

        XCTAssertEqual(low.pulseCount, 1)
        XCTAssertEqual(high.pulseCount, 3)
        XCTAssertLessThan(high.pulseGap, low.pulseGap)
    }

    func testAudioCueUsesPitchContourAndPanForDirection() {
        let left = AudioCueProfile(
            event: makeEvent(id: "person:left", direction: .left),
            configuration: configuration
        )
        let center = AudioCueProfile(event: makeEvent(), configuration: configuration)
        let right = AudioCueProfile(
            event: makeEvent(id: "person:right", direction: .right),
            configuration: configuration
        )

        XCTAssertGreaterThan(left.startFrequency, left.endFrequency)
        XCTAssertEqual(center.startFrequency, center.endFrequency)
        XCTAssertLessThan(right.startFrequency, right.endFrequency)
        XCTAssertLessThan(left.pan, center.pan)
        XCTAssertGreaterThan(right.pan, center.pan)
    }

    private func makeEvent(
        id: String = "person:center",
        kind: EventKind = .person,
        direction: Direction = .center,
        distance: Double = 2,
        confidence: Double = 0.9,
        collisionRisk: CollisionRisk = .none
    ) -> SpatialEvent {
        SpatialEvent(
            id: id,
            kind: kind,
            direction: direction,
            proximity: Proximity.from(distance: distance),
            approximateDistanceMeters: distance,
            approachSpeed: 0,
            collisionRisk: collisionRisk,
            timeToCollisionSeconds: collisionRisk == .none ? nil : 1,
            trajectoryConfidence: collisionRisk == .none ? 0 : 0.9,
            confidence: confidence,
            urgency: 0,
            timestamp: 10,
            box: nil
        )
    }
}
