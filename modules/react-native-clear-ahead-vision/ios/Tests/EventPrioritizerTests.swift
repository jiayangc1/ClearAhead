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
