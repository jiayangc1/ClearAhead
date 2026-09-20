import type {SessionStatusPayload} from '../types';

export function cameraStartedMessage(
  currentMessage: string,
  latestStatus?: SessionStatusPayload,
): string {
  return latestStatus?.code === 'model-load-failed'
    ? currentMessage
    : 'Camera active';
}
