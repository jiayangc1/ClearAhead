import type { SpatialEvent } from '../types';

const proximityRank = { unknown: 0, far: 1, medium: 2, near: 3 };
const riskRank = { none: 0, caution: 1, imminent: 2 };

export class AnnouncementGate {
  private lastEvent?: SpatialEvent;
  private lastEventTime = -Infinity;
  private lastMessage = '';
  private lastMessageTime = -Infinity;

  event(event: SpatialEvent, now: number): boolean {
    const previous = this.lastEvent;
    const changed =
      !previous ||
      event.id !== previous.id ||
      riskRank[event.collisionRisk] > riskRank[previous.collisionRisk] ||
      proximityRank[event.proximity] > proximityRank[previous.proximity] ||
      (event.motionState === 'approaching' &&
        previous.motionState !== 'approaching') ||
      event.urgency >= previous.urgency + 0.2;
    if (
      !changed ||
      (event.collisionRisk !== 'imminent' && now - this.lastEventTime < 0.32)
    ) {
      return false;
    }
    this.lastEvent = event;
    this.lastEventTime = now;
    return true;
  }

  message(message: string, now: number, urgent = false): boolean {
    if (
      (message === this.lastMessage && now - this.lastMessageTime < 2.5) ||
      (!urgent && now - this.lastMessageTime < 1)
    ) {
      return false;
    }
    this.lastMessage = message;
    this.lastMessageTime = now;
    return true;
  }

  clear(): void {
    this.lastEvent = undefined;
  }
}
