import XCTest
@testable import ClearAheadVision

final class EventPrioritizerTests: XCTestCase {
    private var configuration = FeedbackConfiguration()

    func testUnknownDistanceKeepsFeedback() {
        let prioritizer = EventPrioritizer()
        let event = SpatialEvent(id: "distant-person", kind: .person, direction: .center, proximity: .unknown,
                                 approximateDistanceMeters: nil, approachSpeed: 0, confidence: 0.95,
                                 urgency: 0, timestamp: 10, box: nil)
        let selected = prioritizer.select(from: [event], configuration: configuration, now: 10)
        XCTAssertNotNil(selected)
        XCTAssertTrue(prioritizer.shouldAnnounce(selected, now: 10))
    }

    func testUnknownDistanceKeepsConfiguredSpeech() {
        var configuration = FeedbackConfiguration()
        configuration.speechEnabled = true
        let event = SpatialEvent(id: "person", kind: .person, direction: .center, proximity: .unknown,
                                 approximateDistanceMeters: nil, approachSpeed: 0, confidence: 0.95,
                                 urgency: 0.3, timestamp: 10, box: nil)
        XCTAssertTrue(Feedback.shouldSpeak(event, configuration: configuration, voiceOverRunning: false))
        configuration.speechEnabled = false
        XCTAssertFalse(Feedback.shouldSpeak(event, configuration: configuration, voiceOverRunning: false))
    }

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
            confidence: 0.82,
            collisionRisk: .caution
        )
        let person = makeEvent(
            id: "person:left",
            kind: .person,
            direction: .left,
            distance: 4,
            confidence: 0.95,
            collisionRisk: .caution
        )

        let selected = prioritizer.select(
            from: [person, obstacle],
            configuration: configuration,
            now: 10
        )

        XCTAssertEqual(selected?.id, obstacle.id)
    }

    func testSameHazardCuesAgainOnlyWhenRiskRises() {
        let prioritizer = EventPrioritizer()
        let event = makeEvent(distance: 1.4, collisionRisk: .caution)

        let first = prioritizer.select(from: [event], configuration: configuration, now: 10)
        XCTAssertTrue(prioritizer.shouldAnnounce(first, now: 10))
        let repeated = prioritizer.select(from: [event], configuration: configuration, now: 12)
        XCTAssertFalse(prioritizer.shouldAnnounce(repeated, now: 12))
        let approaching = makeEvent(distance: 1.4, collisionRisk: .caution, motionState: .approaching)
        let measured = prioritizer.select(from: [approaching], configuration: configuration, now: 12.5)
        XCTAssertTrue(prioritizer.shouldAnnounce(measured, now: 12.5))
        let urgent = makeEvent(distance: 1.4, collisionRisk: .imminent, motionState: .approaching)
        let escalated = prioritizer.select(from: [urgent], configuration: configuration, now: 13)
        XCTAssertTrue(prioritizer.shouldAnnounce(escalated, now: 13))
    }

    func testImminentCollisionBeyondWarningRangeIsKept() {
        let prioritizer = EventPrioritizer()
        configuration.warningDistanceMeters = 3
        let collision = makeEvent(distance: 4, collisionRisk: .imminent)
        XCTAssertNotNil(prioritizer.select(from: [collision], configuration: configuration, now: 10))
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
        XCTAssertNil(prioritizer.select(from: [cleared], configuration: configuration, now: 11))
    }

    func testObstructionWithoutPredictedCollisionStaysSilent() {
        let prioritizer = EventPrioritizer()
        let wallAhead = makeEvent(id: "depth:path", kind: .obstacle, distance: 1.5)
        let nearbyPerson = makeEvent(id: "person:left", direction: .left, distance: 1.2)
        XCTAssertNil(
            prioritizer.select(from: [wallAhead, nearbyPerson], configuration: configuration, now: 10)
        )
        XCTAssertFalse(prioritizer.hasActiveEvent)
    }

    func testDepthPathOnCollisionCourseIsSelected() {
        let prioritizer = EventPrioritizer()
        let wallAhead = makeEvent(id: "depth:path", kind: .obstacle, distance: 1.5, collisionRisk: .imminent)
        XCTAssertEqual(
            prioritizer.select(from: [wallAhead], configuration: configuration, now: 10)?.id,
            wallAhead.id
        )
    }

    func testWeakNamedDetectionDoesNotHideDepthObstacle() {
        let prioritizer = EventPrioritizer()
        let box = CGRect(x: 0.35, y: 0.2, width: 0.3, height: 0.5)
        let weakNamed = makeEvent(id: "person:center", distance: 1.5, confidence: 0.1, box: box)
        let generic = makeEvent(id: "depth:path", kind: .obstacle, distance: 1.6, collisionRisk: .caution, box: box)
        XCTAssertEqual(
            prioritizer.select(from: [generic, weakNamed], configuration: configuration, now: 10)?.id,
            generic.id
        )
    }

    func testBriefDepthDropoutDoesNotRepeatSameWarning() {
        let prioritizer = EventPrioritizer()
        let obstacle = makeEvent(id: "depth:path", kind: .obstacle, distance: 1.6, collisionRisk: .caution)
        let first = prioritizer.select(from: [obstacle], configuration: configuration, now: 10)
        XCTAssertTrue(prioritizer.shouldAnnounce(first, now: 10))
        XCTAssertNil(prioritizer.select(from: [], configuration: configuration, now: 10.5))
        let returned = prioritizer.select(from: [obstacle], configuration: configuration, now: 10.8)
        XCTAssertFalse(prioritizer.shouldAnnounce(returned, now: 10.8))
    }

    func testHysteresisRetainsSelectionButUsesFreshEventData() throws {
        let prioritizer = EventPrioritizer()
        let initial = makeEvent(id: "person:center", distance: 1.5, collisionRisk: .caution)
        let updated = makeEvent(id: "person:center", distance: 1.8, collisionRisk: .caution)

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
            "mountingMode": "unsupported",
            "spokenCategories": ["person", "unsupported"],
        ])

        XCTAssertEqual(parsed.hapticIntensity, 1)
        XCTAssertEqual(parsed.audioVolume, 0)
        XCTAssertEqual(parsed.warningDistanceMeters, 12)
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

    func testSpeakerCuesKeepDirectionIncludingCollisions() {
        for risk in [CollisionRisk.none, .caution, .imminent] {
            let left = AudioCueProfile(
                event: makeEvent(direction: .left, collisionRisk: risk),
                configuration: configuration, stereo: false
            )
            let center = AudioCueProfile(
                event: makeEvent(collisionRisk: risk),
                configuration: configuration, stereo: false
            )
            let right = AudioCueProfile(
                event: makeEvent(direction: .right, collisionRisk: risk),
                configuration: configuration, stereo: false
            )
            XCTAssertGreaterThan(left.startFrequency, left.endFrequency)
            XCTAssertEqual(center.startFrequency, center.endFrequency)
            XCTAssertLessThan(right.startFrequency, right.endFrequency)
            XCTAssertEqual(left.pan, 0)
            XCTAssertEqual(center.pan, 0)
            XCTAssertEqual(right.pan, 0)

            let stereo = AudioCueProfile(
                event: makeEvent(direction: .left, collisionRisk: risk),
                configuration: configuration
            )
            XCTAssertEqual(left.pulseCount, stereo.pulseCount)
            XCTAssertEqual(left.pulseDuration, stereo.pulseDuration)
            XCTAssertEqual(left.pulseGap, stereo.pulseGap)
            XCTAssertEqual(left.gain, stereo.gain)
        }
    }

    func testStereoCollisionCuesKeepExistingSweepAndPan() {
        for risk in [CollisionRisk.caution, .imminent] {
            for direction in Direction.allCases {
                let profile = AudioCueProfile(
                    event: makeEvent(direction: direction, collisionRisk: risk),
                    configuration: configuration
                )
                XCTAssertEqual(profile.startFrequency, 520)
                XCTAssertEqual(profile.endFrequency, risk == .imminent ? 1_420 : 1_120)
                XCTAssertEqual(profile.pan, direction.pan)
            }
        }
    }

    func testStereoPanFollowsWhereTheHazardSitsInView() {
        func pan(midX: Double) -> Float {
            let box = CGRect(x: midX - 0.1, y: 0.2, width: 0.2, height: 0.3)
            let event = makeEvent(direction: Direction.from(horizontalMidpoint: midX), collisionRisk: .caution, box: box)
            return AudioCueProfile(event: event, configuration: configuration).pan
        }
        XCTAssertEqual(pan(midX: 0.5), 0, accuracy: 0.001)
        // Off-center hazards that still count as "center" are audibly placed.
        XCTAssertLessThan(pan(midX: 0.42), -0.2)
        XCTAssertGreaterThan(pan(midX: 0.58), 0.2)
        XCTAssertLessThan(pan(midX: 0.25), pan(midX: 0.42))
        XCTAssertEqual(pan(midX: 0.05), -1)
        XCTAssertEqual(pan(midX: 0.95), 1)
    }

    func testGroundHazardCautionsOnceItPersists() throws {
        var tracker = GroundHazardTracker()
        let hazard = PathObstacleObservation(
            distanceMeters: 1.8, box: CGRect(x: 0.2, y: 0.1, width: 0.16, height: 0.12), coverage: 0.05
        )
        XCTAssertEqual(tracker.update(hazard, now: 10, cameraStable: true)?.collisionRisk, CollisionRisk.none)
        XCTAssertEqual(tracker.update(hazard, now: 10.3, cameraStable: true)?.collisionRisk, CollisionRisk.none)
        let confirmed = try XCTUnwrap(tracker.update(hazard, now: 10.6, cameraStable: true))
        XCTAssertEqual(confirmed.collisionRisk, .caution)
        XCTAssertEqual(confirmed.direction, .left)
        XCTAssertEqual(confirmed.label, "low obstacle")
        XCTAssertNil(confirmed.timeToCollisionSeconds)

        // A stationary low obstacle is announced by the prioritizer.
        let prioritizer = EventPrioritizer()
        let selected = prioritizer.select(from: [confirmed], configuration: configuration, now: 10.6)
        XCTAssertEqual(selected?.id, confirmed.id)
        XCTAssertTrue(prioritizer.shouldAnnounce(selected, now: 10.6))
    }

    func testGroundHazardNeedsStableCameraAndNewObstacleGetsNewIdentity() throws {
        var tracker = GroundHazardTracker()
        let first = PathObstacleObservation(
            distanceMeters: 1.8, box: CGRect(x: 0.2, y: 0.1, width: 0.16, height: 0.12), coverage: 0.05
        )
        for step in 0..<4 {
            let event = tracker.update(first, now: 10 + Double(step) * 0.3, cameraStable: false)
            XCTAssertEqual(event?.collisionRisk, CollisionRisk.none)
        }
        let firstId = try XCTUnwrap(tracker.update(first, now: 11.2, cameraStable: true)).id

        let second = PathObstacleObservation(
            distanceMeters: 1.2, box: CGRect(x: 0.6, y: 0.1, width: 0.16, height: 0.12), coverage: 0.05
        )
        let moved = try XCTUnwrap(tracker.update(second, now: 11.5, cameraStable: true))
        XCTAssertNotEqual(moved.id, firstId)
        XCTAssertEqual(moved.collisionRisk, .none)

        XCTAssertNil(tracker.update(nil, now: 13, cameraStable: true))
        XCTAssertEqual(tracker.update(second, now: 13.1, cameraStable: true)?.collisionRisk, CollisionRisk.none)
    }

    func testQualityAndEqualPrioritySpeechCannotInterruptHazards() {
        XCTAssertFalse(Feedback.shouldInterruptSpeech(currentPriority: 1, incomingPriority: 0.5, mayInterrupt: false))
        XCTAssertFalse(Feedback.shouldInterruptSpeech(currentPriority: 2, incomingPriority: 2, mayInterrupt: true))
        XCTAssertTrue(Feedback.shouldInterruptSpeech(currentPriority: 1, incomingPriority: 2, mayInterrupt: true))
        XCTAssertFalse(Feedback.shouldInterruptSpeech(currentPriority: 0.5, incomingPriority: 1, mayInterrupt: false))
    }

    func testPlaybackDoesNotUseBluetoothInputOptions() {
        XCTAssertFalse(Feedback.playbackOptions.contains(.allowBluetoothA2DP))
        XCTAssertTrue(Feedback.playbackOptions.contains(.mixWithOthers))
    }

    func testNamedCollisionReplacesOverlappingGenericObstacle() {
        let prioritizer = EventPrioritizer()
        let box = CGRect(x: 0.35, y: 0.2, width: 0.3, height: 0.5)
        let generic = makeEvent(id: "depth:path", kind: .obstacle, distance: 1.5, collisionRisk: .caution, box: box)
        let named = makeEvent(id: "person:center", distance: 1.5, collisionRisk: .caution, box: box)
        XCTAssertEqual(prioritizer.select(from: [generic, named], configuration: configuration, now: 10)?.id, named.id)
        let imminent = makeEvent(id: "depth:path", kind: .obstacle, distance: 1.5, collisionRisk: .imminent, box: box)
        XCTAssertEqual(prioritizer.select(from: [imminent, named], configuration: configuration, now: 10.1)?.id, imminent.id)
    }

    func testHazardSwitchesWaitButRiskEscalationDoesNot() {
        let prioritizer = EventPrioritizer()
        XCTAssertTrue(prioritizer.shouldAnnounce(makeEvent(id: "one", collisionRisk: .caution), now: 10))
        XCTAssertFalse(prioritizer.shouldAnnounce(makeEvent(id: "two", collisionRisk: .caution), now: 10.4))
        XCTAssertTrue(prioritizer.shouldAnnounce(makeEvent(id: "two", collisionRisk: .imminent), now: 10.5))
    }

    func testBoundingBoxVerbosityValidatesNativeInput() {
        XCTAssertEqual(FeedbackConfiguration(dictionary: [:]).boundingBoxVerbosity, "standard")
        XCTAssertEqual(FeedbackConfiguration(dictionary: ["boundingBoxVerbosity": "invalid"]).boundingBoxVerbosity, "standard")
        for value in ["verbose", "standard", "less"] {
            XCTAssertEqual(FeedbackConfiguration(dictionary: ["boundingBoxVerbosity": value]).boundingBoxVerbosity, value)
        }
    }

    private func makeEvent(
        id: String = "person:center",
        kind: EventKind = .person,
        direction: Direction = .center,
        distance: Double = 2,
        confidence: Double = 0.9,
        collisionRisk: CollisionRisk = .none,
        motionState: MotionState = .stationary,
        box: CGRect? = nil
    ) -> SpatialEvent {
        SpatialEvent(
            id: id,
            kind: kind,
            direction: direction,
            proximity: Proximity.from(distance: distance),
            approximateDistanceMeters: distance,
            approachSpeed: 0,
            motionState: motionState,
            collisionRisk: collisionRisk,
            timeToCollisionSeconds: collisionRisk == .none ? nil : 1,
            trajectoryConfidence: collisionRisk == .none ? 0 : 0.9,
            confidence: confidence,
            urgency: 0,
            timestamp: 10,
            box: box
        )
    }
}
