import type {AppPreferences, FeedbackConfiguration} from './types';

export const colors = {
  night: '#071018',
  surface: '#101D27',
  surfaceRaised: '#182A37',
  text: '#F7FBFF',
  muted: '#A8BBC8',
  cyan: '#55D6FF',
  amber: '#FFB547',
  critical: '#FF665E',
  line: '#294250',
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
    spokenCategories: preferences.spokenCategories,
  };
}
