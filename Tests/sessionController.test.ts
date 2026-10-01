import assert from 'node:assert/strict';
import test from 'node:test';
import { SessionController } from '../src/utils/sessionController.ts';

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
