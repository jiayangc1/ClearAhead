import Foundation

struct PipelineStatus: Equatable {
    let state: String
    let code: String
    let message: String
    let severity: String
}

// The engine owns these values under stateLock. All times use systemUptime.
struct SessionHealth {
    let startedAt: TimeInterval
    private(set) var lastFrameReceived: TimeInterval?
    private(set) var lastInferenceCompleted: TimeInterval?
    private(set) var objectFailures = 0
    private(set) var depthFailures = 0
    private(set) var stalled = false
    var audioInterrupted = false

    mutating func receivedFrame(at now: TimeInterval) { lastFrameReceived = now }

    mutating func recordInference(detector: Bool, succeeded: Bool, at now: TimeInterval) {
        lastInferenceCompleted = now
        if detector { objectFailures = succeeded ? 0 : objectFailures + 1 }
        else { depthFailures = succeeded ? 0 : depthFailures + 1 }
    }

    @discardableResult
    mutating func checkStall(at now: TimeInterval) -> Bool {
        stalled = now - (lastFrameReceived ?? startedAt) > 2
            || now - (lastInferenceCompleted ?? startedAt) > 2
        return stalled
    }

    func status(detectorLoaded: Bool, depthLoaded: Bool) -> PipelineStatus {
        let degradedState = lastFrameReceived == nil ? "starting" : "degraded"
        if stalled {
            return PipelineStatus(state: "degraded", code: "camera-stalled", message: "Vision stalled. No current hazard information.", severity: "warning")
        }
        let objectUnavailable = !detectorLoaded || objectFailures >= 3
        let depthUnavailable = !depthLoaded || depthFailures >= 3
        if objectUnavailable && depthUnavailable {
            return PipelineStatus(state: degradedState, code: "pipeline-unavailable", message: "Object detection and depth unavailable. Hazard cues are unreliable.", severity: "error")
        }
        if objectUnavailable {
            return PipelineStatus(state: degradedState, code: "object-unavailable", message: "Object detector unavailable. Only depth obstacle cues remain active.", severity: "warning")
        }
        if depthUnavailable {
            return PipelineStatus(state: degradedState, code: "depth-unavailable", message: "Depth unavailable. Object distances are unknown.", severity: "warning")
        }
        if lastFrameReceived == nil {
            return PipelineStatus(state: "starting", code: "models-ready", message: "Models ready. Waiting for camera frames.", severity: "info")
        }
        if audioInterrupted {
            return PipelineStatus(state: "degraded", code: "audio-interrupted", message: "Audio interrupted. Vision and haptic cues remain active.", severity: "warning")
        }
        return PipelineStatus(state: "running", code: "receiving-frames", message: "Camera frames and on-device models active", severity: "info")
    }
}

struct SessionQualityState {
    var thermalLimited = false
    var cameraTooClose = false
    var imageQuality = "good"
    var transient: [String: TimeInterval] = [:]

    func effective(at now: TimeInterval) -> (quality: String, message: String) {
        if thermalLimited { return ("thermal-limited", "Device is warm. Processing has slowed.") }
        if cameraTooClose { return ("camera-too-close", "Camera too close. Move it back.") }
        if transient["moving-too-fast", default: 0] > now { return ("moving-too-fast", "Phone is moving too quickly. Slow down.") }
        if imageQuality == "camera-covered" { return (imageQuality, "Camera may be covered. Check the lens.") }
        if imageQuality == "low-light" { return (imageQuality, "Low light. Detection may be less reliable.") }
        return ("good", "Camera view is clear")
    }
}

// Stretches the inference intervals when the device cannot keep up, so slow
// hardware runs the models less often instead of falling behind. Frames the
// camera drops while a model is busy are expected and are not overload.
struct AdaptiveThrottle {
    // Hazard tracking needs observations at least this often to stay continuous.
    static let maximumInterval = 0.5
    // Inference may occupy this share of wall time; the rest is headroom.
    static let dutyCycle = 0.6

    private(set) var smoothedInferenceSeconds = 0.0
    private var requiredInterval = 0.0
    private var behindSince: TimeInterval?

    // Every schedule is held to the interval the device can sustain; one that
    // is already slower than that is left alone rather than stretched again.
    func interval(base: Double) -> Double {
        max(base, min(requiredInterval, Self.maximumInterval))
    }

    mutating func record(inferenceSeconds: Double, at now: TimeInterval) {
        smoothedInferenceSeconds = smoothedInferenceSeconds == 0
            ? inferenceSeconds
            : smoothedInferenceSeconds + (inferenceSeconds - smoothedInferenceSeconds) * 0.25
        requiredInterval = smoothedInferenceSeconds / Self.dutyCycle
        if requiredInterval > Self.maximumInterval {
            if behindSince == nil { behindSince = now }
        } else {
            behindSince = nil
        }
    }

    /// True only once even the slowest schedule has been too fast for 3 seconds.
    func isOverloaded(at now: TimeInterval) -> Bool {
        behindSince.map { now - $0 >= 3 } ?? false
    }
}

// Queue callbacks carry a token; stop invalidates it before cancelling devices.
final class FeedbackGeneration {
    private let lock = NSLock()
    private var value = 0
    private var active = false

    @discardableResult
    func start() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        active = true
        return value
    }

    func stop() {
        lock.lock()
        value += 1
        active = false
        lock.unlock()
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func accepts(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active && token == value
    }
}
