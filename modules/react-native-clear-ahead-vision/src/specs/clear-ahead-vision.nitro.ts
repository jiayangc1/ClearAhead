import type { HybridObject } from 'react-native-nitro-modules'
import type { Frame, CameraFrameOutput, CameraDepthFrameOutput } from 'react-native-vision-camera'

export interface ClearAheadVision extends HybridObject<{ ios: 'swift' }> {
  processFrame(frame: Frame): void
  connectDepthOutputs(frameOutput: CameraFrameOutput, depthOutput: CameraDepthFrameOutput): void
  reportDroppedFrame(reason: string): void
}
