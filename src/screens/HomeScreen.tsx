import React from 'react';
import {StyleSheet, Text, View} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import {Settings} from 'lucide-react-native';
import {BrandLogo} from '../components/BrandLogo';
import {SpringPressable} from '../components/Motion';
import {colors, hasFeedbackChannel} from '../config';
import type {AppPreferences, PipelineMetrics, SessionStats} from '../types';

function formatDuration(seconds: number): string {
  if (seconds < 60) return `${seconds} sec`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min`;
  const hours = seconds / 3600;
  return `${hours < 10 ? hours.toFixed(1) : Math.round(hours)} hr`;
}

function plural(value: number, noun: string): string {
  return `${value} ${noun}${value === 1 ? '' : 's'}`;
}

export function HomeScreen({
  preferences,
  stats,
  lastMetrics,
  hasCameraPermission,
  onStart,
  onSettings,
}: {
  preferences: AppPreferences;
  stats: SessionStats;
  lastMetrics?: PipelineMetrics;
  hasCameraPermission: boolean;
  onStart: () => void;
  onSettings: () => void;
}) {
  const feedbackReady = hasFeedbackChannel(preferences);
  const assistReady = hasCameraPermission && feedbackReady;
  const setupMessage = !hasCameraPermission
    ? 'Camera access is off. Turn it on in iOS Settings.'
    : !feedbackReady
    ? 'Turn on voice, sounds, or vibration in Settings.'
    : undefined;
  const tiles = [
    {label: 'Walks', value: String(stats.walks)},
    {label: 'Time guided', value: formatDuration(stats.totalSeconds)},
    {label: 'Alerts', value: String(stats.alerts)},
  ];
  const lastWalk = stats.last
    ? `Last walk · ${formatDuration(stats.last.durationSeconds)} · ${plural(stats.last.alerts, 'alert')}`
    : 'Your walks will show up here';

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
        <Text
          accessibilityRole="header"
          adjustsFontSizeToFit
          numberOfLines={1}
          style={styles.title}
        >
          Clear Ahead
        </Text>

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
        ) : null}
      </View>

      <View
        accessible
        accessibilityLabel={`${plural(stats.walks, 'walk')}, ${formatDuration(stats.totalSeconds)} guided, ${plural(stats.alerts, 'alert')}. ${lastWalk}`}
        style={styles.statsBox}
      >
        <View style={styles.statsRow}>
          {tiles.map(tile => (
            <View key={tile.label} style={styles.statTile}>
              <Text style={styles.statValue} numberOfLines={1} adjustsFontSizeToFit>
                {tile.value}
              </Text>
              <Text style={styles.statLabel} numberOfLines={1}>
                {tile.label}
              </Text>
            </View>
          ))}
        </View>
        <Text style={styles.lastWalk}>{lastWalk}</Text>
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
    paddingBottom: 16,
  },
  title: {
    color: colors.ink,
    fontSize: 48,
    lineHeight: 54,
    fontWeight: '700',
    letterSpacing: -1.4,
    textAlign: 'center',
  },
  startContainer: {marginTop: 44, marginBottom: 28},
  startButton: {
    width: 220,
    height: 220,
    borderRadius: 110,
    backgroundColor: colors.accent,
    borderWidth: 10,
    borderColor: colors.surfaceRaised,
    alignItems: 'center',
    justifyContent: 'center',
  },
  startText: {color: colors.ink, fontSize: 32, fontWeight: '700', letterSpacing: -0.4},
  disabled: {opacity: 0.45},
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
  statsBox: {
    marginHorizontal: 20,
    marginBottom: 16,
    padding: 16,
    borderRadius: 28,
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.line,
    gap: 14,
  },
  statsRow: {flexDirection: 'row', gap: 10},
  statTile: {
    flex: 1,
    alignItems: 'center',
    paddingVertical: 14,
    paddingHorizontal: 6,
    borderRadius: 18,
    backgroundColor: colors.surfaceRaised,
    gap: 2,
  },
  statValue: {
    color: colors.ink,
    fontSize: 24,
    lineHeight: 30,
    fontWeight: '700',
    letterSpacing: -0.4,
    fontVariant: ['tabular-nums'],
  },
  statLabel: {color: colors.muted, fontSize: 13, fontWeight: '600'},
  lastWalk: {
    color: colors.muted,
    fontSize: 14,
    lineHeight: 20,
    fontWeight: '500',
    textAlign: 'center',
  },
  diagnostics: {
    color: colors.muted,
    fontSize: 12,
    textAlign: 'center',
    paddingBottom: 12,
    fontVariant: ['tabular-nums'],
  },
});
