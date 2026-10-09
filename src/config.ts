import type {
  AppPreferences,
  BoundingBoxVerbosity,
  EventKind,
  FeedbackConfiguration,
  ModelVariant,
  MountingMode,
  ProcessingMode,
  SpeechDetail,
} from './types';

// Soft fills carry state; the ink colors keep text at reading contrast on them.
export const colors = {
  background: '#FAF7F2',
  surface: '#FFFFFF',
  surfaceRaised: '#EFEDF9',
  ink: '#2B2838',
  muted: '#6B6779',
  line: '#E7E2EC',
  accent: '#BCC8F9',
  accentStrong: '#8C9CEB',
  accentInk: '#4A53A6',
  mint: '#C5E9D7',
  mintInk: '#2C6549',
  peach: '#FBDDBB',
  peachInk: '#8A5210',
  coral: '#F8C1BC',
  coralInk: '#9C2F2F',
  black: '#000000',
} as const;

export const DEFAULT_PREFERENCES: AppPreferences = {
  version: 1,
  onboardingComplete: false,
  hapticsEnabled: true,
  audioEnabled: true,
  speechEnabled: true,
  hapticIntensity: 1,
  audioVolume: 1,
  continuousAudio: true,
  sensitivity: 0.65,
  warningDistanceMeters: 6,
  mountingMode: 'handheld',
  cameraHeightMeters: 0,
  earHeightMeters: 0,
  cameraForwardOffsetMeters: 0,
  cameraRightOffsetMeters: 0,
  processingMode: 'responsive',
  modelVariant: 'n',
  depthMapEnabled: false,
  lidarEnabled: true,
  showFps: false,
  showBoundingBoxes: true,
  boundingBoxVerbosity: 'standard',
  cameraDeviceId: 'standard',
  spokenCategories: ['person', 'vehicle', 'obstacle', 'furniture'],
  speechDetail: 'hazards',
};

export function hasFeedbackChannel(preferences: AppPreferences): boolean {
  return (
    preferences.hapticsEnabled ||
    preferences.audioEnabled ||
    preferences.speechEnabled
  );
}

const mountingModes = new Set<MountingMode>(['handheld', 'chest']);
const processingModes = new Set<ProcessingMode>(['responsive', 'detailed']);
const modelVariants = new Set<ModelVariant>(['n', 's', 'm', 'l', 'x']);
const boundingBoxVerbosities = new Set<BoundingBoxVerbosity>([
  'verbose', 'standard', 'less',
]);
const eventKinds = new Set<EventKind>([
  'obstacle',
  'person',
  'vehicle',
  'furniture',
]);

function finiteNumber(
  value: unknown,
  fallback: number,
  minimum: number,
  maximum: number,
): number {
  return typeof value === 'number' && Number.isFinite(value)
    ? Math.min(Math.max(value, minimum), maximum)
    : fallback;
}

// Levels saved while the defaults were 72% and 65% were never chosen by hand:
// the stepper cannot land on them from the current default of 100%.
function feedbackLevel(value: unknown, previousDefault: number): number {
  return finiteNumber(value === previousDefault ? undefined : value, 1, 0, 1);
}

function boolean(value: unknown, fallback: boolean): boolean {
  return typeof value === 'boolean' ? value : fallback;
}

/** Safely migrates untrusted or older AsyncStorage data into the current schema. */
export function normalizePreferences(value: unknown): AppPreferences {
  const stored =
    typeof value === 'object' && value !== null
      ? (value as Record<string, unknown>)
      : {};
  const mountingMode = mountingModes.has(stored.mountingMode as MountingMode)
    ? (stored.mountingMode as MountingMode)
    : DEFAULT_PREFERENCES.mountingMode;
  const processingMode = processingModes.has(
    stored.processingMode as ProcessingMode,
  )
    ? (stored.processingMode as ProcessingMode)
    : DEFAULT_PREFERENCES.processingMode;
  const modelVariant = modelVariants.has(stored.modelVariant as ModelVariant)
    ? (stored.modelVariant as ModelVariant)
    : DEFAULT_PREFERENCES.modelVariant;
  const spokenCategories = Array.isArray(stored.spokenCategories)
    ? [...new Set(stored.spokenCategories)].filter(
        (kind): kind is EventKind =>
          typeof kind === 'string' && eventKinds.has(kind as EventKind),
      )
    : DEFAULT_PREFERENCES.spokenCategories;

  return {
    version: 1,
    onboardingComplete: boolean(
      stored.onboardingComplete,
      DEFAULT_PREFERENCES.onboardingComplete,
    ),
    hapticsEnabled: boolean(
      stored.hapticsEnabled,
      DEFAULT_PREFERENCES.hapticsEnabled,
    ),
    audioEnabled: boolean(
      stored.audioEnabled,
      DEFAULT_PREFERENCES.audioEnabled,
    ),
    speechEnabled: boolean(
      stored.speechEnabled,
      DEFAULT_PREFERENCES.speechEnabled,
    ),
    hapticIntensity: feedbackLevel(stored.hapticIntensity, 0.72),
    audioVolume: feedbackLevel(stored.audioVolume, 0.65),
    continuousAudio: boolean(
      stored.continuousAudio,
      DEFAULT_PREFERENCES.continuousAudio,
    ),
    sensitivity: finiteNumber(
      stored.sensitivity,
      DEFAULT_PREFERENCES.sensitivity,
      0,
      1,
    ),
    warningDistanceMeters: finiteNumber(
      stored.warningDistanceMeters,
      DEFAULT_PREFERENCES.warningDistanceMeters,
      1,
      12,
    ),
    mountingMode,
    cameraHeightMeters: finiteNumber(stored.cameraHeightMeters, 0, 0, 2.5),
    earHeightMeters: finiteNumber(stored.earHeightMeters, 0, 0, 2.5),
    cameraForwardOffsetMeters: finiteNumber(stored.cameraForwardOffsetMeters, 0, 0, 0.8),
    cameraRightOffsetMeters: finiteNumber(stored.cameraRightOffsetMeters, 0, -0.5, 0.5),
    processingMode,
    modelVariant,
    depthMapEnabled: boolean(
      stored.depthMapEnabled,
      DEFAULT_PREFERENCES.depthMapEnabled,
    ),
    lidarEnabled: boolean(stored.lidarEnabled, DEFAULT_PREFERENCES.lidarEnabled),
    showFps: boolean(stored.showFps, DEFAULT_PREFERENCES.showFps),
    showBoundingBoxes: boolean(
      stored.showBoundingBoxes,
      DEFAULT_PREFERENCES.showBoundingBoxes,
    ),
    boundingBoxVerbosity: boundingBoxVerbosities.has(
      stored.boundingBoxVerbosity as BoundingBoxVerbosity,
    )
      ? (stored.boundingBoxVerbosity as BoundingBoxVerbosity)
      : DEFAULT_PREFERENCES.boundingBoxVerbosity,
    cameraDeviceId:
      typeof stored.cameraDeviceId === 'string' &&
      stored.cameraDeviceId.length > 0 &&
      stored.cameraDeviceId !== 'widest'
        ? stored.cameraDeviceId
        : DEFAULT_PREFERENCES.cameraDeviceId,
    spokenCategories,
    speechDetail: (stored.speechDetail === 'everything'
      ? 'everything'
      : DEFAULT_PREFERENCES.speechDetail) satisfies SpeechDetail,
  };
}

export function toFeedbackConfiguration(
  preferences: AppPreferences,
): FeedbackConfiguration {
  return {
    version: preferences.version,
    hapticsEnabled: preferences.hapticsEnabled,
    audioEnabled: preferences.audioEnabled,
    speechEnabled: preferences.speechEnabled,
    hapticIntensity: preferences.hapticIntensity,
    audioVolume: preferences.audioVolume,
    continuousAudio: preferences.continuousAudio,
    sensitivity: preferences.sensitivity,
    warningDistanceMeters: preferences.warningDistanceMeters,
    mountingMode: preferences.mountingMode,
    cameraHeightMeters: preferences.cameraHeightMeters,
    earHeightMeters: preferences.earHeightMeters,
    cameraForwardOffsetMeters: preferences.cameraForwardOffsetMeters,
    cameraRightOffsetMeters: preferences.cameraRightOffsetMeters,
    processingMode: preferences.processingMode,
    modelVariant: preferences.modelVariant,
    depthMapEnabled: preferences.depthMapEnabled,
    lidarEnabled: preferences.lidarEnabled,
    showBoundingBoxes: preferences.showBoundingBoxes,
    boundingBoxVerbosity: preferences.boundingBoxVerbosity,
    spokenCategories: preferences.spokenCategories,
    speechDetail: preferences.speechDetail,
  };
}
