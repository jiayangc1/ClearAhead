import React from 'react';
import {ScrollView, StyleSheet, Text, View} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import {BrandLogo} from '../components/BrandLogo';
import {BottomNavigation} from '../components/BottomNavigation';
import {PrimaryButton} from '../components/Controls';
import {Entrance, Pulse, SpringPressable} from '../components/Motion';
import {colors} from '../config';
import type {AppPreferences, PipelineMetrics} from '../types';

export function HomeScreen({
  preferences,
  lastMetrics,
  hasCameraPermission,
  onStart,
  onDemo,
  onSettings,
  onHome,
}: {
  preferences: AppPreferences;
  lastMetrics?: PipelineMetrics;
  hasCameraPermission: boolean;
  onStart: () => void;
  onDemo: () => void;
  onSettings: () => void;
  onHome: () => void;
}) {
  const enabledModes = [preferences.hapticsEnabled && 'Haptics', preferences.audioEnabled && 'Audio', preferences.speechEnabled && 'Speech'].filter(Boolean);

  return (
    <SafeAreaView style={styles.safeArea}>
      <View pointerEvents="none" accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={styles.ambientField}>
        <Pulse minScale={0.72} duration={2200} style={styles.ambientPulse}>
          <View style={styles.ambientRingOuter} />
        </Pulse>
        <Pulse minScale={0.86} duration={1700} style={styles.ambientPulseInner}>
          <View style={styles.ambientRingInner} />
        </Pulse>
      </View>
      <ScrollView contentContainerStyle={styles.content}>
        <Entrance delay={40} distance={12} scaleFrom={0.93} style={styles.header}>
          <View style={styles.logoStage}>
            <BrandLogo width={104} />
          </View>
          <Text accessibilityRole="header" style={styles.title}>
            Move with more confidence.
          </Text>
          <Text style={styles.introduction}>Clear Ahead uses sound and vibration to call out nearby obstacles.</Text>
        </Entrance>

        <Entrance delay={150} style={styles.startPanel}>
          <View style={styles.readyRow} accessible accessibilityLabel="Ready to assist">
            <Pulse minScale={0.55} duration={900}>
              <View style={styles.readyMark} />
            </Pulse>
            <Text style={styles.readyText}>Ready to assist</Text>
          </View>
          {!hasCameraPermission ? (
            <Text accessibilityRole="alert" style={styles.cameraWarning}>
              Camera access is off. Enable Camera in iOS Settings or try the safe demo.
            </Text>
          ) : null}
          <PrimaryButton label="Start Assist Mode" hint="Starts the rear camera and environmental feedback" onPress={onStart} disabled={!hasCameraPermission} />
        </Entrance>

        <Entrance delay={250} style={styles.statusCard}>
          <View accessibilityLabel="Current setup" style={styles.statusCardContent}>
            <Text style={styles.sectionLabel}>CURRENT SETUP</Text>
            <View style={styles.statusItem}>
              <Text style={styles.statusLabel}>Feedback</Text>
              <Text style={styles.statusValue}>{enabledModes.length ? enabledModes.join(' · ') : 'All feedback off'}</Text>
            </View>
            <View style={styles.statusItem}>
              <Text style={styles.statusLabel}>Phone position</Text>
              <Text style={styles.statusValue}>{preferences.mountingMode === 'handheld' ? 'In hand' : 'Chest mounted'}</Text>
            </View>
            {preferences.showFps ? (
              <View style={styles.statusItem}>
                <Text style={styles.statusLabel}>Last session</Text>
                <Text style={styles.statusValue}>
                  {lastMetrics
                    ? `Processed ${lastMetrics.cameraFps.toFixed(1)} fps · Objects ${lastMetrics.detectorFps.toFixed(1)} · Depth ${lastMetrics.depthFps.toFixed(1)}`
                    : 'No frame rate recorded yet'}
                </Text>
              </View>
            ) : null}
          </View>
        </Entrance>

        <Entrance delay={340} style={styles.actions}>
          <SpringPressable
            accessibilityRole="button"
            accessibilityLabel="Try a safe demo"
            accessibilityHint="Runs a seated simulation without the camera"
            onPress={onDemo}
            pressedScale={0.95}
            style={styles.demoButton}
          >
            <Text style={styles.demoText}>Try a safe demo</Text>
          </SpringPressable>
        </Entrance>
      </ScrollView>
      <BottomNavigation active="home" onHome={onHome} onAssist={onStart} onSettings={onSettings} assistDisabled={!hasCameraPermission} />
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safeArea: {flex: 1, backgroundColor: colors.night},
  ambientField: {
    position: 'absolute',
    top: 5,
    left: 0,
    right: 0,
    height: 250,
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
  ambientPulse: {position: 'absolute'},
  ambientPulseInner: {position: 'absolute'},
  ambientRingOuter: {
    width: 240,
    height: 240,
    borderRadius: 120,
    borderWidth: 1,
    borderColor: '#3291FF24',
  },
  ambientRingInner: {
    width: 168,
    height: 168,
    borderRadius: 84,
    borderWidth: 1,
    borderColor: '#3291FF38',
  },
  content: {
    flexGrow: 1,
    paddingHorizontal: 20,
    paddingTop: 28,
    paddingBottom: 22,
  },
  header: {alignItems: 'center', marginBottom: 32},
  logoStage: {
    width: 104,
    height: 104,
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: 12,
  },
  title: {
    color: colors.text,
    fontSize: 36,
    lineHeight: 41,
    fontWeight: '800',
    letterSpacing: -1.2,
    marginTop: 12,
    maxWidth: 330,
    textAlign: 'center',
  },
  introduction: {
    color: colors.muted,
    fontSize: 17,
    lineHeight: 25,
    marginTop: 12,
    maxWidth: 350,
    textAlign: 'center',
  },
  startPanel: {
    backgroundColor: '#111111F2',
    borderColor: colors.line,
    borderWidth: 1,
    borderRadius: 12,
    padding: 16,
    gap: 16,
  },
  readyRow: {flexDirection: 'row', alignItems: 'center', gap: 9},
  readyMark: {
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: colors.cyan,
  },
  readyText: {color: colors.text, fontSize: 15, fontWeight: '700'},
  statusCard: {
    marginTop: 24,
    borderTopWidth: 1,
    borderTopColor: colors.line,
    paddingTop: 20,
  },
  statusCardContent: {gap: 16},
  sectionLabel: {
    color: colors.muted,
    fontSize: 11,
    fontWeight: '800',
    letterSpacing: 1.5,
  },
  statusItem: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    justifyContent: 'space-between',
    gap: 16,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.line,
    paddingBottom: 15,
  },
  statusLabel: {color: colors.muted, fontSize: 15, fontWeight: '600'},
  statusValue: {
    color: colors.text,
    fontSize: 15,
    lineHeight: 21,
    fontWeight: '600',
    textAlign: 'right',
    flex: 1,
  },
  actions: {paddingTop: 10},
  cameraWarning: {color: colors.amber, fontSize: 15, lineHeight: 21},
  demoButton: {minHeight: 50, alignItems: 'center', justifyContent: 'center'},
  demoText: {color: colors.muted, fontSize: 15, fontWeight: '700'},
});
