import XCTest
@testable import ClearAheadVision

final class AudioCueTests: XCTestCase {
    private let configuration = FeedbackConfiguration()

    func testCloserHazardsSoundHigherLouderAndFaster() {
        for risk in [CollisionRisk.none, .caution, .imminent] {
            let far = profile(distance: 5.5, risk: risk, timeToCollision: nil)
            let near = profile(distance: 1, risk: risk, timeToCollision: nil)
            XCTAssertGreaterThan(near.startFrequency, far.startFrequency)
            XCTAssertGreaterThanOrEqual(near.gain, far.gain)
            XCTAssertLessThan(near.repeatRest, far.repeatRest)
        }
        let far = profile(distance: 5.5, risk: .caution, timeToCollision: nil)
        let near = profile(distance: 1, risk: .caution, timeToCollision: nil)
        XCTAssertGreaterThan(near.gain, far.gain)
        XCTAssertEqual(near.startFrequency / far.startFrequency, pow(2, 4.5 / 6), accuracy: 0.001)
    }

    func testFastApproachFromFarAwaySoundsClose() {
        let slow = profile(distance: 5.5, risk: .caution, timeToCollision: nil)
        let fast = profile(distance: 5.5, risk: .caution, timeToCollision: 0.6)
        XCTAssertGreaterThan(fast.startFrequency, slow.startFrequency)
        XCTAssertLessThan(fast.repeatRest, slow.repeatRest)
    }

    func testRiskChangesRhythmAndRoughness() {
        let none = profile(risk: .none)
        let caution = profile(risk: .caution)
        let imminent = profile(risk: .imminent)
        XCTAssertEqual([none.pulseCount, caution.pulseCount, imminent.pulseCount], [1, 2, 3])
        XCTAssertLessThan(imminent.repeatRest, caution.repeatRest)
        XCTAssertLessThan(caution.repeatRest, none.repeatRest)
        XCTAssertEqual(caution.roughness, 0)
        XCTAssertGreaterThan(imminent.roughness, 0)
        XCTAssertGreaterThan(imminent.repeatRest, 0)
    }

    func testEachKindOfHazardHasItsOwnVoice() {
        let timbres = [
            profile(kind: .person).timbre,
            profile(kind: .vehicle).timbre,
            profile(kind: .furniture).timbre,
            profile(id: "depth:path", kind: .obstacle).timbre,
            profile(id: "depth:ground-1", kind: .obstacle).timbre,
        ]
        XCTAssertEqual(timbres, [.voice, .buzz, .knock, .click, .thud])
        XCTAssertLessThan(
            profile(id: "depth:ground-1", kind: .obstacle).startFrequency,
            profile(id: "depth:path", kind: .obstacle).startFrequency
        )
    }

    func testHeadphonePitchContourFollowsMotion() {
        let approaching = profile(motion: .approaching)
        let receding = profile(motion: .receding)
        let stationary = profile(motion: .stationary)
        let crossing = profile(motion: .crossing)
        XCTAssertGreaterThan(approaching.endFrequency, approaching.startFrequency)
        XCTAssertLessThan(receding.endFrequency, receding.startFrequency)
        XCTAssertEqual(stationary.endFrequency, stationary.startFrequency)
        XCTAssertEqual(stationary.vibratoDepth, 0)
        XCTAssertGreaterThan(crossing.vibratoDepth, 0)
    }

    func testSpeakerPitchContourCarriesDirection() {
        for risk in [CollisionRisk.none, .caution, .imminent] {
            let left = profile(direction: .left, risk: risk, stereo: false)
            let center = profile(risk: risk, stereo: false)
            let right = profile(direction: .right, risk: risk, stereo: false)
            XCTAssertGreaterThan(left.startFrequency, left.endFrequency)
            XCTAssertEqual(center.startFrequency, center.endFrequency)
            XCTAssertLessThan(right.startFrequency, right.endFrequency)
            XCTAssertEqual([left.pan, center.pan, right.pan], [0, 0, 0])

            let stereo = profile(direction: .left, risk: risk)
            XCTAssertEqual(stereo.pan, Direction.left.pan)
            XCTAssertEqual(left.pulseCount, stereo.pulseCount)
            XCTAssertEqual(left.repeatRest, stereo.repeatRest)
            XCTAssertEqual(left.gain, stereo.gain)
        }
    }

    func testStereoPanFollowsWhereTheHazardSitsInView() {
        func pan(midX: Double) -> Float {
            let box = CGRect(x: midX - 0.1, y: 0.2, width: 0.2, height: 0.3)
            return profile(direction: Direction.from(horizontalMidpoint: midX), risk: .caution, box: box).pan
        }
        XCTAssertEqual(pan(midX: 0.5), 0, accuracy: 0.001)
        // Off-center hazards that still count as "center" are audibly placed.
        XCTAssertLessThan(pan(midX: 0.42), -0.2)
        XCTAssertGreaterThan(pan(midX: 0.58), 0.2)
        XCTAssertLessThan(pan(midX: 0.25), pan(midX: 0.42))
        XCTAssertEqual(pan(midX: 0.05), -1)
        XCTAssertEqual(pan(midX: 0.95), 1)
    }

    func testCenteredAndConfidentHazardsAreLoudest() {
        XCTAssertGreaterThan(profile(risk: .caution).gain, profile(direction: .left, risk: .caution).gain)
        XCTAssertGreaterThan(
            profile(risk: .caution, confidence: 0.95).gain,
            profile(risk: .caution, confidence: 0.5).gain
        )
        var quiet = FeedbackConfiguration()
        quiet.audioVolume = 0
        XCTAssertEqual(AudioCueProfile(event: event(risk: .imminent), configuration: quiet).gain, 0)
    }

    func testRenderedCuePlacesSoundWithLevelAndArrivalTime() {
        func energy(_ samples: [Float]) -> Float { samples.reduce(0) { $0 + $1 * $1 } }
        func onset(_ samples: [Float]) -> Int { samples.firstIndex { $0 != 0 } ?? -1 }

        let left = AudioCueRenderer.render(profile(direction: .left, risk: .caution), sampleRate: 44_100)
        XCTAssertGreaterThan(energy(left.left), energy(left.right) * 4)
        XCTAssertGreaterThan(energy(left.right), 0)
        XCTAssertGreaterThan(onset(left.right), onset(left.left))

        let right = AudioCueRenderer.render(profile(direction: .right, risk: .caution), sampleRate: 44_100)
        XCTAssertGreaterThan(energy(right.right), energy(right.left) * 4)
        XCTAssertGreaterThan(onset(right.left), onset(right.right))

        let center = AudioCueRenderer.render(profile(risk: .caution), sampleRate: 44_100)
        XCTAssertEqual(center.left, center.right)
    }

    func testRenderedCueStaysWithinRangeForEveryVoice() {
        var loud = FeedbackConfiguration()
        loud.audioVolume = 1
        for kind in EventKind.allCases {
            for risk in [CollisionRisk.none, .caution, .imminent] {
                for motion in [MotionState.stationary, .approaching, .crossing] {
                    let cue = AudioCueProfile(
                        event: event(kind: kind, distance: 0.3, risk: risk, motion: motion), configuration: loud
                    )
                    let samples = AudioCueRenderer.render(cue, sampleRate: 44_100)
                    XCTAssertEqual(samples.left.count, samples.right.count)
                    XCTAssertGreaterThanOrEqual(Double(samples.left.count) / 44_100, cue.duration - 0.001)
                    let peak = (samples.left + samples.right).map(abs).max() ?? 0
                    XCTAssertGreaterThan(peak, 0.05)
                    XCTAssertLessThanOrEqual(peak, 0.6)
                    XCTAssertFalse((samples.left + samples.right).contains { !$0.isFinite })
                    // No click at the end of the burst.
                    XCTAssertLessThan(abs(samples.left.last ?? 1), 0.01)
                }
            }
        }
    }

    func testContinuousAudioPreferenceIsParsed() {
        XCTAssertTrue(FeedbackConfiguration(dictionary: [:]).continuousAudio)
        XCTAssertFalse(FeedbackConfiguration(dictionary: ["continuousAudio": false]).continuousAudio)
    }

    private func profile(
        id: String = "person:center",
        kind: EventKind = .person,
        direction: Direction = .center,
        distance: Double = 2,
        risk: CollisionRisk = .none,
        motion: MotionState = .stationary,
        timeToCollision: Double? = nil,
        confidence: Double = 0.9,
        box: CGRect? = nil,
        stereo: Bool = true
    ) -> AudioCueProfile {
        AudioCueProfile(
            event: event(id: id, kind: kind, direction: direction, distance: distance, risk: risk,
                         motion: motion, timeToCollision: timeToCollision, confidence: confidence, box: box),
            configuration: configuration,
            stereo: stereo
        )
    }

    private func event(
        id: String = "person:center",
        kind: EventKind = .person,
        direction: Direction = .center,
        distance: Double = 2,
        risk: CollisionRisk = .none,
        motion: MotionState = .stationary,
        timeToCollision: Double? = nil,
        confidence: Double = 0.9,
        box: CGRect? = nil
    ) -> SpatialEvent {
        SpatialEvent(
            id: id, kind: kind, direction: direction, proximity: Proximity.from(distance: distance),
            approximateDistanceMeters: distance, approachSpeed: 0, motionState: motion, collisionRisk: risk,
            timeToCollisionSeconds: timeToCollision, trajectoryConfidence: 0.9, confidence: confidence,
            urgency: 0, timestamp: 10, box: box
        )
    }
}
