import React, {useCallback, useRef, useState} from 'react';
import {Animated, Easing, StatusBar, StyleSheet, Text, View} from 'react-native';
import {SafeAreaProvider} from 'react-native-safe-area-context';
import {useCameraPermission} from 'react-native-vision-camera';
import {BrandLogo} from './src/components/BrandLogo';
import {colors, toFeedbackConfiguration} from './src/config';
import {usePreferences} from './src/hooks/usePreferences';
import {useReducedMotion} from './src/hooks/useReducedMotion';
import {ClearAheadModule} from './src/native/ClearAheadModule';
import {AssistScreen} from './src/screens/AssistScreen';
import {HomeScreen} from './src/screens/HomeScreen';
import {OnboardingScreen} from './src/screens/OnboardingScreen';
import {SettingsScreen} from './src/screens/SettingsScreen';
import type {DemoScenario, PipelineMetrics} from './src/types';

type Route = {name: 'home'} | {name: 'settings'} | {name: 'assist'; demoScenario?: DemoScenario};

export default function App() {
  const {preferences, setPreferences, isHydrated} = usePreferences();
  const cameraPermission = useCameraPermission();
  const [route, setRoute] = useState<Route>({name: 'home'});
  const [lastMetrics, setLastMetrics] = useState<PipelineMetrics>();
  const reduceMotion = useReducedMotion();
  const routeProgress = useRef(new Animated.Value(1)).current;

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
      }).start(({finished}) => {
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
          onMountingModeChange={mountingMode => setPreferences({mountingMode})}
          onTestFeedback={async () => {
            await ClearAheadModule.updateConfiguration(toFeedbackConfiguration(preferences));
            await ClearAheadModule.startDemo('crossing-person');
            await new Promise(resolve => setTimeout(resolve, 2200));
            await ClearAheadModule.stopDemo();
          }}
          onComplete={() => setPreferences({onboardingComplete: true})}
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
            onStart={() => navigate({name: 'assist'})}
            onDemo={() => navigate({name: 'assist', demoScenario: 'crossing-person'})}
            onSettings={() => navigate({name: 'settings'})}
            onHome={() => navigate({name: 'home'})}
          />
        ) : null}
        {route.name === 'settings' ? (
          <SettingsScreen
            preferences={preferences}
            onChange={setPreferences}
            hasCameraPermission={cameraPermission.hasPermission}
            onHome={() => navigate({name: 'home'})}
            onAssist={() => navigate({name: 'assist'})}
            onSettings={() => navigate({name: 'settings'})}
          />
        ) : null}
        {route.name === 'assist' ? <AssistScreen preferences={preferences} demoScenario={route.demoScenario} onMetrics={setLastMetrics} onStop={() => navigate({name: 'home'})} /> : null}
      </Animated.View>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  screen: {flex: 1, backgroundColor: colors.night},
  loading: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: colors.night,
    gap: 24,
  },
  loadingText: {color: colors.muted, fontSize: 16, fontWeight: '700'},
});
