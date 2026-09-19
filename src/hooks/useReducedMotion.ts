import {useEffect, useState} from 'react';
import {AccessibilityInfo} from 'react-native';

let cachedReducedMotion: boolean | undefined;
let subscription: {remove: () => void} | undefined;
const listeners = new Set<(value: boolean) => void>();
let isFetchingInitialValue = false;

function broadcast(value: boolean) {
  cachedReducedMotion = value;
  listeners.forEach(listener => listener(value));
}

function ensureSubscription() {
  if (!subscription) {
    subscription = AccessibilityInfo.addEventListener('reduceMotionChanged', broadcast);
  }

  if (cachedReducedMotion === undefined && !isFetchingInitialValue) {
    isFetchingInitialValue = true;
    AccessibilityInfo.isReduceMotionEnabled()
      .then(enabled => broadcast(enabled))
      .finally(() => {
        isFetchingInitialValue = false;
      });
  }
}

function teardownSubscriptionIfUnused() {
  if (listeners.size === 0 && subscription) {
    subscription.remove();
    subscription = undefined;
  }
}

export function useReducedMotion() {
  const [reducedMotion, setReducedMotion] = useState<boolean>(cachedReducedMotion ?? false);

  useEffect(() => {
    ensureSubscription();
    listeners.add(setReducedMotion);

    if (cachedReducedMotion !== undefined) {
      setReducedMotion(cachedReducedMotion);
    }

    return () => {
      listeners.delete(setReducedMotion);
      teardownSubscriptionIfUnused();
    };
  }, []);

  return reducedMotion;
}
