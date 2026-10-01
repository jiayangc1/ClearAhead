import assert from 'node:assert/strict';
import test from 'node:test';
import {
  SessionController,
  runFeedbackTest,
} from '../src/utils/sessionController.ts';

test('stop during configuration prevents a delayed start', async () => {
  let finish!: () => void;
  const preparation = new Promise<void>(resolve => {
    finish = resolve;
  });
  let starts = 0;
  const session = new SessionController(
    () => preparation,
    async () => {
      starts++;
    },
    async () => {},
  );
  const pending = session.start();
  await session.stop();
  finish();
  assert.equal(await pending, false);
  assert.equal(starts, 0);
});

test('feedback test always stops when native start fails', async () => {
  let stops = 0;
  const session = new SessionController(
    async () => {},
    async () => {
      throw new Error('audio failed');
    },
    async () => {
      stops++;
    },
  );
  await assert.rejects(
    runFeedbackTest(session, new AbortController().signal, 0),
    /audio failed/,
  );
  assert.equal(stops, 1);
});

test('background cancellation shuts down a pending demo', async () => {
  let started!: () => void;
  const ready = new Promise<void>(resolve => {
    started = resolve;
  });
  let stops = 0;
  const session = new SessionController(
    async () => {},
    async () => {
      started();
    },
    async () => {
      stops++;
    },
  );
  const abort = new AbortController();
  const pending = runFeedbackTest(session, abort.signal, 60_000);
  await ready;
  abort.abort();
  await pending;
  assert.equal(stops, 1);
});
