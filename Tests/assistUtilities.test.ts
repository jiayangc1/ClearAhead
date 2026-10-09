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

test('LiDAR selection requires rear hardware depth and preserves explicit lenses', () => {
  const wide = { id: 'wide', position: 'back', type: 'wide-angle', mediaTypes: ['video'] };
  const lidar = { id: 'lidar', position: 'back', type: 'lidar-depth', mediaTypes: ['video', 'depth'] };
  const cameras = [wide, lidar];
  assert.equal(chooseRearCamera(cameras, 'standard', true)?.id, 'lidar');
  assert.equal(chooseRearCamera(cameras, 'standard', false)?.id, 'wide');
  assert.equal(chooseRearCamera(cameras, 'wide', true)?.id, 'wide');
  assert.equal(chooseRearCamera([wide], 'standard', true)?.id, 'wide');
  assert.equal(chooseRearCamera([wide, { ...lidar, mediaTypes: ['video'] }], 'standard', true)?.id, 'wide');
  assert.equal(chooseRearCamera([wide, { ...lidar, position: 'front' }], 'standard', true)?.id, 'wide');
});

test('brief hazard dropouts and quality changes do not interrupt warnings', () => {
  const gate = new AnnouncementGate();
  const event: SpatialEvent = {
    id: 'depth:path', kind: 'obstacle', direction: 'center', proximity: 'near',
    approachSpeed: 0.5, motionState: 'approaching', collisionRisk: 'caution',
    trajectoryConfidence: 0.9, confidence: 0.9, urgency: 0.8, timestamp: 10,
  };
  assert.equal(gate.event(event, 10), true);
  assert.equal(gate.message('Low light', 10.2), false);
  gate.clear(10.4);
  assert.equal(gate.event(event, 10.7), false);
  assert.equal(gate.event({ ...event, id: 'person:1' }, 10.8), false);
  assert.equal(gate.event({ ...event, collisionRisk: 'imminent' }, 10.9), true);
  gate.clear(11);
  assert.equal(gate.event(event, 14.1), true);
});

test('quality announcements have a shared cooldown and a longer duplicate cooldown', () => {
  const gate = new AnnouncementGate();
  assert.equal(gate.message('Low light', 10), true);
  assert.equal(gate.message('Camera covered', 11), false);
  assert.equal(gate.message('Low light', 15), false);
  assert.equal(gate.message('Camera covered', 15), true);
  assert.equal(gate.message('Pipeline failed', 15.1, true), true);
});
