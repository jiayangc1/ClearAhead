import type {
  AppPreferences,
  EventKind,
  FeedbackConfiguration,
  ModelVariant,
  MountingMode,
  ProcessingMode,
} from './types';

export const colors = {
  night: '#000000',
  surface: '#111111',
  surfaceRaised: '#1C1C1C',
  text: '#F2F2F2',
  muted: '#A1A1A1',
  cyan: '#3291FF',
  amber: '#F5A623',
  critical: '#FF4545',
  line: '#2E2E2E',
  black: '#000000',
} as const;

export const DEFAULT_PREFERENCES: AppPreferences = {
  version: 1,
  onboardingComplete: false,
  hapticsEnabled: true,
  audioEnabled: true,
  speechEnabled: false,
  hapticIntensity: 0.72,
  audioVolume: 0.65,
  sensitivity: 0.65,
  warningDistanceMeters: 6,
  feedbackFrequency: 0.55,
  mountingMode: 'handheld',
  processingMode: 'responsive',
  modelVariant: 'n',
  modelQuantization: 'int8',
  depthMapEnabled: false,
  showFps: true,
  showBoundingBoxes: true,
  cameraDeviceId: 'widest',
  spokenCategories: ['person', 'vehicle', 'device-warning'],
};

const mountingModes = new Set<MountingMode>(['handheld', 'chest']);
const processingModes = new Set<ProcessingMode>(['responsive', 'detailed']);
const modelVariants = new Set<ModelVariant>(['n', 's', 'm', 'l', 'x']);
const eventKinds = new Set<EventKind>([
  'obstacle',
  'person',
  'vehicle',
  'furniture',
  'opening',
  'device-warning',
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
    hapticIntensity: finiteNumber(
      stored.hapticIntensity,
      DEFAULT_PREFERENCES.hapticIntensity,
      0,
      1,
    ),
    audioVolume: finiteNumber(
      stored.audioVolume,
      DEFAULT_PREFERENCES.audioVolume,
      0,
      1,
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
    feedbackFrequency: finiteNumber(
      stored.feedbackFrequency,
      DEFAULT_PREFERENCES.feedbackFrequency,
      0,
      1,
    ),
    mountingMode,
    processingMode,
    modelVariant,
    modelQuantization: 'int8',
    depthMapEnabled: boolean(
      stored.depthMapEnabled,
      DEFAULT_PREFERENCES.depthMapEnabled,
    ),
    showFps: boolean(stored.showFps, DEFAULT_PREFERENCES.showFps),
    showBoundingBoxes: boolean(
      stored.showBoundingBoxes,
      DEFAULT_PREFERENCES.showBoundingBoxes,
    ),
    cameraDeviceId:
      typeof stored.cameraDeviceId === 'string' &&
      stored.cameraDeviceId.length > 0
        ? stored.cameraDeviceId
        : DEFAULT_PREFERENCES.cameraDeviceId,
    spokenCategories,
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
    sensitivity: preferences.sensitivity,
    warningDistanceMeters: preferences.warningDistanceMeters,
    feedbackFrequency: preferences.feedbackFrequency,
    mountingMode: preferences.mountingMode,
    processingMode: preferences.processingMode,
    modelVariant: preferences.modelVariant,
    modelQuantization: preferences.modelQuantization,
    depthMapEnabled: preferences.depthMapEnabled,
    spokenCategories: preferences.spokenCategories,
  };
}
