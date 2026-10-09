import AsyncStorage from '@react-native-async-storage/async-storage';
import { useCallback, useEffect, useRef, useState } from 'react';
import type { SessionStats, SessionSummary } from '../types';

const STORAGE_KEY = '@clear-ahead/session-stats-v1';
const EMPTY_STATS: SessionStats = { walks: 0, totalSeconds: 0, alerts: 0 };
// Opening assist mode and backing straight out is not a walk.
const MINIMUM_WALK_SECONDS = 5;

function count(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) && value > 0
    ? Math.floor(value)
    : 0;
}

function normalizeStats(value: unknown): SessionStats {
  const stored =
    typeof value === 'object' && value !== null
      ? (value as Record<string, unknown>)
      : {};
  const last =
    typeof stored.last === 'object' && stored.last !== null
      ? (stored.last as Record<string, unknown>)
      : undefined;
  return {
    walks: count(stored.walks),
    totalSeconds: count(stored.totalSeconds),
    alerts: count(stored.alerts),
    last: last
      ? { durationSeconds: count(last.durationSeconds), alerts: count(last.alerts) }
      : undefined,
  };
}

export function useSessionStats() {
  const [stats, setStats] = useState<SessionStats>(EMPTY_STATS);
  const latest = useRef(stats);

  useEffect(() => {
    let active = true;
    AsyncStorage.getItem(STORAGE_KEY)
      .then(value => {
        // A walk recorded before the read finished already holds newer totals.
        if (!active || !value || latest.current.walks > 0) {
          return;
        }
        latest.current = normalizeStats(JSON.parse(value));
        setStats(latest.current);
      })
      .catch(() => undefined);
    return () => {
      active = false;
    };
  }, []);

  const recordSession = useCallback((summary: SessionSummary) => {
    if (summary.durationSeconds < MINIMUM_WALK_SECONDS) {
      return;
    }
    const next: SessionStats = {
      walks: latest.current.walks + 1,
      totalSeconds: latest.current.totalSeconds + summary.durationSeconds,
      alerts: latest.current.alerts + summary.alerts,
      last: summary,
    };
    latest.current = next;
    setStats(next);
    AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(next)).catch(() => undefined);
  }, []);

  return { stats, recordSession };
}
