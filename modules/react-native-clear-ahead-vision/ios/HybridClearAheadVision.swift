//
//  HybridClearAheadVision.swift
//  Pods
//
//  Created by Jiayang Chen on 8/26/2026.
//

import Foundation
import VisionCamera

class HybridClearAheadVision: HybridClearAheadVisionSpec {
    func processFrame(frame: any HybridFrameSpec) throws {
        guard let nativeFrame = frame as? any NativeFrame,
              let sampleBuffer = nativeFrame.sampleBuffer else {
            return
        }

        ClearAheadEngine.shared.process(sampleBuffer: sampleBuffer)
    }

    func reportDroppedFrame(reason: String) throws {
        ClearAheadEngine.shared.reportDroppedFrame(reason: reason)
    }
}
