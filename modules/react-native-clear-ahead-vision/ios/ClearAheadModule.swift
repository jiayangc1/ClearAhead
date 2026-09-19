import Foundation
import React

@objc(ClearAheadModule)
final class ClearAheadModule: RCTEventEmitter {
    private static weak var currentEmitter: ClearAheadModule?
    private var hasListeners = false

    override init() {
        super.init()
        Self.currentEmitter = self
    }

    override static func requiresMainQueueSetup() -> Bool { true }

    override func supportedEvents() -> [String]! {
        ["sessionStatus", "topEvent", "eventCleared", "qualityChanged", "performanceMetrics"]
    }

    override func startObserving() { hasListeners = true }
    override func stopObserving() { hasListeners = false }

    static func emit(name: String, body: [String: Any]) {
        DispatchQueue.main.async {
            guard let emitter = currentEmitter, emitter.hasListeners else { return }
            emitter.sendEvent(withName: name, body: body)
        }
    }

    @objc(startSession:resolver:rejecter:)
    func startSession(
        _ configuration: NSDictionary,
        resolver resolve: RCTPromiseResolveBlock,
        rejecter reject: RCTPromiseRejectBlock
    ) {
        ClearAheadEngine.shared.start(
            configuration: CAFeedbackConfiguration(dictionary: configuration as? [String: Any] ?? [:])
        )
        resolve(nil)
    }

    @objc(stopSession:rejecter:)
    func stopSession(
        _ resolve: RCTPromiseResolveBlock,
        rejecter reject: RCTPromiseRejectBlock
    ) {
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
            configuration: CAFeedbackConfiguration(dictionary: configuration as? [String: Any] ?? [:])
        )
        resolve(nil)
    }

    @objc(startDemo:resolver:rejecter:)
    func startDemo(
        _ scenario: String,
        resolver resolve: RCTPromiseResolveBlock,
        rejecter reject: RCTPromiseRejectBlock
    ) {
        ClearAheadEngine.shared.startDemo(scenario: scenario)
        resolve(nil)
    }

    @objc(stopDemo:rejecter:)
    func stopDemo(
        _ resolve: RCTPromiseResolveBlock,
        rejecter reject: RCTPromiseRejectBlock
    ) {
        ClearAheadEngine.shared.stopDemo()
        resolve(nil)
    }
}
