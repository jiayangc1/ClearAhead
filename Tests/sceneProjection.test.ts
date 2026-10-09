import assert from 'node:assert/strict';
import test from 'node:test';
import { projectSceneBox } from '../src/utils/sceneProjection.ts';

test('scene contours and labels follow portrait aspect-fill crop', () => {
  const box = { x: 0.25, y: 0.25, width: 0.5, height: 0.5 };
  assert.deepEqual(projectSceneBox(box, 0.5, 0.5), box);
  assert.deepEqual(projectSceneBox(box, 1, 0.5), { x: 0, y: 0.25, width: 1, height: 0.5 });
  assert.deepEqual(projectSceneBox(box, 0.5, 1), { x: 0.25, y: 0, width: 0.5, height: 1 });
});
