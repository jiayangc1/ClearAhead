import XCTest
@testable import ClearAheadVision

final class EventPrioritizerTests: XCTestCase {
    private var configuration = CAFeedbackConfiguration()

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

    func testConfigurationClampsUnsafeInputRanges() {
        let parsed = CAFeedbackConfiguration(dictionary: [
            "hapticIntensity": 3.0,
            "audioVolume": -1.0,
            "warningDistanceMeters": 100.0,
        ])

        XCTAssertEqual(parsed.hapticIntensity, 1)
        XCTAssertEqual(parsed.audioVolume, 0)
        XCTAssertEqual(parsed.warningDistanceMeters, 12)
    }

    private func makeEvent(
        id: String = "person:center",
        kind: CAEventKind = .person,
        direction: CADirection = .center,
        distance: Double = 2,
        confidence: Double = 0.9
    ) -> CASpatialEvent {
        CASpatialEvent(
            id: id,
            kind: kind,
            direction: direction,
            proximity: CAProximity.from(distance: distance),
            approximateDistanceMeters: distance,
            approachSpeed: 0,
            confidence: confidence,
            urgency: 0,
            timestamp: 10,
            box: nil
        )
    }
}
