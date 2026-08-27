import type { HybridObject } from 'react-native-nitro-modules'
import type { Frame } from 'react-native-vision-camera'

export interface ClearAheadVision extends HybridObject<{ ios: 'swift' }> {
  processFrame(frame: Frame): void
  reportDroppedFrame(reason: string): void
}
