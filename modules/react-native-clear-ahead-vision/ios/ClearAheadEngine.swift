import Accelerate
import AVFoundation
import CoreML
import CoreMotion
import Foundation
import Vision

final class ClearAheadEngine {
    static let shared = ClearAheadEngine()

    private let stateLock = NSLock()
    private let frameLock = NSLock()
    private let prioritizer = EventPrioritizer()
    private let feedback = FeedbackCoordinator()
    private let motionManager = CMMotionManager()
    private var configuration = CAFeedbackConfiguration()
    private var sessionActive = false
    private var demoTimer: DispatchSourceTimer?

    private lazy var objectModel = loadModel(named: ["YOLOv3TinyInt8LUT", "YOLOv3TinyFP16", "YOLOv3Tiny"])
    private lazy var depthModel = loadModel(named: ["DepthAnythingV2SmallF16P6", "DepthAnythingV2SmallF16"])
    private var objectEvents: [CASpatialEvent] = []
    private var depthEvents: [CASpatialEvent] = []
    private var trackHistory: [String: (distance: Double, time: TimeInterval)] = [:]
    private var lastObjectInference: TimeInterval = 0
    private var lastDepthInference: TimeInterval = 0
    private var lastQualityCheck: TimeInterval = 0
    private var inferenceCount = 0
    private var lastMetricsEmission: TimeInterval = 0
    private var frameCount = 0
    private var objectInferenceCount = 0
    private var depthInferenceCount = 0
    private var droppedFrameCount = 0
    private var metricWindowStart = ProcessInfo.processInfo.systemUptime
    private var latestLatencyMs = 0.0
    private var lastQuality = "good"
    private var transientQualityUntil: TimeInterval = 0
    private var interruptedSessionWasActive = false

    private init() {
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.emitThermalQuality()
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            self?.handleAudioInterruption(notification)
        }
    }

    func start(configuration: CAFeedbackConfiguration) {
        stateLock.lock()
        self.configuration = configuration
        sessionActive = true
        stateLock.unlock()
        prioritizer.reset()
        inferenceCount = 0
        stateLock.lock()
        droppedFrameCount = 0
        stateLock.unlock()
        resetMetrics()
        lastMetricsEmission = ProcessInfo.processInfo.systemUptime
        startMotionMonitoring()
        ClearAheadModule.emit(name: "sessionStatus", body: [
            "state": "running",
            "message": modelStatusMessage(),
        ])
    }

    func stop() {
        stateLock.lock()
        sessionActive = false
        stateLock.unlock()
        stopDemo()
        feedback.stop()
        motionManager.stopDeviceMotionUpdates()
        prioritizer.reset()
        ClearAheadModule.emit(name: "sessionStatus", body: [
            "state": "idle",
            "message": "Assist mode stopped",
        ])
    }

    func update(configuration: CAFeedbackConfiguration) {
        stateLock.lock()
        self.configuration = configuration
        stateLock.unlock()
    }

    func process(sampleBuffer: CMSampleBuffer) {
        stateLock.lock()
        let active = sessionActive
        let currentConfiguration = configuration
        stateLock.unlock()
        guard active, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        guard frameLock.try() else {
            stateLock.lock()
            droppedFrameCount += 1
            stateLock.unlock()
            return
        }
        defer { frameLock.unlock() }

        let startedAt = ProcessInfo.processInfo.systemUptime
        frameCount += 1
        let thermalState = ProcessInfo.processInfo.thermalState
        let thermallyLimited = thermalState == .serious || thermalState == .critical
        let responsive = currentConfiguration.processingMode == "responsive"
        let objectInterval = thermallyLimited ? 0.22 : 0.11
        let depthInterval = thermallyLimited ? 0.5 : (responsive ? 0.5 : 0.18)

        if startedAt - lastQualityCheck >= 0.65 {
            evaluateImageQuality(pixelBuffer: pixelBuffer)
            lastQualityCheck = startedAt
        }

        let objectDue = objectModel != nil && startedAt - lastObjectInference >= objectInterval
        let depthDue = depthModel != nil && startedAt - lastDepthInference >= depthInterval
        let depthStride = responsive ? 4 : 2
        if depthDue && (!objectDue || inferenceCount % depthStride == depthStride - 1) {
            depthEvents = estimateDepthEvents(pixelBuffer: pixelBuffer, now: startedAt)
            lastDepthInference = startedAt
            depthInferenceCount += 1
            inferenceCount += 1
        } else if objectDue {
            objectEvents = detectObjects(pixelBuffer: pixelBuffer, now: startedAt)
            lastObjectInference = startedAt
            objectInferenceCount += 1
            inferenceCount += 1
        }

        let freshEvents = (objectEvents + depthEvents).filter { startedAt - $0.timestamp < 0.7 }
        if let selected = prioritizer.select(
            from: freshEvents,
            configuration: currentConfiguration,
            now: startedAt
        ) {
            feedback.deliver(selected, configuration: currentConfiguration)
            ClearAheadModule.emit(name: "topEvent", body: selected.dictionary)
        }

        latestLatencyMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        emitMetricsIfNeeded(now: startedAt)
    }

    func reportDroppedFrame(reason: String) {
        stateLock.lock()
        droppedFrameCount += 1
        let shouldWarn = droppedFrameCount >= 6
        stateLock.unlock()
        if shouldWarn {
            markTransientQuality(
                "overloaded",
                message: "Processing is behind. Hold the phone steady.",
                duration: 1.5
            )
        }
    }

    func startDemo(scenario: String) {
        stopDemo()
        stateLock.lock()
        sessionActive = true
        let currentConfiguration = configuration
        stateLock.unlock()
        ClearAheadModule.emit(name: "sessionStatus", body: [
            "state": "running",
            "message": "Safe demo running",
        ])

        let sequence = demoSequence(for: scenario)
        var index = 0
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 0.4, repeating: 1.05)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let event = sequence[index % sequence.count]
            index += 1
            feedback.deliver(event, configuration: currentConfiguration)
            ClearAheadModule.emit(name: "topEvent", body: event.dictionary)
            ClearAheadModule.emit(name: "performanceMetrics", body: [
                "cameraFps": 0,
                "detectorFps": 0,
                "depthFps": 0,
                "droppedFrames": 0,
                "endToEndLatencyMs": 12,
                "thermalState": "nominal",
            ])
        }
        demoTimer = timer
        timer.resume()
    }

    func stopDemo() {
        demoTimer?.cancel()
        demoTimer = nil
    }

    private func detectObjects(pixelBuffer: CVPixelBuffer, now: TimeInterval) -> [CASpatialEvent] {
        guard let objectModel else { return [] }
        let request = VNCoreMLRequest(model: objectModel)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        return (request.results as? [VNRecognizedObjectObservation] ?? []).compactMap { observation in
            guard let label = observation.labels.first,
                  let kind = eventKind(for: label.identifier) else { return nil }
            let box = observation.boundingBox
            let direction = CADirection.from(horizontalMidpoint: box.midX)
            let distance = approximateDistance(kind: kind, boundingBox: box)
            let trackKey = "\(kind.rawValue):\(direction.rawValue)"
            let approachSpeed = approachSpeed(for: trackKey, distance: distance, now: now)
            return CASpatialEvent(
                id: trackKey,
                kind: kind,
                direction: direction,
                proximity: CAProximity.from(distance: distance),
                approximateDistanceMeters: distance,
                approachSpeed: approachSpeed,
                confidence: Double(label.confidence),
                urgency: 0,
                timestamp: now,
                box: box
            )
        }
    }

    private func estimateDepthEvents(pixelBuffer: CVPixelBuffer, now: TimeInterval) -> [CASpatialEvent] {
        guard let depthModel else { return [] }
        let request = VNCoreMLRequest(model: depthModel)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let feature = (request.results as? [VNCoreMLFeatureValueObservation])?.first(where: {
            $0.featureValue.multiArrayValue != nil
        }), let array = feature.featureValue.multiArrayValue else {
            return []
        }
        return depthEvents(from: array, now: now)
    }

    private func depthEvents(from array: MLMultiArray, now: TimeInterval) -> [CASpatialEvent] {
        let shape = array.shape.map(\.intValue)
        guard shape.count >= 2 else { return [] }
        let height = shape[shape.count - 2]
        let width = shape[shape.count - 1]
        guard width > 6, height > 6 else { return [] }

        let sampleStep = max(2, min(width, height) / 36)
        var global: [Double] = []
        var sectors: [[Double]] = Array(repeating: [], count: 3)
        for y in stride(from: height / 3, to: height, by: sampleStep) {
            for x in stride(from: 0, to: width, by: sampleStep) {
                let value = array[y * width + x].doubleValue
                guard value.isFinite else { continue }
                global.append(value)
                sectors[min(2, x * 3 / width)].append(value)
            }
        }
        guard global.count > 20,
              let minimum = global.min(),
              let maximum = global.max(),
              maximum - minimum > 0.0001 else { return [] }
        let median = percentile(global, fraction: 0.5)
        let directions: [CADirection] = [.left, .center, .right]
        return sectors.enumerated().compactMap { index, values in
            guard values.count > 5 else { return nil }
            let nearValue = percentile(values, fraction: 0.86)
            let normalizedContrast = (nearValue - median) / (maximum - minimum)
            guard normalizedContrast > 0.2 else { return nil }
            let proximity: CAProximity = normalizedContrast > 0.58 ? .near : .medium
            return CASpatialEvent(
                id: "depth:\(directions[index].rawValue)",
                kind: .obstacle,
                direction: directions[index],
                proximity: proximity,
                approximateDistanceMeters: nil,
                approachSpeed: 0,
                confidence: min(0.5 + normalizedContrast * 0.45, 0.88),
                urgency: 0,
                timestamp: now,
                box: CGRect(x: CGFloat(index) / 3, y: 0.35, width: 1.0 / 3, height: 0.65)
            )
        }
    }

    private func evaluateImageQuality(pixelBuffer: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        if now < transientQualityUntil { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        var count = 0.0
        var sum = 0.0
        var squareSum = 0.0
        for y in stride(from: 0, to: height, by: 32) {
            for x in stride(from: 0, to: width, by: 32) {
                let value = Double(pointer[y * bytesPerRow + x]) / 255
                count += 1
                sum += value
                squareSum += value * value
            }
        }
        guard count > 0 else { return }
        let mean = sum / count
        let variance = max(0, squareSum / count - mean * mean)
        let quality: String
        let message: String
        if mean < 0.12 {
            quality = "low-light"
            message = "Low light. Detection may be less reliable."
        } else if variance < 0.0025 {
            quality = "camera-covered"
            message = "Camera may be covered. Check the lens."
        } else {
            quality = "good"
            message = "Camera view is clear"
        }
        emitQuality(quality, message: message)
    }

    private func emitThermalQuality() {
        let state = ProcessInfo.processInfo.thermalState
        if state == .serious || state == .critical {
            emitQuality("thermal-limited", message: "Device is warm. Processing has slowed.")
        }
    }

    private func startMotionMonitoring() {
        guard motionManager.isDeviceMotionAvailable,
              !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 0.1
        motionManager.startDeviceMotionUpdates(to: OperationQueue()) { [weak self] motion, _ in
            guard let self, let rate = motion?.rotationRate else { return }
            let magnitude = sqrt(rate.x * rate.x + rate.y * rate.y + rate.z * rate.z)
            if magnitude > 3.2 {
                markTransientQuality(
                    "moving-too-fast",
                    message: "Phone is moving too quickly. Slow down.",
                    duration: 1.1
                )
            }
        }
    }

    private func markTransientQuality(_ quality: String, message: String, duration: TimeInterval) {
        transientQualityUntil = max(
            transientQualityUntil,
            ProcessInfo.processInfo.systemUptime + duration
        )
        emitQuality(quality, message: message)
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        if type == .began {
            stateLock.lock()
            interruptedSessionWasActive = sessionActive
            sessionActive = false
            stateLock.unlock()
            ClearAheadModule.emit(name: "sessionStatus", body: [
                "state": "paused",
                "message": "Paused while audio is interrupted",
            ])
        } else {
            stateLock.lock()
            let shouldResume = interruptedSessionWasActive
            sessionActive = shouldResume
            interruptedSessionWasActive = false
            stateLock.unlock()
            if shouldResume {
                ClearAheadModule.emit(name: "sessionStatus", body: [
                    "state": "running",
                    "message": "Audio restored. Assist mode resumed.",
                ])
            }
        }
    }

    private func emitQuality(_ quality: String, message: String) {
        guard quality != lastQuality else { return }
        lastQuality = quality
        ClearAheadModule.emit(name: "qualityChanged", body: ["quality": quality, "message": message])
        if quality != "good" {
            stateLock.lock()
            let currentConfiguration = configuration
            stateLock.unlock()
            feedback.speakWarning(message, configuration: currentConfiguration)
        }
    }

    private func emitMetricsIfNeeded(now: TimeInterval) {
        guard now - lastMetricsEmission >= 1 else { return }
        let duration = max(now - metricWindowStart, 0.001)
        stateLock.lock()
        let droppedFrames = droppedFrameCount
        droppedFrameCount = 0
        stateLock.unlock()
        ClearAheadModule.emit(name: "performanceMetrics", body: [
            "cameraFps": Double(frameCount) / duration,
            "detectorFps": Double(objectInferenceCount) / duration,
            "depthFps": Double(depthInferenceCount) / duration,
            "droppedFrames": droppedFrames,
            "endToEndLatencyMs": latestLatencyMs,
            "thermalState": thermalStateName(ProcessInfo.processInfo.thermalState),
        ])
        resetMetrics()
        lastMetricsEmission = now
    }

    private func resetMetrics() {
        frameCount = 0
        objectInferenceCount = 0
        depthInferenceCount = 0
        metricWindowStart = ProcessInfo.processInfo.systemUptime
    }

    private func modelStatusMessage() -> String {
        if objectModel == nil && depthModel == nil {
            return "Camera active. Baseline models are not installed."
        }
        if objectModel == nil || depthModel == nil {
            return "Camera active. One baseline model is unavailable."
        }
        return "Camera and on-device models active"
    }

    private func loadModel(named candidates: [String]) -> VNCoreMLModel? {
        let bundles = [Bundle.main, Bundle(for: ClearAheadEngine.self)]
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        for bundle in bundles {
            for name in candidates {
                for fileExtension in ["mlmodelc", "mlmodel", "mlpackage"] {
                    guard let assetURL = bundle.url(forResource: name, withExtension: fileExtension) else {
                        continue
                    }
                    let modelURL: URL
                    if fileExtension == "mlmodelc" {
                        modelURL = assetURL
                    } else if let compiledURL = try? MLModel.compileModel(at: assetURL) {
                        modelURL = compiledURL
                    } else {
                        continue
                    }
                    if let model = try? MLModel(contentsOf: modelURL, configuration: configuration),
                       let visionModel = try? VNCoreMLModel(for: model) {
                        return visionModel
                    }
                }
            }
        }
        return nil
    }

    private func eventKind(for label: String) -> CAEventKind? {
        switch label.lowercased() {
        case "person": return .person
        case "car", "truck", "bus", "motorbike", "motorcycle", "bicycle": return .vehicle
        case "chair", "couch", "sofa", "bed", "diningtable", "dining table", "bench": return .furniture
        case "fire hydrant", "stop sign", "parking meter", "pottedplant", "potted plant": return .obstacle
        default: return nil
        }
    }

    private func approximateDistance(kind: CAEventKind, boundingBox: CGRect) -> Double? {
        let referenceHeight: Double
        switch kind {
        case .person: referenceHeight = 1.7
        case .vehicle: referenceHeight = 1.5
        case .furniture: referenceHeight = 1.0
        default: return nil
        }
        let distance = referenceHeight * 0.88 / max(Double(boundingBox.height), 0.05)
        return min(max((distance * 10).rounded() / 10, 0.5), 12)
    }

    private func approachSpeed(for key: String, distance: Double?, now: TimeInterval) -> Double {
        guard let distance else { return 0 }
        defer { trackHistory[key] = (distance, now) }
        guard let previous = trackHistory[key], now > previous.time else { return 0 }
        return max(0, (previous.distance - distance) / (now - previous.time))
    }

    private func percentile(_ values: [Double], fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }

    private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private func demoSequence(for scenario: String) -> [CASpatialEvent] {
        let now = ProcessInfo.processInfo.systemUptime
        switch scenario {
        case "approaching-vehicle":
            return [
                CASpatialEvent(id: "demo-vehicle-right", kind: .vehicle, direction: .right, proximity: .medium, approximateDistanceMeters: 4.8, approachSpeed: 1.2, confidence: 0.92, urgency: 0.72, timestamp: now, box: CGRect(x: 0.68, y: 0.32, width: 0.24, height: 0.35)),
                CASpatialEvent(id: "demo-vehicle-center", kind: .vehicle, direction: .center, proximity: .near, approximateDistanceMeters: 1.8, approachSpeed: 1.8, confidence: 0.95, urgency: 0.96, timestamp: now, box: CGRect(x: 0.34, y: 0.22, width: 0.34, height: 0.5)),
            ]
        case "hallway":
            return [
                CASpatialEvent(id: "demo-obstacle-left", kind: .obstacle, direction: .left, proximity: .medium, approximateDistanceMeters: nil, approachSpeed: 0, confidence: 0.81, urgency: 0.58, timestamp: now, box: CGRect(x: 0.04, y: 0.35, width: 0.28, height: 0.55)),
                CASpatialEvent(id: "demo-furniture-center", kind: .furniture, direction: .center, proximity: .near, approximateDistanceMeters: 1.4, approachSpeed: 0.3, confidence: 0.88, urgency: 0.84, timestamp: now, box: CGRect(x: 0.36, y: 0.42, width: 0.3, height: 0.42)),
            ]
        default:
            return [
                CASpatialEvent(id: "demo-person-left", kind: .person, direction: .left, proximity: .medium, approximateDistanceMeters: 3.6, approachSpeed: 0.6, confidence: 0.94, urgency: 0.64, timestamp: now, box: CGRect(x: 0.08, y: 0.2, width: 0.25, height: 0.58)),
                CASpatialEvent(id: "demo-person-center", kind: .person, direction: .center, proximity: .near, approximateDistanceMeters: 1.6, approachSpeed: 1.1, confidence: 0.96, urgency: 0.91, timestamp: now, box: CGRect(x: 0.38, y: 0.12, width: 0.28, height: 0.72)),
                CASpatialEvent(id: "demo-person-right", kind: .person, direction: .right, proximity: .medium, approximateDistanceMeters: 3.1, approachSpeed: 0.2, confidence: 0.9, urgency: 0.57, timestamp: now, box: CGRect(x: 0.7, y: 0.24, width: 0.22, height: 0.52)),
            ]
        }
    }
}
