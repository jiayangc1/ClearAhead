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
    private let feedback = Feedback()
    private let collisionTracker = CollisionTracker()
    private let opticalFlowAnalyzer = OpticalFlowAnalyzer()
    private let motionManager = CMMotionManager()
    private var configuration = FeedbackConfiguration()
    private var sessionActive = false
    private var demoTimer: DispatchSourceTimer?

    private lazy var objectModel = loadModel(named: ["YOLO26n"])
    private lazy var depthModel = loadModel(named: ["YOLO26nDepth"])
    private var objectEvents: [SpatialEvent] = []
    private var depthEvents: [SpatialEvent] = []
    private var latestDepthMap: DepthMap?
    private var loomingEvent: SpatialEvent?
    private var depthPersistence: [Direction: Int] = [:]
    private var latestDepthSupport = 0.0
    private var latestDepthSupportTime: TimeInterval = 0
    private var latestRotationRate = 0.0
    private var lastObjectInference: TimeInterval = 0
    private var lastDepthInference: TimeInterval = 0
    private var lastFlowInference: TimeInterval = 0
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
    private var baseImageQuality = "good"
    private var baseImageQualityMessage = "Camera view is clear"
    private var cameraTooClose = false
    private var closeDepthFrames = 0
    private var clearDepthFrames = 0
    private var transientQualityUntil: TimeInterval = 0
    private var interruptedSessionWasActive = false
    private var hasVisibleEvent = false

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

    func start(configuration: FeedbackConfiguration) {
        stateLock.lock()
        self.configuration = configuration
        sessionActive = true
        stateLock.unlock()
        prioritizer.reset()
        collisionTracker.reset()
        opticalFlowAnalyzer.reset()
        objectEvents = []
        depthEvents = []
        latestDepthMap = nil
        loomingEvent = nil
        depthPersistence = [:]
        latestDepthSupport = 0
        latestDepthSupportTime = 0
        hasVisibleEvent = false
        cameraTooClose = false
        closeDepthFrames = 0
        clearDepthFrames = 0
        lastQuality = ""
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
        collisionTracker.reset()
        opticalFlowAnalyzer.reset()
        ClearAheadModule.emit(name: "sessionStatus", body: [
            "state": "idle",
            "message": "Assist mode stopped",
        ])
    }

    func update(configuration: FeedbackConfiguration) {
        stateLock.lock()
        self.configuration = configuration
        stateLock.unlock()
    }

    func process(sampleBuffer: CMSampleBuffer) {
        stateLock.lock()
        let isSessionActive = sessionActive
        let currentConfiguration = configuration
        stateLock.unlock()
        guard isSessionActive, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        guard frameLock.try() else {
            stateLock.lock()
            droppedFrameCount += 1
            stateLock.unlock()
            return
        }
        defer { frameLock.unlock() }

        let frameStartTime = ProcessInfo.processInfo.systemUptime
        frameCount += 1
        let thermalState = ProcessInfo.processInfo.thermalState
        let thermallyLimited = thermalState == .serious || thermalState == .critical
        let usesResponsiveProcessing = currentConfiguration.processingMode == "responsive"
        let objectInterval = thermallyLimited ? 0.22 : 0.11
        let depthInterval = thermallyLimited ? 0.5 : (usesResponsiveProcessing ? 0.5 : 0.18)
        let flowInterval = thermallyLimited ? 0.28 : 0.14

        if frameStartTime - lastFlowInference >= flowInterval {
            let depthSupport = frameStartTime - latestDepthSupportTime < 0.8 ? latestDepthSupport : 0
            let observation = opticalFlowAnalyzer.analyze(
                pixelBuffer: pixelBuffer,
                now: frameStartTime,
                rotationRate: currentRotationRate(),
                depthSupport: depthSupport
            )
            loomingEvent = observation.map { loomingEvent(from: $0, now: frameStartTime) }
            lastFlowInference = frameStartTime
        }

        if frameStartTime - lastQualityCheck >= 0.65 {
            evaluateImageQuality(pixelBuffer: pixelBuffer)
            lastQualityCheck = frameStartTime
        }

        let shouldDetectObjects = objectModel != nil && frameStartTime - lastObjectInference >= objectInterval
        let shouldEstimateDepth = depthModel != nil && frameStartTime - lastDepthInference >= depthInterval
        let depthStride = usesResponsiveProcessing ? 4 : 2
        if shouldEstimateDepth && (!shouldDetectObjects || inferenceCount % depthStride == depthStride - 1) {
            depthEvents = estimateDepthEvents(
                pixelBuffer: pixelBuffer,
                now: frameStartTime,
                configuration: currentConfiguration
            )
            lastDepthInference = frameStartTime
            depthInferenceCount += 1
            inferenceCount += 1
        } else if shouldDetectObjects {
            objectEvents = detectObjects(
                pixelBuffer: pixelBuffer,
                now: frameStartTime,
                configuration: currentConfiguration
            )
            lastObjectInference = frameStartTime
            objectInferenceCount += 1
            inferenceCount += 1
        }

        let freshEvents = (objectEvents + depthEvents + [loomingEvent].compactMap { $0 })
            .filter { frameStartTime - $0.timestamp < 0.7 }
        if let selected = prioritizer.select(
            from: freshEvents,
            configuration: currentConfiguration,
            now: frameStartTime
        ) {
            feedback.deliver(selected, configuration: currentConfiguration)
            ClearAheadModule.emit(name: "topEvent", body: selected.dictionary)
            hasVisibleEvent = true
        } else if !prioritizer.hasActiveEvent, hasVisibleEvent {
            ClearAheadModule.emit(name: "eventCleared", body: [:])
            hasVisibleEvent = false
        }

        latestLatencyMs = (ProcessInfo.processInfo.systemUptime - frameStartTime) * 1_000
        emitMetricsIfNeeded(now: frameStartTime)
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

    private func detectObjects(
        pixelBuffer: CVPixelBuffer,
        now: TimeInterval,
        configuration: FeedbackConfiguration
    ) -> [SpatialEvent] {
        guard let objectModel else { return [] }
        let request = VNCoreMLRequest(model: objectModel)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let recognizedObjects = request.results as? [VNRecognizedObjectObservation] ?? []
        let detections: [ObjectDetection]
        if !recognizedObjects.isEmpty {
            detections = recognizedObjects.compactMap { observation in
                guard let label = observation.labels.first,
                      let kind = eventKind(for: label.identifier) else { return nil }
                let box = observation.boundingBox
                return ObjectDetection(
                    kind: kind,
                    label: normalizedObjectLabel(label.identifier),
                    box: box,
                    distanceMeters: latestDepthMap?.distance(inVisionBox: box)
                        ?? approximateDistance(kind: kind, boundingBox: box),
                    confidence: Double(label.confidence)
                )
            }
        } else {
            let modelOutputs = (request.results as? [VNCoreMLFeatureValueObservation] ?? [])
                .compactMap { $0.featureValue.multiArrayValue }
            detections = modelOutputs
                .flatMap(ModelOutputDecoder.detections)
                .compactMap { detection in
                    guard let label = cocoLabel(for: detection.classIdentifier),
                          let kind = eventKind(forCOCOClass: detection.classIdentifier) else { return nil }
                    return ObjectDetection(
                        kind: kind,
                        label: label,
                        box: detection.box,
                        distanceMeters: latestDepthMap?.distance(inVisionBox: detection.box)
                            ?? approximateDistance(kind: kind, boundingBox: detection.box),
                        confidence: detection.confidence
                    )
                }
        }
        return collisionTracker.update(
            detections: detections,
            now: now,
            configuration: configuration,
            rotationRate: currentRotationRate()
        )
    }

    private func estimateDepthEvents(
        pixelBuffer: CVPixelBuffer,
        now: TimeInterval,
        configuration: FeedbackConfiguration
    ) -> [SpatialEvent] {
        guard let depthModel else { return [] }
        let request = VNCoreMLRequest(model: depthModel)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let depthOutput = (request.results as? [VNCoreMLFeatureValueObservation])?.first(where: {
            $0.featureValue.multiArrayValue != nil
        }), let depthValues = depthOutput.featureValue.multiArrayValue else {
            return []
        }
        guard let depthMap = DepthMap(array: depthValues) else { return [] }
        latestDepthMap = depthMap
        updateCloseCameraState(from: depthMap)
        return depthEvents(from: depthMap, now: now, configuration: configuration)
    }

    private func depthEvents(
        from depthMap: DepthMap,
        now: TimeInterval,
        configuration: FeedbackConfiguration
    ) -> [SpatialEvent] {
        let sectorSamples = (0..<3).map { sectorIndex in
            depthMap.samples(
                in: CGRect(x: Double(sectorIndex) / 3, y: 0.28, width: 1.0 / 3, height: 0.72),
                step: max(2, min(depthMap.width, depthMap.height) / 40)
            )
        }
        let directions: [Direction] = [.left, .center, .right]
        var observedDirections = Set<Direction>()
        let events = sectorSamples.enumerated().compactMap { sectorIndex, samples -> SpatialEvent? in
            guard samples.count > 12 else { return nil }
            let nearbyDistance = DepthMap.percentile(samples, fraction: 0.22)
            let warningDistanceCoverage = Double(samples.filter { $0 <= configuration.warningDistanceMeters }.count)
                / Double(samples.count)
            guard nearbyDistance <= configuration.warningDistanceMeters, warningDistanceCoverage >= 0.08 else {
                return nil
            }
            let proximity = Proximity.from(distance: nearbyDistance)
            let direction = directions[sectorIndex]
            observedDirections.insert(direction)
            let consecutiveFrames = (depthPersistence[direction] ?? 0) + 1
            depthPersistence[direction] = consecutiveFrames
            let distanceConfidence = 1 - min(nearbyDistance / configuration.warningDistanceMeters, 1)
            let confidence = min(0.52 + warningDistanceCoverage * 0.28 + distanceConfidence * 0.18, 0.96)
            let trajectoryConfidence = confidence * min(Double(consecutiveFrames) / 3, 1)
            let collisionRisk: CollisionRisk = direction == .center
                && proximity == .near
                && consecutiveFrames >= 3
                && trajectoryConfidence >= 0.65 ? .caution : .none
            return SpatialEvent(
                id: "depth:\(direction.rawValue)",
                kind: .obstacle,
                direction: direction,
                proximity: proximity,
                approximateDistanceMeters: (nearbyDistance * 10).rounded() / 10,
                approachSpeed: 0,
                motionState: collisionRisk == .none ? .stationary : .approaching,
                collisionRisk: collisionRisk,
                trajectoryConfidence: trajectoryConfidence,
                confidence: confidence,
                urgency: 0,
                timestamp: now,
                box: CGRect(x: CGFloat(sectorIndex) / 3, y: 0.35, width: 1.0 / 3, height: 0.65)
            )
        }
        for direction in directions where !observedDirections.contains(direction) {
            depthPersistence[direction] = 0
        }
        let centerSamples = sectorSamples[1]
        if centerSamples.count > 12 {
            let centerDistance = DepthMap.percentile(centerSamples, fraction: 0.22)
            latestDepthSupport = 1 - min(centerDistance / configuration.warningDistanceMeters, 1)
            latestDepthSupportTime = now
        }
        return events
    }

    private func updateCloseCameraState(from depthMap: DepthMap) {
        let centerSamples = depthMap.samples(in: CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84), step: 4)
        guard centerSamples.count > 20 else { return }
        let closeRangeCoverage = Double(centerSamples.filter { $0 <= 0.35 }.count) / Double(centerSamples.count)
        if closeRangeCoverage >= 0.45 {
            closeDepthFrames += 1
            clearDepthFrames = 0
        } else if closeRangeCoverage < 0.25 {
            clearDepthFrames += 1
            closeDepthFrames = 0
        }
        if !cameraTooClose, closeDepthFrames >= 3 {
            cameraTooClose = true
            emitEffectiveQuality()
        } else if cameraTooClose, clearDepthFrames >= 3 {
            cameraTooClose = false
            emitEffectiveQuality()
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
        baseImageQuality = quality
        baseImageQualityMessage = message
        emitEffectiveQuality()
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
            stateLock.lock()
            latestRotationRate = magnitude
            stateLock.unlock()
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

    private func emitEffectiveQuality() {
        if cameraTooClose {
            emitQuality("camera-too-close", message: "Camera too close. Move it back.")
        } else {
            emitQuality(baseImageQuality, message: baseImageQualityMessage)
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
            return "Camera active. YOLO26 models are not installed."
        }
        if objectModel == nil || depthModel == nil {
            return "Camera active. One YOLO26 model is unavailable."
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

    private func eventKind(for label: String) -> EventKind? {
        switch label.lowercased() {
        case "person": return .person
        case "car", "truck", "bus", "motorbike", "motorcycle", "bicycle": return .vehicle
        case "chair", "couch", "sofa", "bed", "diningtable", "dining table", "bench": return .furniture
        case "fire hydrant", "stop sign", "parking meter", "pottedplant", "potted plant": return .obstacle
        default: return .obstacle
        }
    }

    private func eventKind(forCOCOClass identifier: Int) -> EventKind? {
        guard cocoLabel(for: identifier) != nil else { return nil }
        switch identifier {
        case 0: return .person
        case 1, 2, 3, 4, 5, 6, 7, 8: return .vehicle
        case 13, 56, 57, 58, 59, 60: return .furniture
        default: return .obstacle
        }
    }

    private func cocoLabel(for identifier: Int) -> String? {
        let labels = [
            "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat", "traffic light",
            "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow",
            "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella", "handbag", "tie", "suitcase", "frisbee",
            "skis", "snowboard", "sports ball", "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket", "bottle",
            "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple", "sandwich", "orange",
            "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair", "couch", "potted plant", "bed",
            "dining table", "toilet", "tv", "laptop", "mouse", "remote", "keyboard", "cell phone", "microwave", "oven",
            "toaster", "sink", "refrigerator", "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush",
        ]
        return labels.indices.contains(identifier) ? labels[identifier] : nil
    }

    private func normalizedObjectLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "_", with: " ").lowercased()
    }

    private func approximateDistance(kind: EventKind, boundingBox: CGRect) -> Double? {
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

    private func currentRotationRate() -> Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestRotationRate
    }

    private func loomingEvent(from observation: LoomingObservation, now: TimeInterval) -> SpatialEvent {
        SpatialEvent(
            id: "looming:center",
            kind: .obstacle,
            direction: .center,
            proximity: observation.collisionRisk == .imminent ? .near : .medium,
            approximateDistanceMeters: nil,
            approachSpeed: 0,
            motionState: .approaching,
            collisionRisk: observation.collisionRisk,
            timeToCollisionSeconds: observation.timeToCollisionSeconds,
            trajectoryConfidence: observation.confidence,
            confidence: observation.confidence,
            urgency: 0,
            timestamp: now,
            box: CGRect(x: 0.3, y: 0.25, width: 0.4, height: 0.75)
        )
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

    private func demoSequence(for scenario: String) -> [SpatialEvent] {
        let now = ProcessInfo.processInfo.systemUptime
        switch scenario {
        case "approaching-vehicle":
            return [
                SpatialEvent(id: "demo-vehicle-right", kind: .vehicle, direction: .right, proximity: .medium, approximateDistanceMeters: 4.8, approachSpeed: 1.2, confidence: 0.92, urgency: 0.72, timestamp: now, box: CGRect(x: 0.68, y: 0.32, width: 0.24, height: 0.35)),
                SpatialEvent(id: "demo-vehicle-center", kind: .vehicle, direction: .center, proximity: .near, approximateDistanceMeters: 1.8, approachSpeed: 1.8, motionState: .approaching, collisionRisk: .imminent, timeToCollisionSeconds: 1, trajectoryConfidence: 0.93, confidence: 0.95, urgency: 0.96, timestamp: now, box: CGRect(x: 0.34, y: 0.22, width: 0.34, height: 0.5)),
            ]
        case "hallway":
            return [
                SpatialEvent(id: "demo-obstacle-left", kind: .obstacle, direction: .left, proximity: .medium, approximateDistanceMeters: nil, approachSpeed: 0, confidence: 0.81, urgency: 0.58, timestamp: now, box: CGRect(x: 0.04, y: 0.35, width: 0.28, height: 0.55)),
                SpatialEvent(id: "demo-furniture-center", kind: .furniture, direction: .center, proximity: .near, approximateDistanceMeters: 1.4, approachSpeed: 0.3, motionState: .approaching, collisionRisk: .caution, timeToCollisionSeconds: 2.6, trajectoryConfidence: 0.8, confidence: 0.88, urgency: 0.84, timestamp: now, box: CGRect(x: 0.36, y: 0.42, width: 0.3, height: 0.42)),
            ]
        default:
            return [
                SpatialEvent(id: "demo-person-left", kind: .person, direction: .left, proximity: .medium, approximateDistanceMeters: 3.6, approachSpeed: 0.6, confidence: 0.94, urgency: 0.64, timestamp: now, box: CGRect(x: 0.08, y: 0.2, width: 0.25, height: 0.58)),
                SpatialEvent(id: "demo-person-center", kind: .person, direction: .center, proximity: .near, approximateDistanceMeters: 1.6, approachSpeed: 1.1, motionState: .approaching, collisionRisk: .caution, timeToCollisionSeconds: 2.1, trajectoryConfidence: 0.91, confidence: 0.96, urgency: 0.91, timestamp: now, box: CGRect(x: 0.38, y: 0.12, width: 0.28, height: 0.72)),
                SpatialEvent(id: "demo-person-right", kind: .person, direction: .right, proximity: .medium, approximateDistanceMeters: 3.1, approachSpeed: 0.2, confidence: 0.9, urgency: 0.57, timestamp: now, box: CGRect(x: 0.7, y: 0.24, width: 0.22, height: 0.52)),
            ]
        }
    }
}
