import React from 'react';
import {Pressable, StyleSheet, Text, View} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import {PrimaryButton} from '../components/Controls';
import {colors} from '../config';
import type {AppPreferences} from '../types';

export function HomeScreen({
  preferences,
  hasCameraPermission,
  onStart,
  onDemo,
  onSettings,
}: {
  preferences: AppPreferences;
  hasCameraPermission: boolean;
  onStart: () => void;
  onDemo: () => void;
  onSettings: () => void;
}) {
  const enabledModes = [
    preferences.hapticsEnabled && 'Haptics',
    preferences.audioEnabled && 'Audio',
    preferences.speechEnabled && 'Speech',
  ].filter(Boolean);

  return (
    <SafeAreaView style={styles.safeArea}>
      <View style={styles.header}>
        <View style={styles.headerCopy}>
          <Text style={styles.eyebrow}>CLEAR AHEAD</Text>
          <Text accessibilityRole="header" style={styles.title}>
            Ready when you are.
          </Text>
        </View>
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Open settings"
          onPress={onSettings}
          hitSlop={10}
          style={styles.settingsButton}>
          <Text accessibilityElementsHidden style={styles.settingsIcon}>
            {'\u2699\uFE0E'}
          </Text>
        </Pressable>
      </View>

      <View style={styles.field} accessible accessibilityLabel="Clear Ahead is idle">
        <View style={styles.arcOuter} />
        <View style={styles.arcMiddle} />
        <View style={styles.arcInner} />
        <View style={styles.centerMark} />
        <Text style={styles.idleLabel}>IDLE</Text>
      </View>

      <View style={styles.statusCard}>
        <View>
          <Text style={styles.statusLabel}>FEEDBACK</Text>
          <Text style={styles.statusValue}>
            {enabledModes.length ? enabledModes.join(' · ') : 'All feedback off'}
          </Text>
        </View>
        <View>
          <Text style={styles.statusLabel}>PHONE</Text>
          <Text style={styles.statusValue}>
            {preferences.mountingMode === 'handheld' ? 'In hand' : 'Chest mounted'}
          </Text>
        </View>
      </View>

      <View style={styles.actions}>
        {!hasCameraPermission ? (
          <Text accessibilityRole="alert" style={styles.cameraWarning}>
            Camera access is not enabled. Use demo mode or enable Camera in iOS Settings.
          </Text>
        ) : null}
        <PrimaryButton
          label="Start assist mode"
          hint="Starts the rear camera and environmental feedback"
          onPress={onStart}
          disabled={!hasCameraPermission}
        />
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Try a safe demo"
          accessibilityHint="Runs a seated simulation without the camera"
          onPress={onDemo}
          style={({pressed}) => [styles.demoButton, pressed && {opacity: 0.72}]}>
          <Text style={styles.demoText}>Try a safe demo</Text>
        </Pressable>
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safeArea: {flex: 1, backgroundColor: colors.night, paddingHorizontal: 22},
  header: {paddingTop: 18, position: 'relative'},
  headerCopy: {minWidth: 0},
  eyebrow: {color: colors.cyan, fontSize: 12, fontWeight: '900', letterSpacing: 2},
  title: {color: colors.text, fontSize: 31, lineHeight: 37, fontWeight: '800', marginTop: 5},
  settingsButton: {
    width: 44,
    height: 44,
    position: 'absolute',
    top: 18,
    right: 0,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 22,
    borderWidth: 1,
    borderColor: colors.line,
    backgroundColor: colors.surface,
  },
  settingsIcon: {color: colors.cyan, fontSize: 23, lineHeight: 25},
  field: {flex: 1, minHeight: 260, alignItems: 'center', justifyContent: 'center', overflow: 'hidden'},
  arcOuter: {position: 'absolute', width: 350, height: 350, borderRadius: 175, borderWidth: 1, borderColor: '#55D6FF22'},
  arcMiddle: {position: 'absolute', width: 240, height: 240, borderRadius: 120, borderWidth: 1, borderColor: '#55D6FF44'},
  arcInner: {position: 'absolute', width: 130, height: 130, borderRadius: 65, borderWidth: 2, borderColor: '#55D6FF88'},
  centerMark: {width: 18, height: 18, borderRadius: 9, backgroundColor: colors.cyan},
  idleLabel: {color: colors.text, marginTop: 34, fontSize: 12, fontWeight: '900', letterSpacing: 2},
  statusCard: {backgroundColor: colors.surface, borderRadius: 20, padding: 20, flexDirection: 'row', justifyContent: 'space-between', gap: 20},
  statusLabel: {color: colors.muted, fontSize: 11, fontWeight: '800', letterSpacing: 1.4},
  statusValue: {color: colors.text, fontSize: 16, fontWeight: '700', marginTop: 5},
  actions: {paddingVertical: 20, gap: 12},
  cameraWarning: {color: colors.amber, fontSize: 15, lineHeight: 21},
  demoButton: {minHeight: 52, alignItems: 'center', justifyContent: 'center'},
  demoText: {color: colors.cyan, fontSize: 17, fontWeight: '700'},
});
