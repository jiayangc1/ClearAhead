import AVFoundation
import CoreML
import CoreMotion
import CryptoKit
import Foundation
import OSLog
import Vision

private struct ModelLoadResult {
    let model: VNCoreMLModel?
    let resource: String?
    let error: String?

    var dictionary: [String: Any] {
        [
            "loaded": model != nil,
            "resource": resource as Any? ?? NSNull(),
            "error": error as Any? ?? NSNull(),
        ]
    }
}

final class ClearAheadEngine {
    static let shared = ClearAheadEngine()

    private let stateLock = NSLock()
    private let frameLock = NSLock()
    private let depthMapQueue = DispatchQueue(label: "com.clearahead.depth-preview", qos: .utility)
    private var depthPreviewGeneration = 0
    private var depthPreviewPending = false
    private let prioritizer = EventPrioritizer()
    private let feedback = Feedback()
    private let collisionTracker = CollisionTracker()
    private let motionManager = CMMotionManager()
    private var configuration = FeedbackConfiguration()
    private var sessionActive = false
    private var demoTimer: DispatchSourceTimer?
    private var demoGeneration = 0

    private let logger = Logger(subsystem: "com.clearahead.vision", category: "inference")
    private var objectModelResult = ModelLoadResult(model: nil, resource: nil, error: "Model not prepared")
    private var depthModelResult = ModelLoadResult(model: nil, resource: nil, error: "Model not prepared")
    private var preparedModelKey: String?
    private var modelPreparationGeneration = 0
    private var objectModel: VNCoreMLModel? { objectModelResult.model }
    private var depthModel: VNCoreMLModel? { depthModelResult.model }
    private var objectInferenceError: String?
    private var depthInferenceError: String?
    private var depthInferenceFailureCount = 0
    private var depthInferenceWarningActive = false
    private var objectEvents: [SpatialEvent] = []
    private var depthEvents: [SpatialEvent] = []
    private var latestDepthMap: DepthMap?
    private var latestDepthMapTime: TimeInterval = 0
    private var previousPathObstacle: PathObstacleObservation?
    private var previousPathTime: TimeInterval = 0
    private var pathClosingSpeed = 0.0
    private var pathObservationCount = 0
    private var latestRotationRate = 0.0
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
    private var latestProcessingLatencyMs = 0.0
    private var lastQuality = "good"
    private var baseImageQuality = "good"
    private var baseImageQualityMessage = "Camera view is clear"
    private var cameraTooClose = false
    private var closeDepthFrames = 0
    private var clearDepthFrames = 0
    private var transientQualityUntil: TimeInterval = 0
    private var interruptedSessionWasActive = false
    private var hasVisibleEvent = false
    private var lastTopEventEmission: TimeInterval = 0

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

    func prepareModels(
        configuration: FeedbackConfiguration,
        allowDetectorOnly: Bool = false,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let requestedKey = configuration.modelVariant
        stateLock.lock()
        modelPreparationGeneration += 1
        let preparationGeneration = modelPreparationGeneration
        let modelsAlreadyPrepared = preparedModelKey == requestedKey
            && objectModelResult.model != nil
            && depthModelResult.model != nil
        stateLock.unlock()
        if modelsAlreadyPrepared {
            completion(.success(()))
            return
        }
        ModelManager.shared.prepare(
            variant: configuration.modelVariant,
            allowDetectorOnly: allowDetectorOnly,
            progress: { progress, message in
                ClearAheadModule.emit(name: "modelDownloadProgress", body: [
                    "modelVariant": configuration.modelVariant,
                    "progress": progress,
                    "message": message,
                ])
            },
            completion: { result in
                switch result {
                case let .success(pair):
                    let detector = self.loadModel(at: pair.detector)
                    let depth = pair.depth.map { self.loadModel(at: $0) }
                        ?? ModelLoadResult(model: nil, resource: nil, error: "Depth model unavailable")
                    self.frameLock.lock()
                    self.stateLock.lock()
                    if self.modelPreparationGeneration == preparationGeneration {
                        self.objectModelResult = detector
                        self.depthModelResult = depth
                        self.preparedModelKey = detector.error == nil && depth.error == nil
                            ? requestedKey
                            : nil
                    }
                    self.stateLock.unlock()
                    self.frameLock.unlock()
                    if let error = detector.error ?? (allowDetectorOnly ? nil : depth.error) {
                        completion(.failure(NSError(
                            domain: "ClearAheadModels",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: error]
                        )))
                    } else {
                        completion(.success(()))
                    }
                case let .failure(error):
                    completion(.failure(error))
                }
            },
            recoveredDepth: { url in
                let depth = self.loadModel(at: url)
                self.frameLock.lock()
                self.stateLock.lock()
                let isCurrent = self.modelPreparationGeneration == preparationGeneration
                    && self.objectModelResult.model != nil
                if isCurrent && depth.model != nil {
                    self.depthModelResult = depth
                    self.preparedModelKey = requestedKey
                    self.depthInferenceError = nil
                    self.depthInferenceFailureCount = 0
                    self.depthInferenceWarningActive = false
                }
                let isActive = self.sessionActive
                self.stateLock.unlock()
                self.frameLock.unlock()
                if isCurrent && isActive && depth.model != nil {
                    ClearAheadModule.emit(name: "sessionStatus", body: [
                        "state": "running",
                        "message": "Camera and on-device models active",
                        "severity": "info",
                        "code": "models-ready",
                        "diagnostics": self.modelDiagnostics(),
                    ])
                }
            }
        )
    }

    func start(configuration: FeedbackConfiguration) {
        frameLock.lock()
        defer { frameLock.unlock() }
        cancelDemoTimer()
        stateLock.lock()
        self.configuration = configuration
        sessionActive = true
        interruptedSessionWasActive = false
        depthPreviewGeneration += 1
        stateLock.unlock()
        prioritizer.reset()
        collisionTracker.reset()
        objectEvents = []
        depthEvents = []
        latestDepthMap = nil
        latestDepthMapTime = 0
        objectInferenceError = nil
        depthInferenceError = nil
        depthInferenceFailureCount = 0
        depthInferenceWarningActive = false
        previousPathObstacle = nil
        previousPathTime = 0
        pathClosingSpeed = 0
        pathObservationCount = 0
        hasVisibleEvent = false
        lastTopEventEmission = 0
        cameraTooClose = false
        closeDepthFrames = 0
        clearDepthFrames = 0
        stateLock.lock()
        lastQuality = ""
        stateLock.unlock()
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
            "severity": modelsAvailable ? "info" : objectModel != nil ? "warning" : "error",
            "code": modelsAvailable ? "models-ready" : objectModel != nil ? "depth-unavailable" : "model-load-failed",
            "diagnostics": modelDiagnostics(),
        ])
    }

    func stop() {
        frameLock.lock()
        stateLock.lock()
        sessionActive = false
        interruptedSessionWasActive = false
        depthPreviewGeneration += 1
        stateLock.unlock()
        cancelDemoTimer()
        feedback.stop()
        motionManager.stopDeviceMotionUpdates()
        prioritizer.reset()
        collisionTracker.reset()
        frameLock.unlock()
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
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        guard frameLock.try() else {
            stateLock.lock()
            droppedFrameCount += 1
            stateLock.unlock()
            return
        }
        defer { frameLock.unlock() }
        stateLock.lock()
        let isSessionActive = sessionActive
        let currentConfiguration = configuration
        stateLock.unlock()
        guard isSessionActive else { return }

        let frameStartTime = ProcessInfo.processInfo.systemUptime
        frameCount += 1
        let thermalState = ProcessInfo.processInfo.thermalState
        let thermallyLimited = thermalState == .serious || thermalState == .critical
        let usesResponsiveProcessing = currentConfiguration.processingMode == "responsive"
        let objectInterval = thermallyLimited ? 0.22 : 0.11
        let depthInterval = thermallyLimited ? 0.5 : (usesResponsiveProcessing ? 0.35 : 0.18)

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

        let freshEvents = (objectEvents + depthEvents)
            .filter { frameStartTime - $0.timestamp < 0.7 }
        if let selected = prioritizer.select(
            from: freshEvents,
            configuration: currentConfiguration,
            now: frameStartTime
        ) {
            if prioritizer.shouldAnnounce(selected, now: frameStartTime) {
                feedback.deliver(selected, configuration: currentConfiguration)
            }
            if !hasVisibleEvent || frameStartTime - lastTopEventEmission >= 0.25 {
                ClearAheadModule.emit(name: "topEvent", body: selected.dictionary)
                lastTopEventEmission = frameStartTime
            }
            hasVisibleEvent = true
        } else if !prioritizer.hasActiveEvent, hasVisibleEvent {
            ClearAheadModule.emit(name: "eventCleared", body: [:])
            hasVisibleEvent = false
        }

        latestProcessingLatencyMs = (ProcessInfo.processInfo.systemUptime - frameStartTime) * 1_000
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
        frameLock.lock()
        defer { frameLock.unlock() }
        cancelDemoTimer()
        stateLock.lock()
        sessionActive = true
        interruptedSessionWasActive = false
        depthPreviewGeneration += 1
        let currentConfiguration = configuration
        demoGeneration += 1
        let currentDemoGeneration = demoGeneration
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
            frameLock.lock()
            defer { frameLock.unlock() }
            stateLock.lock()
            let shouldDeliver = sessionActive && demoGeneration == currentDemoGeneration
            stateLock.unlock()
            guard shouldDeliver else { return }
            let event = sequence[index % sequence.count]
            index += 1
            feedback.deliver(event, configuration: currentConfiguration)
            ClearAheadModule.emit(name: "topEvent", body: event.dictionary)
            ClearAheadModule.emit(name: "performanceMetrics", body: [
                "cameraFps": 0,
                "detectorFps": 0,
                "depthFps": 0,
                "droppedFrames": 0,
                "processingLatencyMs": 0,
                "thermalState": "nominal",
            ])
        }
        stateLock.lock()
        demoTimer = timer
        stateLock.unlock()
        timer.resume()
    }

    func stopDemo() {
        frameLock.lock()
        stateLock.lock()
        sessionActive = false
        interruptedSessionWasActive = false
        depthPreviewGeneration += 1
        stateLock.unlock()
        cancelDemoTimer()
        feedback.stop()
        frameLock.unlock()
        ClearAheadModule.emit(name: "sessionStatus", body: [
            "state": "idle",
            "message": "Demo stopped",
        ])
    }

    private func cancelDemoTimer() {
        stateLock.lock()
        demoGeneration += 1
        let timer = demoTimer
        demoTimer = nil
        stateLock.unlock()
        timer?.cancel()
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
            objectInferenceError = String(describing: error)
            logger.error("YOLO26 detector inference failed: \(String(describing: error), privacy: .public)")
            if configuration.showBoundingBoxes {
                ClearAheadModule.emit(name: "detectionsUpdated", body: [Any]())
            }
            return []
        }
        let modelOutputs = (request.results as? [VNCoreMLFeatureValueObservation] ?? [])
            .compactMap { $0.featureValue.multiArrayValue }
        guard !modelOutputs.isEmpty else {
            objectInferenceError = "Detector returned no detection array"
            if configuration.showBoundingBoxes {
                ClearAheadModule.emit(name: "detectionsUpdated", body: [Any]())
            }
            return []
        }
        objectInferenceError = nil
        let modelDetections = modelOutputs.flatMap { ModelOutput.detections(from: $0) }
        if configuration.showBoundingBoxes {
            let visibleDetections = modelDetections
            .filter { $0.confidence >= 0.25 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(20)
            ClearAheadModule.emit(name: "detectionsUpdated", body: visibleDetections.compactMap { detection -> [String: Any]? in
                guard let label = cocoLabel(for: detection.classIdentifier) else { return nil }
                return [
                    "label": label,
                    "confidence": detection.confidence,
                    "box": [
                        "x": detection.box.minX,
                        "y": 1 - detection.box.maxY,
                        "width": detection.box.width,
                        "height": detection.box.height,
                    ],
                ]
            })
        }
        let detections = modelDetections.compactMap { detection -> ObjectDetection? in
            guard let label = cocoLabel(for: detection.classIdentifier),
                  let kind = eventKind(forCOCOClass: detection.classIdentifier) else { return nil }
            return ObjectDetection(
                kind: kind,
                label: label,
                box: detection.box,
                depth: recentDepthMeasurement(inVisionBox: detection.box, now: now),
                confidence: detection.confidence
            )
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
            recordDepthInferenceFailure(String(describing: error))
            logger.error("YOLO26 depth inference failed: \(String(describing: error), privacy: .public)")
            return []
        }
        guard let depthOutput = (request.results as? [VNCoreMLFeatureValueObservation])?.first(where: {
            $0.featureValue.multiArrayValue != nil
        }), let depthValues = depthOutput.featureValue.multiArrayValue else {
            recordDepthInferenceFailure("Depth model returned no depth array")
            return []
        }
        guard let depthMap = DepthMap(array: depthValues) else {
            recordDepthInferenceFailure("Depth model returned an invalid depth array")
            return []
        }
        depthInferenceError = nil
        depthInferenceFailureCount = 0
        if depthInferenceWarningActive {
            depthInferenceWarningActive = false
            ClearAheadModule.emit(name: "sessionStatus", body: [
                "state": "running",
                "message": "Camera and on-device models active",
                "severity": "info",
                "code": "models-ready",
            ])
        }
        latestDepthMap = depthMap
        latestDepthMapTime = now
        updateCloseCameraState(from: depthMap)
        let event = pathObstacleEvent(from: depthMap, now: now, configuration: configuration)
        if configuration.depthMapEnabled {
            stateLock.lock()
            let shouldQueue = !depthPreviewPending
            let generation = depthPreviewGeneration
            if shouldQueue { depthPreviewPending = true }
            stateLock.unlock()
            if shouldQueue {
                depthMapQueue.async { [weak self] in
                    guard let self else { return }
                    let dataURL = depthMap.heatmapDataURL()
                    self.stateLock.lock()
                    let shouldEmit = self.sessionActive && self.depthPreviewGeneration == generation
                    self.depthPreviewPending = false
                    self.stateLock.unlock()
                    if shouldEmit, let dataURL {
                        ClearAheadModule.emit(name: "depthMapUpdated", body: ["dataUrl": dataURL])
                    }
                }
            }
        }
        return event.map { [$0] } ?? []
    }

    private func recordDepthInferenceFailure(_ message: String) {
        depthInferenceError = message
        depthInferenceFailureCount += 1
        if depthInferenceFailureCount >= 3, !depthInferenceWarningActive {
            depthInferenceWarningActive = true
            ClearAheadModule.emit(name: "sessionStatus", body: [
                "state": "running",
                "message": "Depth unavailable. Named object cues remain active.",
                "severity": "warning",
                "code": "depth-unavailable",
            ])
        }
    }

    private func pathObstacleEvent(
        from depthMap: DepthMap,
        now: TimeInterval,
        configuration: FeedbackConfiguration
    ) -> SpatialEvent? {
        guard let observation = depthMap.pathObstacle(within: configuration.warningDistanceMeters) else {
            previousPathObstacle = nil
            pathClosingSpeed = 0
            pathObservationCount = 0
            return nil
        }
        let stable = currentRotationRate() < 0.9
        if let previous = previousPathObstacle,
           now - previousPathTime < 0.8,
           overlapFraction(previous.box, observation.box) >= 0.3,
           stable {
            let elapsed = max(now - previousPathTime, 0.04)
            let observedSpeed = (previous.distanceMeters - observation.distanceMeters) / elapsed
            pathClosingSpeed += (observedSpeed - pathClosingSpeed) * 0.4
            pathObservationCount += 1
        } else {
            pathClosingSpeed = 0
            pathObservationCount = 1
        }
        previousPathObstacle = observation
        previousPathTime = now
        let approachSpeed = stable && pathObservationCount >= 2 ? max(0, pathClosingSpeed) : 0
        let timeToCollision = approachSpeed > 0.2 ? observation.distanceMeters / approachSpeed : nil
        let risk: CollisionRisk
        if let timeToCollision, pathObservationCount >= 3, timeToCollision <= 1.5 {
            risk = .imminent
        } else if let timeToCollision, pathObservationCount >= 3, timeToCollision <= 3 {
            risk = .caution
        } else {
            risk = .none
        }
        let confidence = min(0.6 + observation.coverage * 0.5, 0.95)
        return SpatialEvent(
            id: "depth:path",
            kind: .obstacle,
            direction: .center,
            proximity: Proximity.from(distance: observation.distanceMeters),
            approximateDistanceMeters: (observation.distanceMeters * 10).rounded() / 10,
            approachSpeed: approachSpeed,
            motionState: approachSpeed > 0.15 ? .approaching : .stationary,
            collisionRisk: risk,
            timeToCollisionSeconds: timeToCollision,
            trajectoryConfidence: confidence * min(Double(pathObservationCount) / 3, 1),
            confidence: confidence,
            urgency: 0,
            timestamp: now,
            box: observation.box
        )
    }

    private func overlapFraction(_ left: CGRect, _ right: CGRect) -> Double {
        let intersection = left.intersection(right)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = Double(intersection.width * intersection.height)
        let unionArea = Double(left.width * left.height + right.width * right.height) - intersectionArea
        return intersectionArea / max(unionArea, 0.001)
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
        stateLock.lock()
        let isTransientQualityActive = now < transientQualityUntil
        stateLock.unlock()
        if isTransientQualityActive { return }
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
        stateLock.lock()
        transientQualityUntil = max(
            transientQualityUntil,
            ProcessInfo.processInfo.systemUptime + duration
        )
        stateLock.unlock()
        emitQuality(quality, message: message)
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        if type == .began {
            stateLock.lock()
            let wasActive = sessionActive
            interruptedSessionWasActive = wasActive
            sessionActive = false
            depthPreviewGeneration += 1
            stateLock.unlock()
            guard wasActive else { return }
            ClearAheadModule.emit(name: "sessionStatus", body: [
                "state": "paused",
                "message": "Paused while audio is interrupted",
            ])
        } else {
            stateLock.lock()
            let shouldResume = interruptedSessionWasActive
            if shouldResume { sessionActive = true }
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
        stateLock.lock()
        guard quality != lastQuality else {
            stateLock.unlock()
            return
        }
        lastQuality = quality
        let currentConfiguration = configuration
        stateLock.unlock()
        ClearAheadModule.emit(name: "qualityChanged", body: ["quality": quality, "message": message])
        if quality != "good" {
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
            "processingLatencyMs": latestProcessingLatencyMs,
            "thermalState": thermalStateName(ProcessInfo.processInfo.thermalState),
            "objectModelLoaded": objectModel != nil,
            "depthModelLoaded": depthModel != nil,
            "objectInferenceError": objectInferenceError as Any? ?? NSNull(),
            "depthInferenceError": depthInferenceError as Any? ?? NSNull(),
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
        if objectModel == nil {
            return "Object detector unavailable. Assist Mode cannot identify named hazards."
        }
        if depthModel == nil {
            return "Depth unavailable. Named object cues remain active."
        }
        return "Camera and on-device models active"
    }

    private var modelsAvailable: Bool {
        objectModel != nil && depthModel != nil
    }

    private func modelDiagnostics() -> [String: Any] {
        [
            "objectModel": objectModelResult.dictionary,
            "depthModel": depthModelResult.dictionary,
        ]
    }

    private func loadModel(at assetURL: URL) -> ModelLoadResult {
        let configuration = MLModelConfiguration()
        if #available(iOS 16.0, visionOS 1.0, *) {
            configuration.computeUnits = .cpuAndNeuralEngine
        } else {
            configuration.computeUnits = .all
        }
        do {
            let modelURL: URL
            if assetURL.pathExtension == "mlmodelc" {
                modelURL = assetURL
            } else {
                let applicationSupport = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let cacheRoot = applicationSupport.appendingPathComponent("ClearAheadCompiledModels", isDirectory: true)
                try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
                let modified = (try FileManager.default.attributesOfItem(atPath: assetURL.path))[.modificationDate] as? Date
                let cacheIdentity = "\(assetURL.path):\(modified?.timeIntervalSince1970 ?? 0)"
                let cacheKey = SHA256.hash(data: Data(cacheIdentity.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                let cachedCompilation = cacheRoot.appendingPathComponent("\(cacheKey).mlmodelc")
                if FileManager.default.fileExists(atPath: cachedCompilation.path) {
                    modelURL = cachedCompilation
                } else {
                    let temporaryCompilation = try MLModel.compileModel(at: assetURL)
                    try FileManager.default.moveItem(at: temporaryCompilation, to: cachedCompilation)
                    modelURL = cachedCompilation
                }
            }
            let model: MLModel
            do {
                model = try MLModel(contentsOf: modelURL, configuration: configuration)
            } catch {
                guard assetURL.pathExtension != "mlmodelc" else { throw error }
                try? FileManager.default.removeItem(at: modelURL)
                let temporaryCompilation = try MLModel.compileModel(at: assetURL)
                try FileManager.default.moveItem(at: temporaryCompilation, to: modelURL)
                model = try MLModel(contentsOf: modelURL, configuration: configuration)
            }
            return ModelLoadResult(
                model: try VNCoreMLModel(for: model),
                resource: assetURL.lastPathComponent,
                error: nil
            )
        } catch {
            logger.error("Unable to load model at \(assetURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return ModelLoadResult(model: nil, resource: assetURL.lastPathComponent, error: String(describing: error))
        }
    }

    private func eventKind(forCOCOClass identifier: Int) -> EventKind? {
        switch identifier {
        case 0: return .person
        case 1, 2, 3, 5, 6, 7: return .vehicle
        case 13, 56, 57, 59, 60, 61: return .furniture
        default: return nil
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

    private func recentDepthMeasurement(inVisionBox box: CGRect, now: TimeInterval) -> DepthMeasurement? {
        guard now - latestDepthMapTime <= 0.35,
              let distance = latestDepthMap?.distance(inVisionBox: box) else { return nil }
        return DepthMeasurement(distanceMeters: distance, timestamp: latestDepthMapTime)
    }

    private func currentRotationRate() -> Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestRotationRate
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
