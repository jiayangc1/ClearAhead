import assert from 'node:assert/strict';
import test from 'node:test';
import {
  DEFAULT_PREFERENCES,
  hasFeedbackChannel,
  normalizePreferences,
  toFeedbackConfiguration,
} from '../src/config.ts';

test('default configuration has at least one nonvisual feedback channel', () => {
  assert.equal(DEFAULT_PREFERENCES.hapticsEnabled, true);
  assert.equal(DEFAULT_PREFERENCES.audioEnabled, true);
  assert.equal(DEFAULT_PREFERENCES.cameraDeviceId, 'standard');
});

test('stored official model variants remain selectable', () => {
  for (const modelVariant of ['s', 'm', 'l', 'x']) {
    assert.equal(normalizePreferences({ modelVariant }).modelVariant, modelVariant);
  }
});

test('legacy automatic widest setting migrates to standard wide', () => {
  assert.equal(
    normalizePreferences({ cameraDeviceId: 'widest' }).cameraDeviceId,
    'standard',
  );
});

test('silent configuration cannot start assist mode', () => {
  assert.equal(hasFeedbackChannel(DEFAULT_PREFERENCES), true);
  assert.equal(
    hasFeedbackChannel({
      ...DEFAULT_PREFERENCES,
      hapticsEnabled: false,
      audioEnabled: false,
      speechEnabled: false,
    }),
    false,
  );
});

test('native configuration omits React Native onboarding state', () => {
  const configuration = toFeedbackConfiguration(DEFAULT_PREFERENCES);
  assert.equal('onboardingComplete' in configuration, false);
  assert.equal('cameraDeviceId' in configuration, false);
  assert.equal(configuration.version, 1);
  assert.equal(configuration.mountingMode, 'handheld');
  assert.equal(configuration.modelVariant, 'n');
  assert.equal('modelQuantization' in configuration, false);
  assert.equal('modelQuantization' in DEFAULT_PREFERENCES, false);
  assert.equal('feedbackFrequency' in configuration, false);
  assert.equal(configuration.continuousAudio, true);
  assert.equal(normalizePreferences({ continuousAudio: false }).continuousAudio, false);
  assert.equal(normalizePreferences({ continuousAudio: 'no' }).continuousAudio, true);
  assert.equal(configuration.depthMapEnabled, false);
  assert.equal(configuration.showBoundingBoxes, true);
});

test('speech defaults to high-value categories only', () => {
  assert.deepEqual(DEFAULT_PREFERENCES.spokenCategories, [
    'person',
    'vehicle',
    'obstacle',
    'furniture',
  ]);
});

test('bounding box verbosity migrates older settings and reaches native configuration', () => {
  assert.equal(normalizePreferences({}).boundingBoxVerbosity, 'standard');
  assert.equal(normalizePreferences({ boundingBoxVerbosity: 'invalid' }).boundingBoxVerbosity, 'standard');
  for (const boundingBoxVerbosity of ['verbose', 'standard', 'less']) {
    const preferences = normalizePreferences({ boundingBoxVerbosity });
    assert.equal(preferences.boundingBoxVerbosity, boundingBoxVerbosity);
    assert.equal(toFeedbackConfiguration(preferences).boundingBoxVerbosity, boundingBoxVerbosity);
  }
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
