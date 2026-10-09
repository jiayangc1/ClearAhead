import type {
  Direction,
  Proximity,
  SessionQuality,
  SpatialEvent,
} from '../types';

export function clamp(value: number, minimum = 0, maximum = 1): number {
  return Math.min(Math.max(value, minimum), maximum);
}

export function describeDirection(direction: Direction): string {
  switch (direction) {
    case 'left':
      return "left, around 10 o'clock";
    case 'center':
      return 'straight ahead';
    case 'right':
      return "right, around 2 o'clock";
  }
}

export function describeProximity(event: SpatialEvent): string {
  if (event.approximateDistanceMeters != null) {
    return `about ${event.approximateDistanceMeters.toFixed(1)} meters`;
  }
  const names: Record<Proximity, string> = {
    near: 'nearby',
    medium: 'at medium range',
    far: 'farther away',
    unknown: 'distance uncertain',
  };
  return names[event.proximity];
}

export function describeEvent(event: SpatialEvent): string {
  const label = event.label ?? event.kind.replace('-', ' ');
  if (event.collisionRisk !== 'none') {
    const timing = event.timeToCollisionSeconds != null
      ? ` in about ${Math.max(event.timeToCollisionSeconds, 0.1).toFixed(1)} seconds`
      : '';
    const warning = event.collisionRisk === 'imminent'
      ? `Collision likely${timing}`
      : `Possible collision${timing}`;
    return `${warning}: ${label}, ${describeDirection(event.direction)}`;
  }
  return `${label}, ${describeProximity(
    event,
  )}, ${describeDirection(event.direction)}${
    event.motionState === 'approaching' ? ', approaching' : ''
  }`;
}

/** One short line for the assist card: what it is, where, and how far. */
export function summarizeEvent(event: SpatialEvent): string {
  const label = event.label === 'surface' ? 'obstacle' : event.label ?? event.kind;
  const name = label.charAt(0).toUpperCase() + label.slice(1);
  const place = event.direction === 'center' ? 'ahead' : `on your ${event.direction}`;
  if (event.outOfView) {
    return `${name} ${place} · out of view`;
  }
  return event.approximateDistanceMeters != null
    ? `${name} ${place} · ${event.approximateDistanceMeters.toFixed(1)} m`
    : `${name} ${place}`;
}

export function qualityMessage(quality: SessionQuality): string {
  const messages: Record<SessionQuality, string> = {
    good: 'Camera view is clear',
    'low-light': 'Low light. Detection may be less reliable.',
    'camera-covered': 'Camera may be covered. Check the lens.',
    'camera-too-close': 'Camera too close. Move it back.',
    'moving-too-fast': 'Phone is moving too quickly. Slow down.',
    'thermal-limited': 'Device is warm. Processing has slowed.',
  };
  return messages[quality];
}

export function stepValue(
  value: number,
  direction: 'increment' | 'decrement',
  step: number,
  minimum: number,
  maximum: number,
): number {
  const delta = direction === 'increment' ? step : -step;
  return Math.round(clamp(value + delta, minimum, maximum) * 100) / 100;
}
