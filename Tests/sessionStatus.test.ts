import assert from 'node:assert/strict';
import test from 'node:test';
import {cameraStartedMessage} from '../src/utils/sessionStatus.ts';

test('camera start does not hide a model-load failure', () => {
  const failure = 'Camera active. YOLO26 models are not installed.';
  assert.equal(
    cameraStartedMessage(failure, {
      state: 'running',
      message: failure,
      severity: 'error',
      code: 'model-load-failed',
    }),
    failure,
  );
});

test('camera start replaces ordinary startup status', () => {
  assert.equal(
    cameraStartedMessage('Starting camera', {
      state: 'running',
      message: 'Camera and on-device models active',
      severity: 'info',
      code: 'models-ready',
    }),
    'Camera active',
  );
});
