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
        quality.transient["overloaded"] = 12
        XCTAssertEqual(quality.effective(at: 10).quality, "thermal-limited")
        quality.thermalLimited = false
        XCTAssertEqual(quality.effective(at: 10).quality, "overloaded")
        XCTAssertEqual(quality.effective(at: 13).quality, "low-light")
        quality = SessionQualityState()
        XCTAssertEqual(quality.effective(at: 14).quality, "good")
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
