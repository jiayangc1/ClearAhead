import Foundation
import AVFoundation
import VisionCamera

class HybridClearAheadVision: HybridClearAheadVisionSpec {
    func connectDepthOutputs(frameOutput: any HybridCameraFrameOutputSpec,
                             depthOutput: any HybridCameraDepthFrameOutputSpec) throws {
        guard let video = (frameOutput as? any NativeCameraOutput)?.output as? AVCaptureVideoDataOutput,
              let depth = (depthOutput as? any NativeCameraOutput)?.output as? AVCaptureDepthDataOutput,
              video.connection(with: .video) != nil, depth.connection(with: .depthData) != nil else {
            throw NSError(domain: "ClearAheadDepth", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "LiDAR outputs are not connected"])
        }
        ClearAheadEngine.shared.connectDepthOutputs(video: video, depth: depth)
    }

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
