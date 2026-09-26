import AsyncStorage from '@react-native-async-storage/async-storage';
import { useCallback, useEffect, useRef, useState } from 'react';
import { DEFAULT_PREFERENCES, normalizePreferences } from '../config';
import type { AppPreferences } from '../types';
import { createSerializedWriter } from '../utils/preferencePersistence';

const STORAGE_KEY = '@clear-ahead/preferences-v1';

export function usePreferences() {
  const [preferences, setPreferencesState] =
    useState<AppPreferences>(DEFAULT_PREFERENCES);
  const [isHydrated, setIsHydrated] = useState(false);
  const [loadFailed, setLoadFailed] = useState(false);
  const [storageError, setStorageError] = useState<string>();
  const writePreferences = useRef(
    createSerializedWriter((value: string) => AsyncStorage.setItem(STORAGE_KEY, value)),
  ).current;

  useEffect(() => {
    let active = true;
    AsyncStorage.getItem(STORAGE_KEY)
      .then(value => {
        if (!active || !value) {
          return;
        }
        setPreferencesState(normalizePreferences(JSON.parse(value)));
      })
      .catch(() => {
        if (active) {
          setLoadFailed(true);
          setStorageError('Stored settings could not be loaded.');
        }
      })
      .finally(() => active && setIsHydrated(true));
    return () => {
      active = false;
    };
  }, []);

  useEffect(() => {
    if (!isHydrated || loadFailed) return;
    writePreferences(JSON.stringify(preferences))
      .then(() => setStorageError(undefined))
      .catch(() => setStorageError('Settings could not be saved on this device.'));
  }, [isHydrated, loadFailed, preferences, writePreferences]);

  const setPreferences = useCallback(
    (
      update:
        | Partial<AppPreferences>
        | ((current: AppPreferences) => AppPreferences),
    ) => {
      setLoadFailed(false);
      setPreferencesState(current => {
        return (
          typeof update === 'function'
            ? update(current)
            : { ...current, ...update }
        );
      });
    },
    [],
  );

  return { preferences, setPreferences, isHydrated, storageError };
}
