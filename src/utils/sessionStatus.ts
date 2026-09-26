import type {SessionStatusPayload} from '../types';

export function cameraStartedMessage(
  currentMessage: string,
  latestStatus?: SessionStatusPayload,
): string {
  return latestStatus?.code === 'model-load-failed' ||
    latestStatus?.code === 'depth-unavailable'
    ? currentMessage
    : 'Camera active';
}
