import { NitroModules } from 'react-native-nitro-modules'
import type { ClearAheadVision as ClearAheadVisionSpec } from './specs/clear-ahead-vision.nitro'

export const ClearAheadVision =
  NitroModules.createHybridObject<ClearAheadVisionSpec>('ClearAheadVision')