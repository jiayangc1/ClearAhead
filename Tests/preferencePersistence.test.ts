import assert from 'node:assert/strict';
import test from 'node:test';
import { createSerializedWriter } from '../src/utils/preferencePersistence.ts';

test('preference writes finish in update order', async () => {
  let releaseFirst: (() => void) | undefined;
  const saved: string[] = [];
  const write = createSerializedWriter(async value => {
    if (value === 'first') {
      await new Promise<void>(resolve => { releaseFirst = resolve; });
    }
    saved.push(value);
  });

  const first = write('first');
  const second = write('second');
  await Promise.resolve();
  assert.deepEqual(saved, []);
  releaseFirst?.();
  await Promise.all([first, second]);
  assert.deepEqual(saved, ['first', 'second']);
});

test('failed preference write does not block later updates', async () => {
  const saved: string[] = [];
  const write = createSerializedWriter(async value => {
    if (value === 'first') throw new Error('storage unavailable');
    saved.push(value);
  });

  await assert.rejects(write('first'));
  await write('second');
  assert.deepEqual(saved, ['second']);
});
