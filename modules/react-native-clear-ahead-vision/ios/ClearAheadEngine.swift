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
    var compiledURL: URL? = nil

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
    private var lastDepthPreviewTime: TimeInterval = 0
    private var sessionGeneration = 0
    private var watchdog: DispatchSourceTimer?
    private var health = SessionHealth(startedAt: 0)
    private var qualityState = SessionQualityState()
    private var lastPipelineStatus: PipelineStatus?
    private let prioritizer = EventPrioritizer()
    private let feedback = Feedback()
    private let collisionTracker = CollisionTracker()
    private var groundHazardTracker = GroundHazardTracker()
    private var throttle = AdaptiveThrottle()
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
    private var modelPreparationRequest: ModelDownloadRequest?
    private var objectModel: VNCoreMLModel? { objectModelResult.model }
    private var depthModel: VNCoreMLModel? { depthModelResult.model }
    private var objectInferenceError: String?
    private var depthInferenceError: String?
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
    private var lastMetricsEmission: TimeInterval = 0
    private var frameCount = 0
    private var objectInferenceCount = 0
    private var depthInferenceCount = 0
    private var droppedFrameCount = 0
    private var metricWindowStart = ProcessInfo.processInfo.systemUptime
    private var latestProcessingLatencyMs = 0.0
    private var lastQuality = "good"
    private var cameraTooClose = false
    private var closeDepthFrames = 0
    private var clearDepthFrames = 0
    private var hasVisibleEvent = false
    private var lastTopEventEmission: TimeInterval = 0

    private init() {
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.emitThermalQuality()
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
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
        let previousRequest = modelPreparationRequest
        modelPreparationRequest = nil
        let modelsAlreadyPrepared = preparedModelKey == requestedKey
            && objectModelResult.model != nil
            && (depthModelResult.model != nil || allowDetectorOnly)
        stateLock.unlock()
        previousRequest?.cancel()
        if modelsAlreadyPrepared {
            completion(.success(()))
            return
        }
        var validatedDetector: ModelLoadResult?
        var validatedDepth: ModelLoadResult?
        let request = ModelManager.shared.prepare(
            variant: configuration.modelVariant,
            allowDetectorOnly: allowDetectorOnly,
            progress: { progress, message in
                ClearAheadModule.emit(name: "modelDownloadProgress", body: [
                    "modelVariant": configuration.modelVariant,
                    "progress": progress,
                    "message": message,
                ], isCurrent: {
                    self.stateLock.lock()
                    defer { self.stateLock.unlock() }
                    return self.modelPreparationGeneration == preparationGeneration
                })
            },
            validate: { pair in
                self.stateLock.lock()
                let current = self.modelPreparationGeneration == preparationGeneration
                self.stateLock.unlock()
                guard current else { throw CocoaError(.userCancelled) }
                let detector = self.loadModel(at: pair.detector)
                let depth = pair.depth.map { self.loadModel(at: $0, isDepth: true) }
                    ?? ModelLoadResult(model: nil, resource: nil, error: "Depth model unavailable")
                if let error = detector.error ?? (pair.depth == nil && allowDetectorOnly ? nil : depth.error) {
                    self.trimCompiledCache()
                    throw NSError(domain: "ClearAheadModels", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: error])
                }
                validatedDetector = detector
                validatedDepth = depth
            },
            completion: { result in
                switch result {
                case .success:
                    self.stateLock.lock()
                    let current = self.modelPreparationGeneration == preparationGeneration
                    self.stateLock.unlock()
                    guard current else { completion(.failure(CocoaError(.userCancelled))); return }
                    guard let detector = validatedDetector, let depth = validatedDepth else {
                        completion(.failure(CocoaError(.fileReadCorruptFile))); return
                    }
                    self.frameLock.lock()
                    self.stateLock.lock()
                    let stillCurrent = self.modelPreparationGeneration == preparationGeneration
                    if stillCurrent {
                        self.objectModelResult = detector
                        self.depthModelResult = depth
                        self.preparedModelKey = detector.error == nil && (depth.error == nil || allowDetectorOnly)
                            ? requestedKey
                            : nil
                    }
                    self.stateLock.unlock()
                    self.frameLock.unlock()
                    self.trimCompiledCache()
                    completion(stillCurrent ? .success(()) : .failure(CocoaError(.userCancelled)))
                case let .failure(error):
                    completion(.failure(error))
                }
            }

        )
        stateLock.lock()
        let stillCurrent = modelPreparationGeneration == preparationGeneration
        if stillCurrent { modelPreparationRequest = request }
        stateLock.unlock()
        if !stillCurrent { request.cancel() }
    }

    func cancelModelPreparation() {
        stateLock.lock()
        modelPreparationGeneration += 1
        let request = modelPreparationRequest
        modelPreparationRequest = nil
        stateLock.unlock()
        request?.cancel()
    }

    func start(configuration: FeedbackConfiguration) {
        precondition(Thread.isMainThread)
        frameLock.lock()
        defer { frameLock.unlock() }
        cancelDemoTimer()
        stateLock.lock()
        self.configuration = configuration
        sessionActive = true
        sessionGeneration += 1
        depthPreviewGeneration += 1
        stateLock.unlock()
        resetSessionState()
        feedback.stop()
        feedback.start()
        motionManager.stopDeviceMotionUpdates()
        startMotionMonitoring()
        startWatchdog()
        emitThermalQuality()
        emitPipelineStatus()
    }

    // Called with frameLock held; device/model resources are session-independent.
    private func resetSessionState() {
        prioritizer.reset()
        collisionTracker.reset()
        groundHazardTracker.reset()
        throttle = AdaptiveThrottle()
        objectEvents = []
        depthEvents = []
        latestDepthMap = nil
        latestDepthMapTime = 0
        objectInferenceError = nil
        depthInferenceError = nil
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
        health = SessionHealth(startedAt: ProcessInfo.processInfo.systemUptime)
        qualityState = SessionQualityState()
        latestRotationRate = 0
        lastPipelineStatus = nil
        lastQuality = ""
        stateLock.unlock()
        lastObjectInference = 0
        lastDepthInference = 0
        lastQualityCheck = 0
        lastDepthPreviewTime = 0
        latestProcessingLatencyMs = 0
        stateLock.lock()
        droppedFrameCount = 0
        stateLock.unlock()
        resetMetrics()
        lastMetricsEmission = ProcessInfo.processInfo.systemUptime
    }

    func stop() {
        stop(message: "Assist mode stopped")
    }

    private func stop(message: String) {
        cancelModelPreparation()
        stateLock.lock()
        sessionActive = false
        modelPreparationGeneration += 1
        sessionGeneration += 1
        depthPreviewGeneration += 1
        stateLock.unlock()
        cancelDemoTimer()
        watchdog?.cancel()
        watchdog = nil
        feedback.stop()
        motionManager.stopDeviceMotionUpdates()
        // In-flight Core ML work cannot be cancelled. Invalidate it immediately
        // rather than blocking main while waiting for inference to finish.
        if frameLock.try() {
            prioritizer.reset()
            collisionTracker.reset()
            groundHazardTracker.reset()
            objectEvents = []
            depthEvents = []
            latestDepthMap = nil
            hasVisibleEvent = false
            frameLock.unlock()
        }
        emitSessionEvent(name: "eventCleared", body: [:], requireActive: false)
        emitSessionEvent(name: "sessionStatus", body: [
            "state": "idle",
            "message": message,
        ], requireActive: false)
    }

    func update(configuration: FeedbackConfiguration) {
        stateLock.lock()
        self.configuration = configuration
        stateLock.unlock()
    }

    func process(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        stateLock.lock()
        if sessionActive && demoTimer == nil { health.receivedFrame(at: ProcessInfo.processInfo.systemUptime) }
        stateLock.unlock()

        guard frameLock.try() else {
            stateLock.lock()
            droppedFrameCount += 1
            stateLock.unlock()
            return
        }
        defer { frameLock.unlock() }
        stateLock.lock()
        let isSessionActive = sessionActive && demoTimer == nil
        let currentConfiguration = configuration
        let processingGeneration = sessionGeneration
        stateLock.unlock()
        guard isSessionActive else { return }

        let frameStartTime = ProcessInfo.processInfo.systemUptime
        frameCount += 1
        let thermalState = ProcessInfo.processInfo.thermalState
        let thermallyLimited = thermalState == .serious || thermalState == .critical
        let usesResponsiveProcessing = currentConfiguration.processingMode == "responsive"
        let baseObjectInterval = thermallyLimited ? 0.22 : 0.11
        let objectInterval = throttle.interval(base: baseObjectInterval)
        let depthInterval = throttle.interval(
            base: thermallyLimited ? 0.5 : (usesResponsiveProcessing ? 0.35 : 0.18)
        )

        if frameStartTime - lastQualityCheck >= 0.65 {
            evaluateImageQuality(pixelBuffer: pixelBuffer)
            lastQualityCheck = frameStartTime
        }

        let shouldDetectObjects = objectModel != nil && frameStartTime - lastObjectInference >= objectInterval
        let shouldEstimateDepth = depthModel != nil && frameStartTime - lastDepthInference >= depthInterval
        // A due depth observation and detector observation use this same frame.
        // Never sample an older map using a newer bounding box.
        if shouldEstimateDepth {
            depthEvents = estimateDepthEvents(
                pixelBuffer: pixelBuffer,
                now: frameStartTime,
                configuration: currentConfiguration
            )
            lastDepthInference = frameStartTime
            depthInferenceCount += 1
        }
        if shouldDetectObjects {
            objectEvents = detectObjects(
                pixelBuffer: pixelBuffer,
                now: frameStartTime,
                configuration: currentConfiguration
            )
            lastObjectInference = frameStartTime
            objectInferenceCount += 1
        }
        if shouldDetectObjects || shouldEstimateDepth {
            let inferenceEndTime = ProcessInfo.processInfo.systemUptime
            throttle.record(
                inferenceSeconds: inferenceEndTime - frameStartTime,
                baseInterval: baseObjectInterval,
                at: inferenceEndTime
            )
            if throttle.isOverloaded(at: inferenceEndTime) {
                markTransientQuality(
                    "overloaded",
                    message: "Processing is behind. Hold the phone steady.",
                    duration: 1.5
                )
            }
        }

        stateLock.lock()
        let stalled = health.stalled
        let stillActive = sessionActive && sessionGeneration == processingGeneration
        stateLock.unlock()
        emitPipelineStatus()
        guard stillActive, !stalled else { return }

        let evaluationTime = ProcessInfo.processInfo.systemUptime
        let freshEvents = (objectEvents + depthEvents)
            .filter { evaluationTime - $0.timestamp < 0.7 }
        if let selected = prioritizer.select(
            from: freshEvents,
            configuration: currentConfiguration,
            now: evaluationTime
        ) {
            if prioritizer.shouldAnnounce(selected, now: evaluationTime) {
                feedback.deliver(selected, configuration: currentConfiguration)
            }
            if !hasVisibleEvent || evaluationTime - lastTopEventEmission >= 0.25 {
                emitSessionEvent(name: "topEvent", body: selected.dictionary)
                lastTopEventEmission = evaluationTime
            }
            hasVisibleEvent = true
        } else if !prioritizer.hasActiveEvent, hasVisibleEvent {
            emitSessionEvent(name: "eventCleared", body: [:], requireActive: false)
            hasVisibleEvent = false
        }

        latestProcessingLatencyMs = (ProcessInfo.processInfo.systemUptime - frameStartTime) * 1_000
        emitMetricsIfNeeded(now: frameStartTime)
    }

    func reportDroppedFrame(reason: String) {
        stateLock.lock()
        guard sessionActive && demoTimer == nil else { stateLock.unlock(); return }
        // The camera drops frames by design while a model is busy, so drops
        // only feed the metrics. AdaptiveThrottle decides when processing is behind.
        droppedFrameCount += 1
        stateLock.unlock()
    }

    func startDemo(scenario: String) {
        cancelModelPreparation()
        frameLock.lock()
        defer { frameLock.unlock() }
        cancelDemoTimer()
        stateLock.lock()
        sessionActive = true
        modelPreparationGeneration += 1
        sessionGeneration += 1
        depthPreviewGeneration += 1
        let currentConfiguration = configuration
        demoGeneration += 1
        let currentDemoGeneration = demoGeneration
        stateLock.unlock()
        resetSessionState()
        watchdog?.cancel()
        watchdog = nil
        feedback.stop()
        feedback.start()
        motionManager.stopDeviceMotionUpdates()
        emitQuality("good", message: "Safe demo running")
        emitSessionEvent(name: "sessionStatus", body: [
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
            let event = sequence[index % sequence.count].withTimestamp(ProcessInfo.processInfo.systemUptime)
            index += 1
            feedback.deliver(event, configuration: currentConfiguration)
            emitSessionEvent(name: "topEvent", body: event.dictionary)
            emitSessionEvent(name: "performanceMetrics", body: [
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
        stop(message: "Demo stopped")
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
            recordObjectInferenceFailure(String(describing: error))
            logger.error("YOLO26 detector inference failed: \(String(describing: error), privacy: .public)")
            if configuration.showBoundingBoxes {
                emitSessionEvent(name: "detectionsUpdated", body: [Any]())
            }
            return []
        }
        let modelOutputs = (request.results as? [VNCoreMLFeatureValueObservation] ?? [])
            .compactMap { $0.featureValue.multiArrayValue }
        guard !modelOutputs.isEmpty else {
            recordObjectInferenceFailure("Detector returned no detection array")
            if configuration.showBoundingBoxes {
                emitSessionEvent(name: "detectionsUpdated", body: [Any]())
            }
            return []
        }
        objectInferenceError = nil
        recordInference(detector: true, succeeded: true)
        let modelDetections = modelOutputs.flatMap { ModelOutput.detections(from: $0) }
        if configuration.showBoundingBoxes {
            let visibleDetections = modelDetections
            .filter { $0.confidence >= 0.25 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(20)
            emitSessionEvent(name: "detectionsUpdated", body: visibleDetections.compactMap { detection -> [String: Any]? in
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
        recordInference(detector: false, succeeded: true)
        latestDepthMap = depthMap
        latestDepthMapTime = now
        updateCloseCameraState(from: depthMap)
        let event = pathObstacleEvent(from: depthMap, now: now, configuration: configuration)
        if configuration.depthMapEnabled {
            stateLock.lock()
            let shouldQueue = !depthPreviewPending && now - lastDepthPreviewTime >= 1
            let generation = depthPreviewGeneration
            if shouldQueue { depthPreviewPending = true }
            stateLock.unlock()
            if shouldQueue {
                lastDepthPreviewTime = now
                depthMapQueue.async { [weak self] in
                    guard let self else { return }
                    let dataURL = depthMap.heatmapDataURL()
                    self.stateLock.lock()
                    let shouldEmit = self.sessionActive && self.depthPreviewGeneration == generation
                    self.depthPreviewPending = false
                    self.stateLock.unlock()
                    if shouldEmit, let dataURL {
                        self.emitSessionEvent(name: "depthMapUpdated", body: ["dataUrl": dataURL])
                    }
                }
            }
        }
        let groundEvent = groundHazardTracker.update(
            depthMap.groundHazard(
                within: min(configuration.warningDistanceMeters, GroundHazardTracker.warningRangeMeters)
            ),
            now: now,
            cameraStable: currentRotationRate() < 0.9
        )
        return [event, groundEvent].compactMap { $0 }
    }

    private func recordDepthInferenceFailure(_ message: String) {
        depthInferenceError = message
        latestDepthMap = nil
        latestDepthMapTime = 0
        recordInference(detector: false, succeeded: false)
    }

    private func recordObjectInferenceFailure(_ message: String) {
        objectInferenceError = message
        recordInference(detector: true, succeeded: false)
    }

    private func recordInference(detector: Bool, succeeded: Bool) {
        stateLock.lock()
        health.recordInference(detector: detector, succeeded: succeeded, at: ProcessInfo.processInfo.systemUptime)
        stateLock.unlock()
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
        } else if stable, pathObservationCount >= 3, observation.distanceMeters <= 1 {
            // Too slow to measure a closing speed, but the path is blocked within a step.
            risk = .caution
        } else {
            risk = .none
        }
        let confidence = min(0.6 + observation.coverage * 0.5, 0.95)
        return SpatialEvent(
            id: "depth:path",
            kind: .obstacle,
            direction: Direction.from(horizontalMidpoint: observation.box.midX),
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
            stateLock.lock()
            qualityState.cameraTooClose = true
            stateLock.unlock()
            emitEffectiveQuality()
        } else if cameraTooClose, clearDepthFrames >= 3 {
            cameraTooClose = false
            stateLock.lock()
            qualityState.cameraTooClose = false
            stateLock.unlock()
            emitEffectiveQuality()
        }
    }

    private func evaluateImageQuality(pixelBuffer: CVPixelBuffer) {
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
        if mean < 0.12 {
            quality = "low-light"
        } else if variance < 0.0025 {
            quality = "camera-covered"
        } else {
            quality = "good"
        }
        stateLock.lock()
        qualityState.imageQuality = quality
        stateLock.unlock()
        emitEffectiveQuality()
    }

    private func emitThermalQuality() {
        let state = ProcessInfo.processInfo.thermalState
        stateLock.lock()
        qualityState.thermalLimited = state == .serious || state == .critical
        let active = sessionActive
        stateLock.unlock()
        if active { emitEffectiveQuality() }
    }

    private func startMotionMonitoring() {
        guard motionManager.isDeviceMotionAvailable,
              !motionManager.isDeviceMotionActive else { return }
        stateLock.lock()
        let generation = sessionGeneration
        stateLock.unlock()
        motionManager.deviceMotionUpdateInterval = 0.1
        motionManager.startDeviceMotionUpdates(to: OperationQueue()) { [weak self] motion, _ in
            guard let self, let rate = motion?.rotationRate else { return }
            let magnitude = sqrt(rate.x * rate.x + rate.y * rate.y + rate.z * rate.z)
            stateLock.lock()
            guard sessionActive && sessionGeneration == generation else { stateLock.unlock(); return }
            latestRotationRate = magnitude
            stateLock.unlock()
            if magnitude > 3.2 {
                markTransientQuality(
                    "moving-too-fast",
                    message: "Phone is moving too quickly. Slow down.",
                    duration: 1.1,
                    generation: generation
                )
            }
        }
    }

    private func markTransientQuality(_ quality: String, message: String, duration: TimeInterval, generation: Int? = nil) {
        stateLock.lock()
        guard sessionActive && (generation == nil || generation == sessionGeneration) else { stateLock.unlock(); return }
        qualityState.transient[quality] = max(
            qualityState.transient[quality, default: 0],
            ProcessInfo.processInfo.systemUptime + duration
        )
        stateLock.unlock()
        emitEffectiveQuality()
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        let options = AVAudioSession.InterruptionOptions(rawValue:
            notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
        let available = type == .ended && options.contains(.shouldResume)
        stateLock.lock()
        let active = sessionActive
        let demo = demoTimer != nil
        health.audioInterrupted = !available
        stateLock.unlock()
        guard active else { return }
        feedback.setAudioAvailable(available)
        if demo {
            emitSessionEvent(name: "sessionStatus", body: [
                "state": available ? "running" : "degraded",
                "code": "audio-interrupted",
                "severity": available ? "info" : "warning",
                "message": available ? "Demo audio restored" : "Demo audio interrupted. Haptic cues remain active.",
            ])
        } else { emitPipelineStatus() }
    }

    private func emitQuality(_ quality: String, message: String) {
        stateLock.lock()
        guard sessionActive, quality != lastQuality else {
            stateLock.unlock()
            return
        }
        lastQuality = quality
        let currentConfiguration = configuration
        stateLock.unlock()
        emitSessionEvent(name: "qualityChanged", body: ["quality": quality, "message": message])
        if quality != "good" {
            feedback.speakWarning(message, configuration: currentConfiguration)
        }
    }

    private func emitEffectiveQuality() {
        stateLock.lock()
        let effective = qualityState.effective(at: ProcessInfo.processInfo.systemUptime)
        stateLock.unlock()
        emitQuality(effective.quality, message: effective.message)
    }

    private func emitSessionEvent(name: String, body: Any, requireActive: Bool = true) {
        stateLock.lock()
        let generation = sessionGeneration
        stateLock.unlock()
        ClearAheadModule.emit(name: name, body: body, isCurrent: { [weak self] in
            guard let self else { return false }
            stateLock.lock()
            defer { stateLock.unlock() }
            return (!requireActive || sessionActive) && sessionGeneration == generation
                && (name != "topEvent" || !health.stalled)
        })
    }

    private func emitPipelineStatus() {
        stateLock.lock()
        guard sessionActive else { stateLock.unlock(); return }
        let status = health.status(detectorLoaded: objectModel != nil, depthLoaded: depthModel != nil)
        guard status != lastPipelineStatus else { stateLock.unlock(); return }
        lastPipelineStatus = status
        let diagnostics = modelDiagnostics()
        stateLock.unlock()
        emitSessionEvent(name: "sessionStatus", body: [
            "state": status.state, "code": status.code,
            "message": status.message, "severity": status.severity,
            "diagnostics": diagnostics,
        ])
    }

    private func startWatchdog() {
        precondition(Thread.isMainThread)
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            stateLock.lock()
            guard sessionActive else { stateLock.unlock(); return }
            let wasStalled = health.stalled
            let stalled = health.checkStall(at: ProcessInfo.processInfo.systemUptime)
            let audioAvailable = !health.audioInterrupted
            stateLock.unlock()
            if stalled && !wasStalled {
                feedback.stop()
                emitSessionEvent(name: "eventCleared", body: [:])
                emitSessionEvent(name: "detectionsUpdated", body: [Any]())
                emitSessionEvent(name: "depthMapUpdated", body: ["dataUrl": NSNull()])
                if frameLock.try() {
                    objectEvents = []
                    depthEvents = []
                    latestDepthMap = nil
                    previousPathObstacle = nil
                    pathObservationCount = 0
                    pathClosingSpeed = 0
                    prioritizer.reset()
                    collisionTracker.reset()
                    groundHazardTracker.reset()
                    hasVisibleEvent = false
                    frameLock.unlock()
                }
            } else if wasStalled && !stalled {
                feedback.start(audioAvailable: audioAvailable)
                if frameLock.try() {
                    prioritizer.reset()
                    collisionTracker.reset()
                    hasVisibleEvent = false
                    frameLock.unlock()
                }
            }
            emitPipelineStatus()
            emitEffectiveQuality()
        }
        watchdog = timer
        timer.resume()
    }

    private func emitMetricsIfNeeded(now: TimeInterval) {
        guard now - lastMetricsEmission >= 1 else { return }
        let duration = max(now - metricWindowStart, 0.001)
        stateLock.lock()
        let droppedFrames = droppedFrameCount
        droppedFrameCount = 0
        stateLock.unlock()
        emitSessionEvent(name: "performanceMetrics", body: [
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

    private func modelDiagnostics() -> [String: Any] {
        [
            "objectModel": objectModelResult.dictionary,
            "depthModel": depthModelResult.dictionary,
        ]
    }

    private func loadModel(at assetURL: URL, isDepth: Bool = false) -> ModelLoadResult {
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
                let cacheKey = try ModelManager.contentIdentity(at: assetURL)
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
            let description = model.modelDescription
            let validInput = description.inputDescriptionsByName.values.contains {
                $0.imageConstraint?.pixelsWide == 640 && $0.imageConstraint?.pixelsHigh == 640
            }
            let validOutput = description.outputDescriptionsByName.values.contains {
                guard let shape = $0.multiArrayConstraint?.shape.map(\.intValue), shape.count >= 2 else { return false }
                return isDepth ? shape.suffix(2).allSatisfy { $0 > 16 } : shape.last == 6
            }
            guard validInput && validOutput else {
                throw NSError(domain: "ClearAheadModels", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Model schema incompatible: expected 640x640 image input and \(isDepth ? "dense depth map" : "six-column detections").",
                ])
            }
            return ModelLoadResult(
                model: try VNCoreMLModel(for: model),
                resource: assetURL.lastPathComponent,
                error: nil,
                compiledURL: modelURL
            )
        } catch {
            logger.error("Unable to load model at \(assetURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return ModelLoadResult(model: nil, resource: assetURL.lastPathComponent, error: String(describing: error))
        }
    }

    private func trimCompiledCache() {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: false) else { return }
        let root = support.appendingPathComponent("ClearAheadCompiledModels", isDirectory: true)
        stateLock.lock()
        let active = Set([objectModelResult.compiledURL, depthModelResult.compiledURL].compactMap { $0?.path })
        stateLock.unlock()
        let candidates = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let inactive = candidates.filter { $0.pathExtension == "mlmodelc" && !active.contains($0.path) }.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        for url in inactive.dropFirst(2) { try? FileManager.default.removeItem(at: url) }
    }

    private func eventKind(forCOCOClass identifier: Int) -> EventKind? {
        switch identifier {
        case 0: return .person
        case 1, 2, 3, 5, 6, 7: return .vehicle
        case 13, 56, 57, 59, 60, 61: return .furniture
        // Low things that sit on the ground and trip people: hydrant, cat, dog,
        // backpack, handbag, suitcase, sports ball, skateboard, potted plant.
        case 10, 15, 16, 24, 26, 28, 32, 36, 58: return .obstacle
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
        guard abs(now - latestDepthMapTime) < 0.001,
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
