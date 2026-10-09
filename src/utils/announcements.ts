import type { SpatialEvent } from '../types';

const proximityRank = { unknown: 0, far: 1, medium: 2, near: 3 };
const riskRank = { none: 0, caution: 1, imminent: 2 };

// Track ids change whenever tracking hiccups; what the listener hears does not.
const heardAs = (event: SpatialEvent) =>
  `${event.label ?? event.kind}|${event.direction}`;

export class AnnouncementGate {
  private lastEvent?: SpatialEvent;
  private lastMessage = '';
  private lastMessageTime = -Infinity;
  private lastAnnouncementTime = -Infinity;
  private clearedAt?: number;

  event(event: SpatialEvent, now: number): boolean {
    const previous = this.clearedAt != null && now - this.clearedAt >= 3
      ? undefined : this.lastEvent;
    this.clearedAt = undefined;
    const escalated = !previous || riskRank[event.collisionRisk] > riskRank[previous.collisionRisk];
    const changed =
      !previous ||
      heardAs(event) !== heardAs(previous) ||
      riskRank[event.collisionRisk] > riskRank[previous.collisionRisk] ||
      proximityRank[event.proximity] > proximityRank[previous.proximity] ||
      (event.motionState === 'approaching' &&
        previous.motionState !== 'approaching') ||
      event.urgency >= previous.urgency + 0.2;
    if (
      !changed ||
      (!escalated && now - this.lastAnnouncementTime < 4)
    ) {
      return false;
    }
    this.lastEvent = event;
    this.lastAnnouncementTime = now;
    return true;
  }

  message(message: string, now: number, urgent = false): boolean {
    if (
      (message === this.lastMessage && now - this.lastMessageTime < 10) ||
      (!urgent && now - this.lastAnnouncementTime < 3)
    ) {
      return false;
    }
    this.lastMessage = message;
    this.lastMessageTime = now;
    this.lastAnnouncementTime = now;
    return true;
  }

  clear(now = Date.now() / 1000): void {
    this.clearedAt ??= now;
  }
}
