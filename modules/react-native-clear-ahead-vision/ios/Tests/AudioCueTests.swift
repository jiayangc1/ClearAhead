import XCTest
@testable import ClearAheadVision

final class AudioCueTests: XCTestCase {
    func testDistanceChangesGainWithoutChangingRepetitionOrCharacter() {
        let near = SceneAudioMath.gain(distance: 0.5, range: 6, volume: 1, count: 6)
        let far = SceneAudioMath.gain(distance: 5.5, range: 6, volume: 1, count: 6)
        XCTAssertGreaterThan(near, far * 4)
        XCTAssertEqual(SceneAudioMath.gain(distance: 1, range: 6, volume: 0, count: 6), 0)
        XCTAssertEqual(SceneTone.frequency(kind: .furniture, slot: 0), SceneTone.frequency(kind: .obstacle, slot: 0))
        XCTAssertNotEqual(SceneTone.frequency(kind: .person, slot: 0), SceneTone.frequency(kind: .obstacle, slot: 0))
        XCTAssertNotEqual(SceneTone.frequency(kind: .vehicle, slot: 0), SceneTone.frequency(kind: .obstacle, slot: 0))
    }

    func testSixSourcesHaveBoundedTotalGainAndFiniteSmoothLoops() {
        let gain = SceneAudioMath.gain(distance: 0, range: 6, volume: 1, count: 6)
        XCTAssertLessThanOrEqual(gain * 6, 0.22)
        for kind in EventKind.allCases {
            for slot in 0..<6 {
                let samples = SceneTone.samples(kind: kind, slot: slot, sampleRate: 44_100)
                XCTAssertEqual(samples.count, 44_100)
                XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
                // Joining the last sample to the first stays within the normal waveform slope.
                XCTAssertLessThan(abs(samples.last! - samples.first!), 0.1)
                XCTAssertGreaterThan(samples.map(abs).max()!, 0.5)
            }
        }
    }

    func testOrdinarySceneryNeverVibratesAndUrgencyEscalatesImmediately() {
        var gate = UrgencyHaptics()
        XCTAssertFalse(gate.shouldPlay(.none, now: 10))
        XCTAssertTrue(gate.shouldPlay(.caution, now: 10.1))
        XCTAssertFalse(gate.shouldPlay(.caution, now: 10.2))
        XCTAssertTrue(gate.shouldPlay(.imminent, now: 10.3))
        XCTAssertFalse(gate.shouldPlay(.imminent, now: 10.4))
        XCTAssertTrue(gate.shouldPlay(.imminent, now: 10.8))
        XCTAssertFalse(gate.shouldPlay(.none, now: 11))
    }

    func testSpeechDefaultsOnAndOptOutStillWorks() {
        XCTAssertTrue(FeedbackConfiguration(dictionary: [:]).speechEnabled)
        XCTAssertFalse(FeedbackConfiguration(dictionary: ["speechEnabled": false]).speechEnabled)
        XCTAssertFalse(FeedbackConfiguration(dictionary: ["continuousAudio": false]).continuousAudio)
    }
}
