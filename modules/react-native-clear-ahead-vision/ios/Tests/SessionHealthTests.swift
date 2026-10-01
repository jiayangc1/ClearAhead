import XCTest
@testable import ClearAheadVision

final class SessionHealthTests: XCTestCase {
    func testRecoveryDoesNotHideOtherModelFailure() {
        var health = SessionHealth(startedAt: 10)
        health.receivedFrame(at: 10)
        for _ in 0..<3 { health.recordInference(detector: true, succeeded: false, at: 10) }
        for _ in 0..<3 { health.recordInference(detector: false, succeeded: false, at: 10) }
        XCTAssertEqual(health.status(detectorLoaded: true, depthLoaded: true).code, "pipeline-unavailable")
        health.recordInference(detector: false, succeeded: true, at: 10.1)
        XCTAssertEqual(health.status(detectorLoaded: true, depthLoaded: true).code, "object-unavailable")
    }

    func testWatchdogDetectsNoFramesAndInferenceStall() {
        var health = SessionHealth(startedAt: 10)
        XCTAssertTrue(health.checkStall(at: 12.1))
        health.receivedFrame(at: 12.2)
        health.recordInference(detector: true, succeeded: true, at: 12.2)
        XCTAssertFalse(health.checkStall(at: 12.2))
        health.receivedFrame(at: 14.4)
        XCTAssertTrue(health.checkStall(at: 14.4))
    }

    func testResetDropsPreviousSessionHealth() {
        var health = SessionHealth(startedAt: 1)
        for _ in 0..<4 { health.recordInference(detector: true, succeeded: false, at: 1) }
        _ = health.checkStall(at: 5)
        health = SessionHealth(startedAt: 6)
        XCTAssertEqual(health.status(detectorLoaded: true, depthLoaded: true).code, "models-ready")
        XCTAssertFalse(health.checkStall(at: 6))
    }

    func testThermalQualitySurvivesImageAndTransientConditions() {
        var quality = SessionQualityState()
        quality.thermalLimited = true
        quality.imageQuality = "low-light"
        quality.transient["moving-too-fast"] = 12
        XCTAssertEqual(quality.effective(at: 10).quality, "thermal-limited")
        quality.thermalLimited = false
        XCTAssertEqual(quality.effective(at: 10).quality, "moving-too-fast")
        XCTAssertEqual(quality.effective(at: 13).quality, "low-light")
        quality = SessionQualityState()
        XCTAssertEqual(quality.effective(at: 14).quality, "good")
    }

    func testThrottleStretchesIntervalsOnlyWhenInferenceIsSlow() {
        var throttle = AdaptiveThrottle()
        throttle.record(inferenceSeconds: 0.04, at: 1)
        XCTAssertEqual(throttle.interval(base: 0.11), 0.11, accuracy: 0.001)
        XCTAssertEqual(throttle.interval(base: 0.35), 0.35, accuracy: 0.001)

        throttle = AdaptiveThrottle()
        throttle.record(inferenceSeconds: 0.15, at: 1)
        XCTAssertEqual(throttle.interval(base: 0.11), 0.25, accuracy: 0.001)
        // Depth keeps pace with the detector instead of being stretched a second time.
        XCTAssertEqual(throttle.interval(base: 0.18), 0.25, accuracy: 0.001)
        XCTAssertEqual(throttle.interval(base: 0.35), 0.35, accuracy: 0.001)
        XCTAssertFalse(throttle.isOverloaded(at: 60))

        // Intervals never stretch past what hazard tracking can tolerate.
        throttle = AdaptiveThrottle()
        throttle.record(inferenceSeconds: 0.4, at: 1)
        XCTAssertEqual(throttle.interval(base: 0.11), AdaptiveThrottle.maximumInterval, accuracy: 0.001)
    }

    func testThrottleReportsOverloadOnlyAfterSustainedSlowInference() {
        var throttle = AdaptiveThrottle()
        throttle.record(inferenceSeconds: 0.4, at: 10)
        XCTAssertFalse(throttle.isOverloaded(at: 10))
        throttle.record(inferenceSeconds: 0.4, at: 12)
        XCTAssertFalse(throttle.isOverloaded(at: 12))
        throttle.record(inferenceSeconds: 0.4, at: 13.1)
        XCTAssertTrue(throttle.isOverloaded(at: 13.1))
        // Recovery clears the warning without waiting.
        for step in 0..<12 {
            throttle.record(inferenceSeconds: 0.05, at: 14 + Double(step) * 0.1)
        }
        XCTAssertFalse(throttle.isOverloaded(at: 20))
    }

    func testFeedbackGenerationRejectsStoppedAndOldWork() {
        let generation = FeedbackGeneration()
        let old = generation.start()
        XCTAssertTrue(generation.accepts(old))
        generation.stop()
        XCTAssertFalse(generation.accepts(old))
        let current = generation.start()
        XCTAssertFalse(generation.accepts(old))
        XCTAssertTrue(generation.accepts(current))
    }
}
