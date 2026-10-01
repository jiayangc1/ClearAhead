import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  Animated,
  AppState,
  Easing,
  StatusBar,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { useCameraPermission } from 'react-native-vision-camera';
import { BrandLogo } from './src/components/BrandLogo';
import {
  colors,
  hasFeedbackChannel,
  toFeedbackConfiguration,
} from './src/config';
import { usePreferences } from './src/hooks/usePreferences';
import { useReducedMotion } from './src/hooks/useReducedMotion';
import { ClearAheadModule } from './src/native/ClearAheadModule';
import { AssistScreen } from './src/screens/AssistScreen';
import { HomeScreen } from './src/screens/HomeScreen';
import { OnboardingScreen } from './src/screens/OnboardingScreen';
import { SettingsScreen } from './src/screens/SettingsScreen';
import type { DemoScenario, PipelineMetrics } from './src/types';
import {
  SessionController,
  runFeedbackTest,
} from './src/utils/sessionController';

type Route =
  | { name: 'home' }
  | { name: 'settings' }
  | { name: 'assist'; demoScenario?: DemoScenario };

export default function App() {
  const { preferences, setPreferences, isHydrated, storageError } =
    usePreferences();
  const cameraPermission = useCameraPermission();
  const [route, setRoute] = useState<Route>({ name: 'home' });
  const [lastMetrics, setLastMetrics] = useState<PipelineMetrics>();
  const canStartAssist =
    cameraPermission.hasPermission && hasFeedbackChannel(preferences);
  const reduceMotion = useReducedMotion();
  const routeProgress = useRef(new Animated.Value(1)).current;
  const feedbackTest = useRef<AbortController | undefined>(undefined);
  useEffect(() => () => feedbackTest.current?.abort(), []);
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

  if (!isHydrated) {
    return (
      <View style={styles.loading} accessibilityLabel="Loading Clear Ahead">
        <BrandLogo width={112} accessible={false} />
        <Text style={styles.loadingText}>Loading Clear Ahead</Text>
      </View>
    );
  }

  if (!preferences.onboardingComplete) {
    return (
      <SafeAreaProvider>
        <StatusBar barStyle="light-content" />
        <OnboardingScreen
          mountingMode={preferences.mountingMode}
          hasCameraPermission={cameraPermission.hasPermission}
          canRequestCameraPermission={cameraPermission.canRequestPermission}
          requestCameraPermission={cameraPermission.requestPermission}
          onMountingModeChange={mountingMode =>
            setPreferences({ mountingMode })
          }
          onTestFeedback={async () => {
            if (AppState.currentState !== 'active') {
              throw new Error('Return to the app to test feedback.');
            }
            feedbackTest.current?.abort();
            const abort = new AbortController();
            feedbackTest.current = abort;
            const session = new SessionController(
              () =>
                ClearAheadModule.updateConfiguration(
                  toFeedbackConfiguration(preferences),
                ),
              () => ClearAheadModule.startDemo('crossing-person'),
              () => ClearAheadModule.stopDemo(),
            );
            const subscription = AppState.addEventListener('change', state => {
              if (state !== 'active') {
                abort.abort();
              }
            });
            try {
              await runFeedbackTest(session, abort.signal);
            } finally {
              subscription.remove();
            }
          }}
          onComplete={() => {
            feedbackTest.current?.abort();
            setPreferences({ onboardingComplete: true });
          }}
        />
      </SafeAreaProvider>
    );
  }

  return (
    <SafeAreaProvider>
      <StatusBar barStyle="light-content" />
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
            lastMetrics={lastMetrics}
            hasCameraPermission={cameraPermission.hasPermission}
            onStart={() => {
              if (canStartAssist) navigate({ name: 'assist' });
            }}
            onDemo={() => {
              if (hasFeedbackChannel(preferences))
                navigate({ name: 'assist', demoScenario: 'crossing-person' });
            }}
            onSettings={() => navigate({ name: 'settings' })}
            onHome={() => navigate({ name: 'home' })}
          />
        ) : null}
        {route.name === 'settings' ? (
          <SettingsScreen
            preferences={preferences}
            storageError={storageError}
            onChange={setPreferences}
            hasCameraPermission={cameraPermission.hasPermission}
            onHome={() => navigate({ name: 'home' })}
            onAssist={() => {
              if (canStartAssist) navigate({ name: 'assist' });
            }}
            onSettings={() => navigate({ name: 'settings' })}
          />
        ) : null}
        {route.name === 'assist' ? (
          <AssistScreen
            preferences={preferences}
            demoScenario={route.demoScenario}
            onMetrics={setLastMetrics}
            onStop={() => navigate({ name: 'home' })}
          />
        ) : null}
      </Animated.View>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.night },
  loading: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: colors.night,
    gap: 24,
  },
  loadingText: { color: colors.muted, fontSize: 16, fontWeight: '700' },
});
