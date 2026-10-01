import assert from 'node:assert/strict';
import test from 'node:test';
import { chooseRearCamera } from '../src/utils/cameraSelection.ts';
import { AnnouncementGate } from '../src/utils/announcements.ts';
import type { SpatialEvent } from '../src/types.ts';

test('standard camera selects wide lens and explicit widest remains selectable', () => {
  const cameras = [
    {
      id: 'ultra',
      position: 'back',
      type: 'ultra-wide-angle',
      focalLength: 13,
    },
    { id: 'wide', position: 'back', type: 'wide-angle', focalLength: 26 },
  ];
  assert.equal(chooseRearCamera(cameras, 'standard')?.id, 'wide');
  assert.equal(chooseRearCamera(cameras, 'missing')?.id, 'wide');
  assert.equal(chooseRearCamera(cameras, 'widest')?.id, 'ultra');
  assert.equal(chooseRearCamera([], 'standard'), undefined);
});

test('announcements ignore metric churn but allow hazard change and risk escalation', () => {
  const gate = new AnnouncementGate();
  const event: SpatialEvent = {
    id: 'person',
    kind: 'person',
    direction: 'center',
    proximity: 'medium',
    approachSpeed: 0,
    motionState: 'stationary',
    collisionRisk: 'none',
    trajectoryConfidence: 1,
    confidence: 0.9,
    urgency: 0.6,
    timestamp: 1,
  };
  assert.equal(gate.event(event, 10), true);
  assert.equal(
    gate.event(
      { ...event, approximateDistanceMeters: 3.9, timestamp: 2 },
      10.25,
    ),
    false,
  );
  assert.equal(
    gate.event({ ...event, collisionRisk: 'imminent' }, 10.26),
    true,
  );
  assert.equal(gate.event({ ...event, collisionRisk: 'imminent' }, 12), false);
});
