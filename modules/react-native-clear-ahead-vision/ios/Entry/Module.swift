import Foundation
import React

@objc(ClearAheadModule)
final class ClearAheadModule: RCTEventEmitter {
    private static weak var currentEmitter: ClearAheadModule?
    private var hasListeners = false
    private let requestLock = NSLock()
    private var sessionGeneration = 0

    override init() {
        super.init()
        Self.currentEmitter = self
    }

    override static func requiresMainQueueSetup() -> Bool { true }
    override var methodQueue: DispatchQueue! { DispatchQueue.main }

    override func supportedEvents() -> [String]! {
        ["sessionStatus", "topEvent", "eventCleared", "qualityChanged", "performanceMetrics", "detectionsUpdated", "depthMapUpdated", "modelDownloadProgress", "sceneUpdated"]
    }

    override func startObserving() { hasListeners = true }
    override func stopObserving() { hasListeners = false }

    static func emit(name: String, body: Any, isCurrent: (() -> Bool)? = nil) {
        DispatchQueue.main.async {
            guard isCurrent?() ?? true else { return }
            guard let emitter = currentEmitter, emitter.hasListeners else { return }
            emitter.sendEvent(withName: name, body: body)
        }
    }

    @objc(startSession:resolver:rejecter:)
    func startSession(
        _ configuration: NSDictionary,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        let parsed = FeedbackConfiguration(dictionary: configuration as? [String: Any] ?? [:])
        guard parsed.hapticsEnabled || parsed.audioEnabled || parsed.speechEnabled else {
            reject("feedback_disabled", "Turn on haptics, audio, or speech before starting Assist Mode.", nil)
            return
        }
        let requestGeneration = beginSessionRequest()
        ClearAheadEngine.shared.prepareModels(configuration: parsed, allowDetectorOnly: true) { result in
            DispatchQueue.main.async {
                guard self.isCurrentSessionRequest(requestGeneration) else {
                    resolve(nil)
                    return
                }
                switch result {
                case .success:
                    ClearAheadEngine.shared.start(configuration: parsed)
                    resolve(nil)
                case let .failure(error):
                    reject("model_prepare_failed", error.localizedDescription, error)
                }
            }
        }
    }

    private func beginSessionRequest() -> Int {
        requestLock.lock()
        defer { requestLock.unlock() }
        sessionGeneration += 1
        return sessionGeneration
    }

    private func invalidateSessionRequests() {
        requestLock.lock()
        sessionGeneration += 1
        requestLock.unlock()
    }

    private func isCurrentSessionRequest(_ generation: Int) -> Bool {
        requestLock.lock()
        defer { requestLock.unlock() }
        return generation == sessionGeneration
    }

    @objc(prepareModels:resolver:rejecter:)
    func prepareModels(
        _ modelVariant: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        var configuration = FeedbackConfiguration()
        configuration.modelVariant = modelVariant
        ClearAheadEngine.shared.prepareModels(configuration: configuration) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    resolve(nil)
                case let .failure(error):
                    reject("model_prepare_failed", error.localizedDescription, error)
                }
            }
        }
    }

    @objc(cancelModelPreparation:rejecter:)
    func cancelModelPreparation(_ resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
        invalidateSessionRequests()
        ClearAheadEngine.shared.cancelModelPreparation()
        resolve(nil)
    }

    @objc(stopSession:rejecter:)
    func stopSession(
        _ resolve: RCTPromiseResolveBlock,
        rejecter reject: RCTPromiseRejectBlock
    ) {
        invalidateSessionRequests()
        ClearAheadEngine.shared.stop()
        resolve(nil)
    }

    @objc(updateConfiguration:resolver:rejecter:)
    func updateConfiguration(
        _ configuration: NSDictionary,
        resolver resolve: RCTPromiseResolveBlock,
        rejecter reject: RCTPromiseRejectBlock
    ) {
        ClearAheadEngine.shared.update(
            configuration: FeedbackConfiguration(dictionary: configuration as? [String: Any] ?? [:])
        )
        resolve(nil)
    }

}
