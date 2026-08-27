import assert from 'node:assert/strict';
import test from 'node:test';
import {
  clamp,
  describeDirection,
  describeEvent,
  qualityMessage,
  stepValue,
} from '../src/utils/eventLogic.ts';
import type {SpatialEvent} from '../src/types.ts';

test('clamp and adjustable stepping stay inside configured bounds', () => {
  assert.equal(clamp(-1), 0);
  assert.equal(clamp(2), 1);
  assert.equal(stepValue(0.95, 'increment', 0.1, 0.1, 1), 1);
  assert.equal(stepValue(0.1, 'decrement', 0.1, 0.1, 1), 0.1);
});

test('directions include a clock position for speech', () => {
  assert.equal(describeDirection('left'), "left, around 10 o'clock");
  assert.equal(describeDirection('center'), 'straight ahead');
  assert.equal(describeDirection('right'), "right, around 2 o'clock");
});

test('event descriptions prefer explicitly approximate meters', () => {
  const event: SpatialEvent = {
    id: 'person:left',
    kind: 'person',
    direction: 'left',
    proximity: 'near',
    approximateDistanceMeters: 1.84,
    approachSpeed: 0.5,
    confidence: 0.9,
    urgency: 0.8,
    timestamp: 1,
  };

  assert.equal(
    describeEvent(event),
    "person, about 1.8 meters, left, around 10 o'clock",
  );
});

test('quality messages provide a corrective action', () => {
  assert.match(qualityMessage('camera-covered'), /Check the lens/);
  assert.match(qualityMessage('moving-too-fast'), /Slow down/);
  assert.match(qualityMessage('thermal-limited'), /slowed/);
});
