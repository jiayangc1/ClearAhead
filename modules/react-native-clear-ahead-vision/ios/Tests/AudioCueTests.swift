import AVFoundation
import XCTest
@testable import ClearAheadVision

final class AudioCueTests: XCTestCase {
    func testRecoveryWaitsForEngineStartAndResumesAllActiveSources() throws {
        let engine = AVAudioEngine()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let audio = SpatialAudio(engine: engine)
        defer { audio.stop(); engine.stop() }
        try engine.start()
        let sources = (0..<SceneSelector.maximumSources).map { index in
            let event = SpatialEvent(id: "source-\(index)", kind: .person, direction: .center, proximity: .near,
                                     approximateDistanceMeters: 1, approachSpeed: 0, motionState: .stationary,
                                     collisionRisk: .none, confidence: 0.9, urgency: 0, timestamp: 10, box: nil)
            return SceneSource(event: event, position: SIMD3(0, 0, -1), contours: [], visibility: 1, isSurface: false)
        }
        audio.update(sources, configuration: FeedbackConfiguration(), camera: nil, earCalibrated: false)
        let players = engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }
        XCTAssertEqual(players.filter(\.isPlaying).count, SceneSelector.maximumSources)
        for _ in 0..<2 {
            engine.stop()
            engine.reset()
            audio.recover()
            audio.resume()
            XCTAssertFalse(engine.isRunning)
            XCTAssertTrue(players.allSatisfy { !$0.isPlaying })
            try engine.start()
            audio.resume()
            XCTAssertEqual(players.filter(\.isPlaying).count, SceneSelector.maximumSources)
        }
    }

    func testMediaServicesResetReplacesEngineWithoutStartingAnIdleSession() {
        onMain {
            let feedback = Feedback()
            let original = feedback.audioEngine
            NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: AVAudioSession.sharedInstance())
            XCTAssertFalse(feedback.audioEngine === original)
            XCTAssertFalse(feedback.audioEngine.isRunning)
            let replacement = feedback.audioEngine
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: original)
            _ = feedback.spatialCapability
            XCTAssertTrue(feedback.audioEngine === replacement)
            XCTAssertFalse(feedback.audioEngine.isRunning)
        }
    }

    func testMediaServicesResetPreservesActiveSessionForTheNextFrame() throws {
        try onMain {
            let feedback = Feedback()
            feedback.start()
            defer { feedback.stop() }
            let original = feedback.audioEngine
            NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: AVAudioSession.sharedInstance())
            XCTAssertFalse(feedback.audioEngine === original)
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: original)
            _ = feedback.spatialCapability
            // A new frame restarts playback; the reset itself must not play stale cues.
            XCTAssertFalse(feedback.audioEngine.isRunning)
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
            try feedback.audioEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
            feedback.updateScene([], configuration: FeedbackConfiguration(), camera: nil, earCalibrated: false)
            _ = feedback.spatialCapability
            XCTAssertTrue(feedback.audioEngine.isRunning)
        }
    }

    private func onMain(_ action: () throws -> Void) rethrows {
        if Thread.isMainThread { try action() }
        else { try DispatchQueue.main.sync(execute: action) }
    }

    func testDistanceChangesGainAndCategoriesKeepDistinctRegisters() {
        let near = SceneAudioMath.gain(distance: 0.5, range: 6, volume: 1, count: 6)
        let far = SceneAudioMath.gain(distance: 5.5, range: 6, volume: 1, count: 6)
        XCTAssertGreaterThan(near, far * 4)
        XCTAssertEqual(SceneAudioMath.gain(distance: 1, range: 6, volume: 0, count: 6), 0)
        XCTAssertEqual(SceneTone.frequency(kind: .furniture, slot: 0), SceneTone.frequency(kind: .obstacle, slot: 0))
        XCTAssertNotEqual(SceneTone.frequency(kind: .person, slot: 0), SceneTone.frequency(kind: .obstacle, slot: 0))
        XCTAssertNotEqual(SceneTone.frequency(kind: .vehicle, slot: 0), SceneTone.frequency(kind: .obstacle, slot: 0))
    }

    func testLiveCueFollowsHeightProximityAndCollisionRisk() {
        func cue(distance: Double, height: Double = 0, risk: CollisionRisk = .none,
                 motion: MotionState = .stationary, speed: Double = 0) -> SceneTone.Cue {
            let event = SpatialEvent(id: "hazard", kind: .obstacle, direction: .center, proximity: .near,
                                     approximateDistanceMeters: distance, approachSpeed: speed, motionState: motion,
                                     collisionRisk: risk, confidence: 0.9, urgency: 0.8, timestamp: 10, box: nil)
            return SceneTone.cue(event: event, position: SIMD3(0, height, -distance), range: 6)
        }
        let far = cue(distance: 5)
        let near = cue(distance: 1)
        XCTAssertGreaterThan(near.pitchCents, far.pitchCents)
        XCTAssertGreaterThan(near.brightness, far.brightness)
        XCTAssertGreaterThan(near.pulseRate, far.pulseRate)
        XCTAssertGreaterThan(cue(distance: 2, height: 1).pitchCents, cue(distance: 2, height: -1).pitchCents)
        let caution = cue(distance: 1, risk: .caution)
        let imminent = cue(distance: 1, risk: .imminent)
        XCTAssertGreaterThan(imminent.pitchCents, caution.pitchCents)
        XCTAssertGreaterThan(imminent.brightness, caution.brightness)
        XCTAssertGreaterThan(imminent.pulseRate, caution.pulseRate)
        XCTAssertGreaterThan(imminent.pulseDepth, caution.pulseDepth)
        XCTAssertGreaterThan(cue(distance: 1, motion: .approaching, speed: 1).pulseRate, near.pulseRate)
        XCTAssertEqual(cue(distance: 1, motion: .receding, speed: 1).pulseRate, near.pulseRate)
        for phase in stride(from: 0.0, through: 2 * .pi, by: 0.01) {
            let gain = SceneTone.pulse(phase: phase, depth: imminent.pulseDepth)
            XCTAssertTrue(gain.isFinite && gain >= 0 && gain <= 1)
        }
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
        XCTAssertTrue(FeedbackConfiguration(dictionary: [:]).lidarEnabled)
        XCTAssertFalse(FeedbackConfiguration(dictionary: ["lidarEnabled": false]).lidarEnabled)
    }
}
