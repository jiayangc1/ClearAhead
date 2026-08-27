import assert from 'node:assert/strict';
import test from 'node:test';
import {DEFAULT_PREFERENCES, toFeedbackConfiguration} from '../src/config.ts';

test('default configuration has at least one nonvisual feedback channel', () => {
  assert.equal(DEFAULT_PREFERENCES.hapticsEnabled, true);
  assert.equal(DEFAULT_PREFERENCES.audioEnabled, true);
});

test('native configuration omits React Native onboarding state', () => {
  const configuration = toFeedbackConfiguration(DEFAULT_PREFERENCES);
  assert.equal('onboardingComplete' in configuration, false);
  assert.equal(configuration.version, 1);
  assert.equal(configuration.mountingMode, 'handheld');
});

test('speech defaults to high-value categories only', () => {
  assert.deepEqual(DEFAULT_PREFERENCES.spokenCategories, [
    'person',
    'vehicle',
    'device-warning',
  ]);
  assert.equal(DEFAULT_PREFERENCES.spokenCategories.includes('furniture'), false);
});
