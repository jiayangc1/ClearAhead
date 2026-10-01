import type { SessionStatusPayload } from '../types';

export function cameraStartedMessage(
  currentMessage: string,
  latestStatus?: SessionStatusPayload,
): string {
  return latestStatus?.severity === 'warning' ||
    latestStatus?.severity === 'error' ||
    latestStatus?.code === 'model-load-failed' ||
    latestStatus?.code === 'depth-unavailable'
    ? currentMessage
    : latestStatus?.state === 'running'
    ? latestStatus.message
    : 'Camera started. Waiting for frames.';
}
