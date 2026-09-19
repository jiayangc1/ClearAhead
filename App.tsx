import React, {useState} from 'react';
import {ActivityIndicator, StatusBar, StyleSheet, View} from 'react-native';
import {SafeAreaProvider} from 'react-native-safe-area-context';
import {useCameraPermission} from 'react-native-vision-camera';
import {BrandLogo} from './src/components/BrandLogo';
import {colors, toFeedbackConfiguration} from './src/config';
import {usePreferences} from './src/hooks/usePreferences';
import {ClearAheadModule} from './src/native/ClearAheadModule';
import {AssistScreen} from './src/screens/AssistScreen';
import {HomeScreen} from './src/screens/HomeScreen';
import {OnboardingScreen} from './src/screens/OnboardingScreen';
import {SettingsScreen} from './src/screens/SettingsScreen';
import type {DemoScenario, PipelineMetrics} from './src/types';

type Route =
  | {name: 'home'}
  | {name: 'settings'}
  | {name: 'assist'; demoScenario?: DemoScenario};

export default function App() {
  const {preferences, setPreferences, isHydrated} = usePreferences();
  const cameraPermission = useCameraPermission();
  const [route, setRoute] = useState<Route>({name: 'home'});
  const [lastMetrics, setLastMetrics] = useState<PipelineMetrics>();

  if (!isHydrated) {
    return (
      <View style={styles.loading} accessibilityLabel="Loading Clear Ahead">
        <BrandLogo width={112} accessible={false} />
        <ActivityIndicator size="large" color={colors.cyan} />
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
            await ClearAheadModule.updateConfiguration(
              toFeedbackConfiguration(preferences),
            );
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
      {route.name === 'home' ? (
        <HomeScreen
          preferences={preferences}
          lastMetrics={lastMetrics}
          hasCameraPermission={cameraPermission.hasPermission}
          onStart={() => setRoute({name: 'assist'})}
          onDemo={() =>
            setRoute({name: 'assist', demoScenario: 'crossing-person'})
          }
          onSettings={() => setRoute({name: 'settings'})}
          onHome={() => setRoute({name: 'home'})}
        />
      ) : null}
      {route.name === 'settings' ? (
        <SettingsScreen
          preferences={preferences}
          onChange={setPreferences}
          hasCameraPermission={cameraPermission.hasPermission}
          onHome={() => setRoute({name: 'home'})}
          onAssist={() => setRoute({name: 'assist'})}
          onSettings={() => setRoute({name: 'settings'})}
        />
      ) : null}
      {route.name === 'assist' ? (
        <AssistScreen
          preferences={preferences}
          demoScenario={route.demoScenario}
          onMetrics={setLastMetrics}
          onStop={() => setRoute({name: 'home'})}
        />
      ) : null}
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  loading: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: colors.night,
    gap: 24,
  },
});
