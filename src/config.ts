import type { AppPreferences, FeedbackConfiguration } from './types';

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
  spokenCategories: ['person', 'vehicle', 'device-warning'],
};

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
