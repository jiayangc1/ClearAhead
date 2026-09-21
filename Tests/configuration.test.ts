import assert from 'node:assert/strict';
import test from 'node:test';
import {
  DEFAULT_PREFERENCES,
  normalizePreferences,
  toFeedbackConfiguration,
} from '../src/config.ts';

test('default configuration has at least one nonvisual feedback channel', () => {
  assert.equal(DEFAULT_PREFERENCES.hapticsEnabled, true);
  assert.equal(DEFAULT_PREFERENCES.audioEnabled, true);
  assert.equal(DEFAULT_PREFERENCES.cameraDeviceId, 'widest');
});

test('native configuration omits React Native onboarding state', () => {
  const configuration = toFeedbackConfiguration(DEFAULT_PREFERENCES);
  assert.equal('onboardingComplete' in configuration, false);
  assert.equal('cameraDeviceId' in configuration, false);
  assert.equal(configuration.version, 1);
  assert.equal(configuration.mountingMode, 'handheld');
  assert.equal(configuration.modelVariant, 'n');
  assert.equal(configuration.modelQuantization, 'int8');
  assert.equal(configuration.depthMapEnabled, false);
});

test('speech defaults to high-value categories only', () => {
  assert.deepEqual(DEFAULT_PREFERENCES.spokenCategories, [
    'person',
    'vehicle',
    'device-warning',
  ]);
  assert.equal(
    DEFAULT_PREFERENCES.spokenCategories.includes('furniture'),
    false,
  );
});

test('stored preferences are validated and clamped before use', () => {
  const preferences = normalizePreferences({
    onboardingComplete: 'yes',
    audioVolume: 4,
    sensitivity: Number.NaN,
    warningDistanceMeters: -20,
    mountingMode: 'tripod',
    modelVariant: 'unknown',
    cameraDeviceId: 'rear-camera-id',
    spokenCategories: ['person', 'person', 'invalid', 3],
  });

  assert.equal(preferences.onboardingComplete, false);
  assert.equal(preferences.audioVolume, 1);
  assert.equal(preferences.sensitivity, DEFAULT_PREFERENCES.sensitivity);
  assert.equal(preferences.warningDistanceMeters, 1);
  assert.equal(preferences.mountingMode, 'handheld');
  assert.equal(preferences.modelVariant, 'n');
  assert.equal(preferences.cameraDeviceId, 'rear-camera-id');
  assert.deepEqual(preferences.spokenCategories, ['person']);
});
