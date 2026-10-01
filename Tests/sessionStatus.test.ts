import assert from 'node:assert/strict';
import test from 'node:test';
import { cameraStartedMessage } from '../src/utils/sessionStatus.ts';

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

test('camera start waits for frames after models are ready', () => {
  assert.equal(
    cameraStartedMessage('Starting camera', {
      state: 'starting',
      message: 'Models ready. Waiting for camera frames.',
      severity: 'info',
      code: 'models-ready',
    }),
    'Camera started. Waiting for frames.',
  );
});

test('camera start preserves confirmed frame receipt', () => {
  const message = 'Camera frames and on-device models active';
  assert.equal(
    cameraStartedMessage('Starting camera', {
      state: 'running',
      message,
      severity: 'info',
      code: 'receiving-frames',
    }),
    message,
  );
});

test('camera start keeps detector-only warning visible', () => {
  const warning = 'Depth unavailable. Named object cues remain active.';
  assert.equal(
    cameraStartedMessage(warning, {
      state: 'running',
      message: warning,
      severity: 'warning',
      code: 'depth-unavailable',
    }),
    warning,
  );
});

test('camera start keeps pipeline failure and stall warnings visible', () => {
  for (const code of [
    'object-unavailable',
    'pipeline-unavailable',
    'camera-stalled',
  ] as const) {
    assert.equal(
      cameraStartedMessage('Pipeline warning', {
        state: 'running',
        message: 'Pipeline warning',
        severity: 'warning',
        code,
      }),
      'Pipeline warning',
    );
  }
});
