import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  Animated,
  Easing,
  StatusBar,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { useCameraPermission } from 'react-native-vision-camera';
import { BrandLogo } from './src/components/BrandLogo';
import { LoadingBar } from './src/components/LoadingBar';
import { PrimaryButton } from './src/components/Controls';
import { ClearAheadModule } from './src/native/ClearAheadModule';
import {
  colors,
  hasFeedbackChannel,
} from './src/config';
import { usePreferences } from './src/hooks/usePreferences';
import { useSessionStats } from './src/hooks/useSessionStats';
import { useReducedMotion } from './src/hooks/useReducedMotion';
import { HomeScreen } from './src/screens/HomeScreen';
import { OnboardingScreen } from './src/screens/OnboardingScreen';
import { SettingsScreen } from './src/screens/SettingsScreen';
import type { PipelineMetrics } from './src/types';

type Route =
  | { name: 'home' }
  | { name: 'settings' }
  | { name: 'assist' };

export default function App() {
  const { preferences, setPreferences, isHydrated, storageError } =
    usePreferences();
  const { stats, recordSession } = useSessionStats();
  const cameraPermission = useCameraPermission();
  const [route, setRoute] = useState<Route>({ name: 'home' });
  const [lastMetrics, setLastMetrics] = useState<PipelineMetrics>();
  const [modelsReady, setModelsReady] = useState(false);
  const [loadProgress, setLoadProgress] = useState(0);
  const [loadMessage, setLoadMessage] = useState('Loading settings');
  const [loadError, setLoadError] = useState<string>();
  const [AssistScreen, setAssistScreen] =
    useState<typeof import('./src/screens/AssistScreen').AssistScreen>();
  useEffect(() => {
    if (!isHydrated) return;
    let active = true;
    setModelsReady(false);
    setLoadError(undefined);
    setLoadProgress(0.01);
    setLoadMessage('Preparing on-device models');
    const subscription = ClearAheadModule.onModelDownload(payload => {
      if (active && payload.modelVariant === preferences.modelVariant) {
        setLoadProgress(current => Math.max(current, 0.01 + payload.progress * 0.99));
        setLoadMessage(payload.message);
      }
    });
    ClearAheadModule.prepareModels(preferences.modelVariant)
      .then(() => { if (active) { setLoadProgress(1); setModelsReady(true); } })
      .catch(error => { if (active) setLoadError(error instanceof Error ? error.message : 'Models could not load'); });
    return () => {
      active = false;
      subscription?.remove();
      ClearAheadModule.cancelModelPreparation().catch(() => undefined);
    };
  }, [isHydrated, preferences.modelVariant]);
  const canStartAssist =
    cameraPermission.hasPermission && hasFeedbackChannel(preferences);
  const reduceMotion = useReducedMotion();
  const routeProgress = useRef(new Animated.Value(1)).current;
  useEffect(() => {
    if (reduceMotion) {
      routeProgress.stopAnimation();
      routeProgress.setValue(1);
    }
  }, [reduceMotion, routeProgress]);

  const navigate = useCallback(
    (nextRoute: Route) => {
      if (nextRoute.name === route.name) {
        return;
      }
      if (reduceMotion) {
        setRoute(nextRoute);
        return;
      }

      routeProgress.stopAnimation();
      Animated.timing(routeProgress, {
        toValue: 0,
        duration: 130,
        easing: Easing.in(Easing.cubic),
        useNativeDriver: true,
      }).start(({ finished }) => {
        if (!finished) {
          return;
        }
        setRoute(nextRoute);
        routeProgress.setValue(0);
        Animated.spring(routeProgress, {
          toValue: 1,
          damping: 17,
          stiffness: 190,
          mass: 0.78,
          useNativeDriver: true,
        }).start();
      });
    },
    [reduceMotion, route.name, routeProgress],
  );

  if (!isHydrated || !modelsReady) {
    return (
      <View style={styles.loading} accessibilityLabel="Loading Clear Ahead">
        <BrandLogo width={112} accessible={false} centered />
        <View style={styles.loadingCopy}>
          <Text style={styles.loadingName}>Clear Ahead</Text>
          <Text style={styles.loadingCaption}>Sound and vibration for the path ahead</Text>
        </View>
        {loadError ? <Text accessibilityRole="alert" style={styles.loadingError}>{loadError}</Text> : null}
        <LoadingBar progress={loadProgress} message={loadMessage} />
        {loadError ? <PrimaryButton label={preferences.onboardingComplete ? 'Open settings' : 'Continue setup'} onPress={() => {
          setModelsReady(true);
          setRoute({ name: 'settings' });
        }} /> : null}
      </View>
    );
  }

  if (!preferences.onboardingComplete) {
    return (
      <SafeAreaProvider>
        <StatusBar barStyle="dark-content" />
        <OnboardingScreen
          mountingMode={preferences.mountingMode}
          hasCameraPermission={cameraPermission.hasPermission}
          canRequestCameraPermission={cameraPermission.canRequestPermission}
          requestCameraPermission={cameraPermission.requestPermission}
          onMountingModeChange={mountingMode =>
            setPreferences({ mountingMode })
          }
          onComplete={() => {
            setPreferences({ onboardingComplete: true });
          }}
        />
      </SafeAreaProvider>
    );
  }

  return (
    <SafeAreaProvider>
      <StatusBar barStyle={route.name === 'assist' ? 'light-content' : 'dark-content'} />
      <Animated.View
        style={[
          styles.screen,
          {
            opacity: routeProgress,
            transform: [
              {
                translateY: routeProgress.interpolate({
                  inputRange: [0, 1],
                  outputRange: [10, 0],
                }),
              },
              {
                scale: routeProgress.interpolate({
                  inputRange: [0, 1],
                  outputRange: [0.99, 1],
                }),
              },
            ],
          },
        ]}
      >
        {route.name === 'home' ? (
          <HomeScreen
            preferences={preferences}
            stats={stats}
            lastMetrics={lastMetrics}
            hasCameraPermission={cameraPermission.hasPermission}
            onStart={() => {
              if (!canStartAssist) return;
              try {
                // Native registration errors must not prevent Home or Settings from opening.
                const screen = require('./src/screens/AssistScreen').AssistScreen as
                  typeof import('./src/screens/AssistScreen').AssistScreen;
                setAssistScreen(() => screen);
                navigate({ name: 'assist' });
              } catch (error) {
                setLoadError(error instanceof Error ? error.message : 'Assist mode could not start');
                setLoadMessage('Assist mode could not start');
                setModelsReady(false);
              }
            }}
            onSettings={() => navigate({ name: 'settings' })}
          />
        ) : null}
        {route.name === 'settings' ? (
          <SettingsScreen
            preferences={preferences}
            storageError={storageError}
            onChange={setPreferences}
            hasCameraPermission={cameraPermission.hasPermission}
            onBack={() => navigate({ name: 'home' })}
          />
        ) : null}
        {route.name === 'assist' && AssistScreen ? (
          <AssistScreen
            preferences={preferences}
            onChange={setPreferences}
            onMetrics={setLastMetrics}
            onSessionEnd={recordSession}
            onStop={() => navigate({ name: 'home' })}
          />
        ) : null}
      </Animated.View>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  loading: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: colors.background,
    paddingHorizontal: 32,
    paddingVertical: 48,
    gap: 28,
  },
  loadingCopy: { alignItems: 'center', gap: 6 },
  loadingName: {
    color: colors.ink,
    fontSize: 28,
    lineHeight: 32,
    fontWeight: '700',
    letterSpacing: -0.6,
    textAlign: 'center',
  },
  loadingCaption: {
    color: colors.muted,
    fontSize: 14,
    lineHeight: 20,
    textAlign: 'center',
  },
  loadingError: {
    color: colors.peachInk,
    fontSize: 14,
    lineHeight: 20,
    fontWeight: '700',
    textAlign: 'center',
  },
});
