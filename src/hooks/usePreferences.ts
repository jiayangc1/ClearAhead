import AsyncStorage from '@react-native-async-storage/async-storage';
import {useCallback, useEffect, useState} from 'react';
import {DEFAULT_PREFERENCES} from '../config';
import type {AppPreferences} from '../types';

const STORAGE_KEY = '@clear-ahead/preferences-v1';

export function usePreferences() {
  const [preferences, setPreferencesState] =
    useState<AppPreferences>(DEFAULT_PREFERENCES);
  const [isHydrated, setIsHydrated] = useState(false);

  useEffect(() => {
    let active = true;
    AsyncStorage.getItem(STORAGE_KEY)
      .then(value => {
        if (!active || !value) {
          return;
        }
        const parsed = JSON.parse(value) as Partial<AppPreferences>;
        setPreferencesState({...DEFAULT_PREFERENCES, ...parsed, version: 1});
      })
      .catch(() => undefined)
      .finally(() => active && setIsHydrated(true));
    return () => {
      active = false;
    };
  }, []);

  const setPreferences = useCallback(
    (
      update:
        | Partial<AppPreferences>
        | ((current: AppPreferences) => AppPreferences),
    ) => {
      setPreferencesState(current => {
        const next =
          typeof update === 'function'
            ? update(current)
            : {...current, ...update};
        AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(next)).catch(
          () => undefined,
        );
        return next;
      });
    },
    [],
  );

  return {preferences, setPreferences, isHydrated};
}
