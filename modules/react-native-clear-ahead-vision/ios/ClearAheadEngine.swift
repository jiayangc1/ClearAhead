import AVFoundation
import CoreML
import CoreMotion
import CryptoKit
import Foundation
import OSLog
import UIKit
import Vision
import simd

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
    private let depthMapQueue = DispatchQueue(label: "com.clearahead.depth-preview", qos: .default)
    private var depthPreviewGeneration = 0
    private var depthPreviewPending = false
    private var lastDepthPreviewTime: TimeInterval = 0
    private var sessionGeneration = 0
    private var lidarCapture: LidarCapture?
    private var lidarGeneration = 0
    private var depthUsesLidar = false
    private var distanceStatus = "metric-estimate"
    private var watchdog: DispatchSourceTimer?
    private var health = SessionHealth(startedAt: 0)
    private var qualityState = SessionQualityState()
    private var lastPipelineStatus: PipelineStatus?
    private let prioritizer = EventPrioritizer()
    private let speechGate = SpeechGate()
    private var hazardMemory = HazardMemory()
    private let feedback = Feedback()
    private let collisionTracker = CollisionTracker()
    private let sceneSelector = SceneSelector()
    private var groundNormalizer = GroundNormalizer()
    private var cameraGeometry: CameraGeometry?
    private var latestGravity: SIMD3<Double>?
    private var latestCameraAttitude: simd_quatd?
    private var latestMotionTime: TimeInterval = 0
    private var walkingEffort = 0.0
    private var frameGravity: SIMD3<Double>?
    private var frameAttitude: simd_quatd?
    private var groundHazardTracker = GroundHazardTracker()
    private var throttle = AdaptiveThrottle()
    private let motionManager = CMMotionManager()
    private var configuration = FeedbackConfiguration()
    private var sessionActive = false

    private let logger = Logger(subsystem: "com.clearahead.vision", category: "inference")
    private var objectModelResult = ModelLoadResult(model: nil, resource: nil, error: "Model not prepared")
    private var depthModelResult = ModelLoadResult(model: nil, resource: nil, error: "Model not prepared")
    private var preparedModelKey: String?
    private var modelPreparationGeneration = 0
    private var modelPreparationRequest: ModelDownloadRequest?
    private var objectModel: VNCoreMLModel? { objectModelResult.model }
    private var depthModel: VNCoreMLModel? { depthModelResult.model }
    private var objectRequest: VNCoreMLRequest?
    private var depthRequest: VNCoreMLRequest?
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
    private var pathTrackStart: TimeInterval = 0
    private var latestRotationRate = 0.0
    private var lastObjectInference: TimeInterval = 0
    private var lastDepthInference: TimeInterval = 0
    private var lastDetectionEmission: TimeInterval = 0
    private var averageObjectDuration: TimeInterval = 0
    private var averageDepthDuration: TimeInterval = 0
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
    private var closeDepthSince: TimeInterval = 0
    private var clearDepthSince: TimeInterval = 0
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
                let detectorBytes = ModelManager.packageBytes(pair.detector)
                let totalBytes = detectorBytes + (pair.depth.map(ModelManager.packageBytes) ?? 0)
                let detector = self.loadModel(at: pair.detector)
                if detector.error == nil {
                    ClearAheadModule.emit(name: "modelDownloadProgress", body: [
                        "modelVariant": configuration.modelVariant,
                        "progress": 0.95 * Double(detectorBytes) / Double(max(totalBytes, 1)),
                        "message": "Detector loaded; loading depth…",
                    ], isCurrent: {
                        self.stateLock.lock()
                        defer { self.stateLock.unlock() }
                        return self.modelPreparationGeneration == preparationGeneration
                    })
                }
                let depth = pair.depth.map { self.loadModel(at: $0, isDepth: true) }
                    ?? ModelLoadResult(model: nil, resource: nil, error: "Depth model unavailable")
                if let error = detector.error ?? (allowDetectorOnly ? nil : depth.error) {
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
                        self.objectRequest = detector.model.map { VNCoreMLRequest(model: $0) }
                        self.depthRequest = depth.model.map { VNCoreMLRequest(model: $0) }
                        self.objectRequest?.imageCropAndScaleOption = .scaleFill
                        self.depthRequest?.imageCropAndScaleOption = .scaleFill
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
        speechGate.reset()
        hazardMemory.reset()
        collisionTracker.reset()
        sceneSelector.reset()
        groundNormalizer = GroundNormalizer()
        groundHazardTracker.reset()
        throttle = AdaptiveThrottle()
        objectEvents = []
        depthEvents = []
        latestDepthMap = nil
        latestDepthMapTime = 0
        depthUsesLidar = false
        distanceStatus = "metric-estimate"
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
        walkingEffort = 0
        latestGravity = nil
        latestCameraAttitude = nil
        lastPipelineStatus = nil
        lastQuality = ""
        stateLock.unlock()
        lastObjectInference = 0
        lastDepthInference = 0
        lastDetectionEmission = 0
        averageObjectDuration = 0
        averageDepthDuration = 0
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
        lidarGeneration += 1
        lidarCapture = nil
        modelPreparationGeneration += 1
        sessionGeneration += 1
        depthPreviewGeneration += 1
        stateLock.unlock()
        watchdog?.cancel()
        watchdog = nil
        feedback.stop()
        motionManager.stopDeviceMotionUpdates()
        // In-flight Core ML work cannot be cancelled. Invalidate it immediately
        // rather than blocking main while waiting for inference to finish.
        if frameLock.try() {
            prioritizer.reset()
            speechGate.reset()
            hazardMemory.reset()
            collisionTracker.reset()
            groundHazardTracker.reset()
            objectEvents = []
            depthEvents = []
            latestDepthMap = nil
            hasVisibleEvent = false
            frameLock.unlock()
        }
        emitSessionEvent(name: "sceneUpdated", body: ["state": "unavailable", "sources": [Any](),
                                                   "distanceStatus": "unavailable", "spatialCapability": "unavailable"], requireActive: false)
        emitSessionEvent(name: "eventCleared", body: [:], requireActive: false)
        emitSessionEvent(name: "sessionStatus", body: [
            "state": "idle",
            "message": message,
        ], requireActive: false)
    }

    func update(configuration: FeedbackConfiguration) {
        stateLock.lock()
        if self.configuration.depthMapEnabled != configuration.depthMapEnabled {
            depthPreviewGeneration += 1
        }
        self.configuration = configuration
        stateLock.unlock()
    }

    func connectDepthOutputs(video: AVCaptureVideoDataOutput, depth: AVCaptureDepthDataOutput) {
        stateLock.lock()
        lidarGeneration += 1
        let token = lidarGeneration
        lidarCapture = LidarCapture(video: video, depth: depth) { [weak self] color, measurement in
            self?.process(sampleBuffer: color, lidarDepth: measurement, lidarToken: token)
        }
        stateLock.unlock()
    }

    func process(sampleBuffer: CMSampleBuffer, lidarDepth: AVDepthData? = nil, lidarToken: Int? = nil) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        stateLock.lock()
        if sessionActive { health.receivedFrame(at: ProcessInfo.processInfo.systemUptime) }
        stateLock.unlock()

        guard frameLock.try() else {
            stateLock.lock()
            droppedFrameCount += 1
            stateLock.unlock()
            return
        }
        defer { frameLock.unlock() }
        stateLock.lock()
        let isSessionActive = sessionActive && (lidarToken == nil || lidarToken == lidarGeneration)
        let currentConfiguration = configuration
        let processingGeneration = sessionGeneration
        stateLock.unlock()
        guard isSessionActive else { return }

        cameraGeometry = Self.geometry(sampleBuffer: sampleBuffer, pixelBuffer: pixelBuffer)

        let frameStartTime = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        frameGravity = frameStartTime - latestMotionTime < 0.4 ? latestGravity : nil
        frameAttitude = frameStartTime - latestMotionTime < 0.4 ? latestCameraAttitude : nil
        stateLock.unlock()
        frameCount += 1
        let thermalState = ProcessInfo.processInfo.thermalState
        let thermallyLimited = thermalState == .serious || thermalState == .critical
        let usesResponsiveProcessing = currentConfiguration.processingMode == "responsive"
        // Leave processing headroom instead of immediately starting another costly pair.
        // Model inputs and all safety checks retain their full resolution.
        let baseObjectInterval = thermallyLimited ? 0.22 : 0.11
        let objectInterval = max(throttle.interval(base: baseObjectInterval), min(averageObjectDuration * 1.15, 0.35))
        // Bases sit just under a whole number of 30 fps camera frames. They are
        // only a ceiling on the rate: AdaptiveThrottle stretches them to what
        // the device sustains.
        let depthInterval = max(
            throttle.interval(base: thermallyLimited ? 0.5 : (usesResponsiveProcessing ? 0.12 : 0.09)),
            min((averageObjectDuration + averageDepthDuration) * 1.2, 0.5)
        )

        if frameStartTime - lastQualityCheck >= 0.65 {
            evaluateImageQuality(pixelBuffer: pixelBuffer)
            lastQualityCheck = frameStartTime
        }

        let shouldEstimateDepth = (depthModel != nil || currentConfiguration.lidarEnabled && lidarToken != nil)
            && frameStartTime - lastDepthInference >= depthInterval
        let shouldDetectObjects = objectModel != nil
            && (shouldEstimateDepth || frameStartTime - lastObjectInference >= objectInterval)
        guard shouldEstimateDepth || shouldDetectObjects else {
            emitMetricsIfNeeded(now: frameStartTime)
            return
        }
        // Both models read this frame through one handler so Vision can reuse
        // its converted image instead of preparing the frame twice.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        // A due depth observation and detector observation use this same frame.
        // Never sample an older map using a newer bounding box.
        if shouldEstimateDepth {
            let started = ProcessInfo.processInfo.systemUptime
            depthEvents = estimateDepthEvents(
                handler: handler,
                pixelBuffer: pixelBuffer,
                lidarDepth: currentConfiguration.lidarEnabled ? lidarDepth : nil,
                now: frameStartTime,
                configuration: currentConfiguration
            )
            lastDepthInference = frameStartTime
            averageDepthDuration += ((ProcessInfo.processInfo.systemUptime - started) - averageDepthDuration) * 0.2
            depthInferenceCount += 1
        }
        // Stop can invalidate a session while depth inference is running.
        stateLock.lock()
        let mayContinue = sessionActive && sessionGeneration == processingGeneration
        stateLock.unlock()
        guard mayContinue else { return }
        if shouldDetectObjects {
            let started = ProcessInfo.processInfo.systemUptime
            objectEvents = detectObjects(
                handler: handler,
                now: frameStartTime,
                configuration: currentConfiguration
            )
            lastObjectInference = frameStartTime
            averageObjectDuration += ((ProcessInfo.processInfo.systemUptime - started) - averageObjectDuration) * 0.2
            objectInferenceCount += 1
        }
        if shouldDetectObjects || shouldEstimateDepth {
            let inferenceEndTime = ProcessInfo.processInfo.systemUptime
            throttle.record(inferenceSeconds: inferenceEndTime - frameStartTime, at: inferenceEndTime)
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

        // Build geometry and semantic masks only from the matched depth/detector frame.
        guard shouldEstimateDepth || latestDepthMap == nil else {
            emitMetricsIfNeeded(now: frameStartTime)
            return
        }
        let evaluationTime = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        let gravity = frameGravity
        let attitude = frameAttitude
        let walking = walkingEffort > 0.06 && evaluationTime - latestMotionTime < 0.4
        let imageUsable = depthUsesLidar
            ? qualityState.imageQuality != "camera-covered"
            : qualityState.imageQuality == "good" && !cameraTooClose
        stateLock.unlock()
        var available = latestDepthMap != nil && evaluationTime - latestDepthMapTime < 0.65 && imageUsable
        var sources: [SceneSource]
        if available, let map = latestDepthMap {
            sources = sceneSelector.select(SceneBuilder.build(
                map: map, objects: objectEvents.filter { abs($0.timestamp - latestDepthMapTime) < 0.001 },
                hazards: depthEvents, geometry: cameraGeometry, gravity: gravity, ground: groundNormalizer,
                configuration: currentConfiguration, now: evaluationTime
            ), now: evaluationTime, range: currentConfiguration.warningDistanceMeters)
            if sources.isEmpty, map.values.contains(where: { $0.isFinite && $0 <= currentConfiguration.warningDistanceMeters }),
               groundNormalizer.plane == nil { available = false }
            // An empty partial sensor map cannot establish that the view is clear.
            if sources.isEmpty, !map.hasUsableCoverage { available = false }
        } else {
            sceneSelector.reset()
            sources = []
        }
        // Something low that just left the bottom of the view is still ahead.
        // It keeps its place among the sources until it has been stepped past.
        let remembered = hazardMemory.update(
            events: objectEvents.filter { abs($0.timestamp - latestDepthMapTime) < 0.001 } + depthEvents,
            now: evaluationTime, walking: walking, heading: Self.heading(attitude),
            cameraHeight: currentConfiguration.cameraHeightMeters
        )
        // A confirmed ground hazard is reported even when the floor around it
        // swallowed its depth region and no source came to carry it.
        let unmatched = depthEvents.filter { hazard in
            hazard.label == GroundHazardTracker.label && hazard.collisionRisk != .none
                && !sources.contains { $0.event.label == hazard.label && $0.event.collisionRisk != .none }
        }
        let added = (remembered + unmatched).map {
            SceneSource.onGround($0, cameraHeight: currentConfiguration.cameraHeightMeters)
        }
        if !added.isEmpty {
            sources = Array((added + sources).prefix(SceneSelector.maximumSources))
            available = true
        }
        feedback.updateScene(sources, configuration: currentConfiguration, camera: attitude,
                             earCalibrated: currentConfiguration.earHeightMeters >= 0.4
                                && currentConfiguration.cameraHeightMeters >= 0.4 && groundNormalizer.plane != nil)
        emitSessionEvent(name: "sceneUpdated", body: [
            "state": available ? (sources.isEmpty ? "clear" : "available") : "unavailable",
            "sources": sources.map(\.dictionary),
            "distanceStatus": distanceStatus,
            "spatialCapability": feedback.spatialCapability,
            "imageAspectRatio": Double(CVPixelBufferGetHeight(pixelBuffer)) / Double(CVPixelBufferGetWidth(pixelBuffer)),
        ])
        let freshEvents = sources.map(\.event)
        let speakable = sources.filter(\.isSpeakable).map(\.event)
        if let utterance = speechGate.next(from: speakable, configuration: currentConfiguration, now: evaluationTime) {
            feedback.speak(utterance, configuration: currentConfiguration)
        }
        if let selected = prioritizer.select(
            from: freshEvents,
            configuration: currentConfiguration,
            now: evaluationTime
        ) {
            if !hasVisibleEvent || evaluationTime - lastTopEventEmission >= 0.25 {
                emitSessionEvent(name: "topEvent", body: selected.dictionary)
                lastTopEventEmission = evaluationTime
            }
            hasVisibleEvent = true
        } else {
            if !prioritizer.hasActiveEvent, hasVisibleEvent {
                emitSessionEvent(name: "eventCleared", body: [:], requireActive: false)
                hasVisibleEvent = false
            }
        }

        latestProcessingLatencyMs = (ProcessInfo.processInfo.systemUptime - frameStartTime) * 1_000
        emitMetricsIfNeeded(now: frameStartTime)
    }

    func reportDroppedFrame(reason: String) {
        stateLock.lock()
        guard sessionActive else { stateLock.unlock(); return }
        // The camera drops frames by design while a model is busy, so drops
        // only feed the metrics. AdaptiveThrottle decides when processing is behind.
        droppedFrameCount += 1
        stateLock.unlock()
    }

    private func detectObjects(
        handler: VNImageRequestHandler,
        now: TimeInterval,
        configuration: FeedbackConfiguration
    ) -> [SpatialEvent] {
        guard let request = objectRequest else { return [] }
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
        let detections = modelDetections.compactMap { detection -> ObjectDetection? in
            guard detection.confidence >= 0.25,
                  let label = cocoLabel(for: detection.classIdentifier),
                  let kind = detection.kind else { return nil }
            return ObjectDetection(
                kind: kind,
                label: label,
                box: detection.box,
                depth: recentDepthMeasurement(inVisionBox: detection.box, now: now),
                confidence: detection.confidence
            )
        }
        let events = collisionTracker.update(
            detections: detections,
            now: now,
            configuration: configuration,
            rotationRate: currentRotationRate()
        )
        if configuration.showBoundingBoxes, now - lastDetectionEmission >= 0.2 {
            emitDetections(modelDetections, events: events, configuration: configuration)
            lastDetectionEmission = now
        }
        return events
    }

    private func emitDetections(_ detections: [YOLODetection], events: [SpatialEvent], configuration: FeedbackConfiguration) {
        let visible: [YOLODetection]
        if configuration.boundingBoxVerbosity == "less" {
            // These events already passed tracking and collision constraints.
            emitSessionEvent(name: "detectionsUpdated", body: events.filter {
                $0.collisionRisk != .none && $0.confidence >= 0.6
            }.prefix(4).compactMap { event -> [String: Any]? in
                guard let box = event.box else { return nil }
                return ["label": event.label ?? event.kind.rawValue, "confidence": event.confidence,
                        "box": ["x": box.minX, "y": 1 - box.maxY, "width": box.width, "height": box.height]]
            })
            return
        }
        visible = Array(detections.filter { $0.shouldDisplay(verbosity: configuration.boundingBoxVerbosity) }
            .sorted { $0.confidence > $1.confidence }.prefix(configuration.boundingBoxVerbosity == "verbose" ? 20 : 8))
        emitSessionEvent(name: "detectionsUpdated", body: visible.compactMap { detection -> [String: Any]? in
            guard let label = cocoLabel(for: detection.classIdentifier) else { return nil }
            return ["label": label, "confidence": detection.confidence,
                    "box": ["x": detection.box.minX, "y": 1 - detection.box.maxY,
                            "width": detection.box.width, "height": detection.box.height]]
        })
    }

    private func estimateDepthEvents(
        handler: VNImageRequestHandler,
        pixelBuffer: CVPixelBuffer,
        lidarDepth: AVDepthData?,
        now: TimeInterval,
        configuration: FeedbackConfiguration
    ) -> [SpatialEvent] {
        let modelMap = estimateModelDepthMap(handler: handler)
        let lidarMap = lidarDepth.flatMap { DepthMap(lidar: $0) }
        guard let rawMap = modelMap ?? lidarMap else {
            latestDepthMap = nil
            latestDepthMapTime = 0
            depthUsesLidar = false
            distanceStatus = "unavailable"
            previousPathObstacle = nil
            pathObservationCount = 0
            pathClosingSpeed = 0
            recordInference(detector: false, succeeded: false)
            emitSessionEvent(name: "depthMapUpdated", body: ["dataUrl": NSNull()])
            return []
        }
        recordInference(detector: false, succeeded: true)
        groundNormalizer.update(map: rawMap, geometry: cameraGeometry, gravity: frameGravity,
                                cameraHeight: configuration.cameraHeightMeters, stable: currentRotationRate() < 0.9,
                                metric: modelMap == nil)
        let scale = groundNormalizer.scale
        let calibrated = scale == 1 ? rawMap
            : DepthMap(width: rawMap.width, height: rawMap.height, values: rawMap.values.map { $0 * scale })
        let depthMap = modelMap != nil ? calibrated.mergingCloseDepth(lidarMap) : calibrated
        depthUsesLidar = modelMap == nil || lidarMap?.values.contains { $0.isFinite && $0 <= 2 } == true
        distanceStatus = modelMap == nil ? "lidar-measured" : groundNormalizer.status
        if modelMap == nil, !rawMap.hasUsableCoverage { distanceStatus += "-partial-view" }
        if modelMap != nil, depthUsesLidar { distanceStatus += "; lidar-close-measured" }
        latestDepthMap = depthMap
        latestDepthMapTime = now
        updateCloseCameraState(from: depthMap, now: now)
        let event = pathObstacleEvent(from: depthMap, now: now, configuration: configuration)
        if configuration.depthMapEnabled {
            stateLock.lock()
            let shouldQueue = sessionActive && self.configuration.depthMapEnabled
                && !depthPreviewPending && now - lastDepthPreviewTime >= 0.09
            let generation = depthPreviewGeneration
            if shouldQueue { depthPreviewPending = true }
            stateLock.unlock()
            if shouldQueue {
                lastDepthPreviewTime = now
                let status = distanceStatus
                let imageAspect = Double(CVPixelBufferGetHeight(pixelBuffer)) / Double(CVPixelBufferGetWidth(pixelBuffer))
                depthMapQueue.async { [weak self] in
                    guard let self else { return }
                    self.stateLock.lock()
                    let shouldRender = self.sessionActive && self.configuration.depthMapEnabled
                        && self.depthPreviewGeneration == generation
                    self.stateLock.unlock()
                    let dataURL = shouldRender
                        ? depthMap.heatmapDataURL(farDistance: configuration.warningDistanceMeters, imageAspect: imageAspect) : nil
                    self.stateLock.lock()
                    let shouldEmit = self.sessionActive && self.configuration.depthMapEnabled
                        && self.depthPreviewGeneration == generation
                    self.depthPreviewPending = false
                    self.stateLock.unlock()
                    if shouldEmit, let dataURL {
                        self.emitSessionEvent(name: "depthMapUpdated", body: ["dataUrl": dataURL,
                            "nearMeters": 0.25, "farMeters": configuration.warningDistanceMeters,
                            "distanceStatus": status])
                    }
                }
            }
        }
        let groundEvent = groundHazardTracker.update(
            depthMap.groundHazard(
                within: min(configuration.warningDistanceMeters, GroundHazardTracker.detectionRangeMeters)
            ),
            now: now,
            cameraStable: currentRotationRate() < 0.9
        )
        return [event, groundEvent].compactMap { $0 }
    }

    private func estimateModelDepthMap(handler: VNImageRequestHandler) -> DepthMap? {
        guard let request = depthRequest else { return nil }
        do {
            try handler.perform([request])
        } catch {
            recordDepthInferenceFailure(String(describing: error))
            logger.error("YOLO26 depth inference failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard let depthOutput = (request.results as? [VNCoreMLFeatureValueObservation])?.first(where: {
            $0.featureValue.multiArrayValue != nil
        }), let depthValues = depthOutput.featureValue.multiArrayValue else {
            recordDepthInferenceFailure("Depth model returned no depth array")
            return nil
        }
        guard let rawMap = DepthMap(array: depthValues), rawMap.hasUsableCoverage else {
            recordDepthInferenceFailure("Depth model returned an invalid depth array")
            return nil
        }
        depthInferenceError = nil
        return rawMap
    }

    private func recordDepthInferenceFailure(_ message: String) {
        depthInferenceError = message
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
            // Smooth over elapsed time rather than per frame, so a faster depth
            // rate does not turn depth noise into closing speed.
            pathClosingSpeed += (observedSpeed - pathClosingSpeed) * min(0.4, 1 - exp(-elapsed / 0.5))
            pathObservationCount += 1
        } else {
            pathClosingSpeed = 0
            pathObservationCount = 1
            pathTrackStart = now
        }
        previousPathObstacle = observation
        previousPathTime = now
        // Frames count as evidence only as fast as time passes; three frames
        // can now arrive in a fraction of a second.
        let evidence = min(pathObservationCount, 1 + Int((now - pathTrackStart) / 0.25))
        let approachSpeed = stable && evidence >= 2 ? max(0, pathClosingSpeed) : 0
        let timeToCollision = approachSpeed > 0.2 ? observation.distanceMeters / approachSpeed : nil
        let risk = observation.collisionRisk(observations: evidence,
                                             closingSpeed: approachSpeed, stable: stable)
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
            trajectoryConfidence: confidence * min(Double(evidence) / 3, 1),
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

    private func updateCloseCameraState(from depthMap: DepthMap, now: TimeInterval) {
        let centerSamples = depthMap.samples(in: CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84), step: 4)
        guard centerSamples.count > 20 else { return }
        let closeRangeCoverage = Double(centerSamples.reduce(0) { $0 + ($1 <= 0.35 ? 1 : 0) }) / Double(centerSamples.count)
        if closeRangeCoverage >= 0.45 {
            if closeDepthFrames == 0 { closeDepthSince = now }
            closeDepthFrames += 1
            clearDepthFrames = 0
        } else if closeRangeCoverage < 0.25 {
            if clearDepthFrames == 0 { clearDepthSince = now }
            clearDepthFrames += 1
            closeDepthFrames = 0
        }
        if !cameraTooClose, closeDepthFrames >= 3, now - closeDepthSince >= 0.4 {
            cameraTooClose = true
            stateLock.lock()
            qualityState.cameraTooClose = true
            stateLock.unlock()
            emitEffectiveQuality()
        } else if cameraTooClose, clearDepthFrames >= 3, now - clearDepthSince >= 0.4 {
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
            guard let self, let motion else { return }
            let rate = motion.rotationRate
            let magnitude = sqrt(rate.x * rate.x + rate.y * rate.y + rate.z * rate.z)
            stateLock.lock()
            guard sessionActive && sessionGeneration == generation else { stateLock.unlock(); return }
            latestRotationRate = magnitude
            // Arm swing and footfalls shake the phone; standing still does not.
            let push = motion.userAcceleration
            walkingEffort += (sqrt(push.x * push.x + push.y * push.y + push.z * push.z) - walkingEffort) * 0.2
            latestGravity = SIMD3(motion.gravity.x, motion.gravity.y, motion.gravity.z)
            latestCameraAttitude = SpatialAudio.attitude(motion.attitude)
            latestMotionTime = ProcessInfo.processInfo.systemUptime
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
        health.audioInterrupted = !available
        stateLock.unlock()
        guard active else { return }
        feedback.setAudioAvailable(available)
        emitPipelineStatus()
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
        let needsFreshScene = name == "sceneUpdated" && ((body as? [String: Any])?["state"] as? String) != "unavailable"
        ClearAheadModule.emit(name: name, body: body, isCurrent: { [weak self] in
            guard let self else { return false }
            stateLock.lock()
            defer { stateLock.unlock() }
            return (!requireActive || sessionActive) && sessionGeneration == generation
                && ((name != "topEvent" && !needsFreshScene) || !health.stalled)
        })
    }

    private func emitPipelineStatus() {
        stateLock.lock()
        guard sessionActive else { stateLock.unlock(); return }
        let status = health.status(detectorLoaded: objectModel != nil,
                                   depthLoaded: depthModel != nil || configuration.lidarEnabled && lidarCapture != nil)
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
                emitSessionEvent(name: "sceneUpdated", body: ["state": "unavailable", "sources": [Any](),
                                                           "distanceStatus": "unavailable", "spatialCapability": "unavailable"])
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
                    speechGate.reset()
                    hazardMemory.reset()
                    collisionTracker.reset()
                    groundHazardTracker.reset()
                    hasVisibleEvent = false
                    frameLock.unlock()
                }
            } else if wasStalled && !stalled {
                feedback.start(audioAvailable: audioAvailable)
                if frameLock.try() {
                    prioritizer.reset()
                    speechGate.reset()
                    hazardMemory.reset()
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

    private static let cocoLabels = [
            "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat", "traffic light",
            "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow",
            "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella", "handbag", "tie", "suitcase", "frisbee",
            "skis", "snowboard", "sports ball", "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket", "bottle",
            "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple", "sandwich", "orange",
            "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair", "couch", "potted plant", "bed",
            "dining table", "toilet", "tv", "laptop", "mouse", "remote", "keyboard", "cell phone", "microwave", "oven",
            "toaster", "sink", "refrigerator", "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush",
    ]

    private func cocoLabel(for identifier: Int) -> String? {
        Self.cocoLabels.indices.contains(identifier) ? Self.cocoLabels[identifier] : nil
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

    private static func geometry(sampleBuffer: CMSampleBuffer, pixelBuffer: CVPixelBuffer) -> CameraGeometry? {
        guard let data = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                         attachmentModeOut: nil) as? Data,
              data.count >= MemoryLayout<simd_float3x3>.size else { return nil }
        let matrix = data.withUnsafeBytes { $0.loadUnaligned(as: simd_float3x3.self) }
        let width = Double(CVPixelBufferGetWidth(pixelBuffer))
        let height = Double(CVPixelBufferGetHeight(pixelBuffer))
        // Vision rotates the landscape buffer clockwise into the portrait depth/box coordinate system.
        let geometry = CameraGeometry(fx: Double(matrix[1][1]) / height, fy: Double(matrix[0][0]) / width,
                                      cx: 1 - Double(matrix[2][1]) / height, cy: Double(matrix[2][0]) / width)
        return geometry.valid ? geometry : nil
    }

    /// Compass-free direction the camera faces, flattened to the ground plane.
    /// Nil while the phone points nearly straight up or down.
    private static func heading(_ attitude: simd_quatd?) -> SIMD2<Double>? {
        guard let attitude else { return nil }
        let forward = attitude.act(SIMD3<Double>(0, 0, -1))
        let level = SIMD2(forward.x, forward.y)
        return simd_length(level) > 0.3 ? simd_normalize(level) : nil
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

}
