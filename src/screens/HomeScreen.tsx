import React from 'react';
import {StyleSheet, Text, View} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import {Settings} from 'lucide-react-native';
import {BrandLogo} from '../components/BrandLogo';
import {SpringPressable} from '../components/Motion';
import {colors, hasFeedbackChannel} from '../config';
import type {AppPreferences, PipelineMetrics} from '../types';

export function HomeScreen({
  preferences,
  lastMetrics,
  hasCameraPermission,
  onStart,
  onSettings,
}: {
  preferences: AppPreferences;
  lastMetrics?: PipelineMetrics;
  hasCameraPermission: boolean;
  onStart: () => void;
  onSettings: () => void;
}) {
  const enabledModes = [preferences.speechEnabled && 'Voice', preferences.audioEnabled && 'Sounds', preferences.hapticsEnabled && 'Vibration'].filter(Boolean);
  const feedbackReady = hasFeedbackChannel(preferences);
  const assistReady = hasCameraPermission && feedbackReady;
  const setupMessage = !hasCameraPermission
    ? 'Camera access is off. Turn it on in iOS Settings.'
    : !feedbackReady
    ? 'Turn on voice, sounds, or vibration in Settings.'
    : undefined;

  return (
    <SafeAreaView style={styles.safeArea}>
      <View style={styles.topBar}>
        <BrandLogo width={40} />
        <SpringPressable
          accessibilityRole="button"
          accessibilityLabel="Settings"
          hitSlop={8}
          onPress={onSettings}
          pressedScale={0.9}
          style={styles.settingsButton}
        >
          <Settings color={colors.ink} size={24} strokeWidth={2} />
        </SpringPressable>
      </View>

      <View style={styles.center}>
        <Text accessibilityRole="header" style={styles.title}>
          Clear Ahead
        </Text>
        <Text style={styles.introduction}>Sound and vibration for the path ahead.</Text>

        <SpringPressable
          accessibilityRole="button"
          accessibilityLabel="Start"
          accessibilityHint="Starts the rear camera and feedback"
          accessibilityState={{disabled: !assistReady}}
          disabled={!assistReady}
          onPress={onStart}
          pressedScale={0.95}
          containerStyle={styles.startContainer}
          style={[styles.startButton, !assistReady && styles.disabled]}
        >
          <Text style={styles.startText}>Start</Text>
        </SpringPressable>

        {setupMessage ? (
          <Text accessibilityRole="alert" style={styles.setupMessage}>
            {setupMessage}
          </Text>
        ) : (
          <Text style={styles.summary}>{enabledModes.join(' · ')}</Text>
        )}
      </View>

      {preferences.showFps && lastMetrics ? (
        <Text style={styles.diagnostics}>
          Last session · {lastMetrics.cameraFps.toFixed(0)} fps · objects {lastMetrics.detectorFps.toFixed(0)} · depth {lastMetrics.depthFps.toFixed(0)}
        </Text>
      ) : null}
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safeArea: {flex: 1, backgroundColor: colors.background},
  topBar: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 20,
    paddingTop: 8,
  },
  settingsButton: {
    width: 48,
    height: 48,
    borderRadius: 24,
    backgroundColor: colors.surfaceRaised,
    alignItems: 'center',
    justifyContent: 'center',
  },
  center: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 28,
    paddingBottom: 40,
  },
  title: {
    color: colors.ink,
    fontSize: 34,
    lineHeight: 40,
    fontWeight: '700',
    letterSpacing: -0.8,
    textAlign: 'center',
  },
  introduction: {
    color: colors.muted,
    fontSize: 17,
    lineHeight: 24,
    marginTop: 8,
    textAlign: 'center',
  },
  startContainer: {marginTop: 44, marginBottom: 28},
  startButton: {
    width: 208,
    height: 208,
    borderRadius: 104,
    backgroundColor: colors.accent,
    borderWidth: 10,
    borderColor: colors.surfaceRaised,
    alignItems: 'center',
    justifyContent: 'center',
  },
  startText: {color: colors.ink, fontSize: 32, fontWeight: '700', letterSpacing: -0.4},
  disabled: {opacity: 0.45},
  summary: {color: colors.muted, fontSize: 15, lineHeight: 21, textAlign: 'center'},
  setupMessage: {
    color: colors.peachInk,
    backgroundColor: colors.peach,
    fontSize: 15,
    lineHeight: 21,
    fontWeight: '600',
    textAlign: 'center',
    paddingHorizontal: 16,
    paddingVertical: 12,
    borderRadius: 16,
    overflow: 'hidden',
  },
  diagnostics: {
    color: colors.muted,
    fontSize: 12,
    textAlign: 'center',
    paddingBottom: 12,
    fontVariant: ['tabular-nums'],
  },
});
