import React from 'react';
import {Pressable, ScrollView, StyleSheet, Text, View} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import {AdjustableRow, ToggleRow} from '../components/Controls';
import {colors} from '../config';
import type {AppPreferences, EventKind, MountingMode} from '../types';
import {stepValue} from '../utils/eventLogic';

const speechCategories: Array<{kind: EventKind; label: string}> = [
  {kind: 'person', label: 'People'},
  {kind: 'vehicle', label: 'Vehicles'},
  {kind: 'obstacle', label: 'Obstacles'},
  {kind: 'furniture', label: 'Furniture'},
  {kind: 'device-warning', label: 'Device warnings'},
];

export function SettingsScreen({
  preferences,
  onChange,
  onDone,
}: {
  preferences: AppPreferences;
  onChange: (update: Partial<AppPreferences>) => void;
  onDone: () => void;
}) {
  const toggleSpeechCategory = (kind: EventKind, enabled: boolean) => {
    const next = enabled
      ? [...new Set([...preferences.spokenCategories, kind])]
      : preferences.spokenCategories.filter(category => category !== kind);
    onChange({spokenCategories: next});
  };

  return (
    <SafeAreaView style={styles.safeArea}>
      <View style={styles.header}>
        <Text accessibilityRole="header" style={styles.title}>Settings</Text>
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Done with settings"
          onPress={onDone}
          style={styles.doneButton}>
          <Text style={styles.doneText}>Done</Text>
        </Pressable>
      </View>
      <ScrollView contentContainerStyle={styles.content}>
        <Section title="Feedback">
          <ToggleRow
            label="Haptics"
            description="Vibration patterns for direction and urgency."
            value={preferences.hapticsEnabled}
            onValueChange={value => onChange({hapticsEnabled: value})}
          />
          <ToggleRow
            label="Directional audio"
            description="Short tones positioned left, center, or right."
            value={preferences.audioEnabled}
            onValueChange={value => onChange({audioEnabled: value})}
          />
          <ToggleRow
            label="Speech"
            description="Brief spoken labels for selected events."
            value={preferences.speechEnabled}
            onValueChange={value => onChange({speechEnabled: value})}
          />
          <AdjustableRow
            label="Haptic strength"
            valueLabel={`${Math.round(preferences.hapticIntensity * 100)} percent`}
            onIncrement={() => onChange({hapticIntensity: stepValue(preferences.hapticIntensity, 'increment', 0.1, 0.1, 1)})}
            onDecrement={() => onChange({hapticIntensity: stepValue(preferences.hapticIntensity, 'decrement', 0.1, 0.1, 1)})}
          />
          <AdjustableRow
            label="Audio volume"
            valueLabel={`${Math.round(preferences.audioVolume * 100)} percent`}
            onIncrement={() => onChange({audioVolume: stepValue(preferences.audioVolume, 'increment', 0.1, 0.1, 1)})}
            onDecrement={() => onChange({audioVolume: stepValue(preferences.audioVolume, 'decrement', 0.1, 0.1, 1)})}
          />
          <AdjustableRow
            label="Cue frequency"
            valueLabel={`${Math.round(preferences.feedbackFrequency * 100)} percent`}
            onIncrement={() => onChange({feedbackFrequency: stepValue(preferences.feedbackFrequency, 'increment', 0.1, 0.1, 1)})}
            onDecrement={() => onChange({feedbackFrequency: stepValue(preferences.feedbackFrequency, 'decrement', 0.1, 0.1, 1)})}
          />
        </Section>

        <Section title="Detection">
          <AdjustableRow
            label="Sensitivity"
            valueLabel={`${Math.round(preferences.sensitivity * 100)} percent`}
            onIncrement={() => onChange({sensitivity: stepValue(preferences.sensitivity, 'increment', 0.05, 0.2, 1)})}
            onDecrement={() => onChange({sensitivity: stepValue(preferences.sensitivity, 'decrement', 0.05, 0.2, 1)})}
          />
          <AdjustableRow
            label="Warning range"
            valueLabel={`${preferences.warningDistanceMeters.toFixed(1)} meters`}
            onIncrement={() => onChange({warningDistanceMeters: stepValue(preferences.warningDistanceMeters, 'increment', 0.5, 1, 12)})}
            onDecrement={() => onChange({warningDistanceMeters: stepValue(preferences.warningDistanceMeters, 'decrement', 0.5, 1, 12)})}
          />
        </Section>

        <Section title="Phone position">
          <MountingChoice mode="handheld" current={preferences.mountingMode} label="In my hand" onPress={() => onChange({mountingMode: 'handheld'})} />
          <MountingChoice mode="chest" current={preferences.mountingMode} label="Chest mounted" onPress={() => onChange({mountingMode: 'chest'})} />
        </Section>

        <Section title="Speak these events">
          {speechCategories.map(category => (
            <ToggleRow
              key={category.kind}
              label={category.label}
              description={`Speak when important ${category.label.toLowerCase()} are detected.`}
              value={preferences.spokenCategories.includes(category.kind)}
              onValueChange={value => toggleSpeechCategory(category.kind, value)}
            />
          ))}
        </Section>

        <Text style={styles.safetyNote}>
          Clear Ahead is experimental and can miss hazards. It does not replace a cane, guide dog, or mobility training.
        </Text>
      </ScrollView>
    </SafeAreaView>
  );
}

function Section({title, children}: {title: string; children: React.ReactNode}) {
  return (
    <View style={styles.section}>
      <Text accessibilityRole="header" style={styles.sectionTitle}>{title}</Text>
      <View style={styles.sectionBody}>{children}</View>
    </View>
  );
}

function MountingChoice({mode, current, label, onPress}: {mode: MountingMode; current: MountingMode; label: string; onPress: () => void}) {
  return (
    <Pressable
      accessibilityRole="radio"
      accessibilityState={{checked: mode === current}}
      onPress={onPress}
      style={styles.mountingChoice}>
      <Text style={styles.mountingLabel}>{label}</Text>
      <Text style={styles.mountingValue}>{mode === current ? 'Selected' : 'Select'}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  safeArea: {flex: 1, backgroundColor: colors.night},
  header: {paddingHorizontal: 22, paddingVertical: 16, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between'},
  title: {color: colors.text, fontSize: 34, fontWeight: '800'},
  doneButton: {minWidth: 60, minHeight: 48, alignItems: 'flex-end', justifyContent: 'center'},
  doneText: {color: colors.cyan, fontSize: 18, fontWeight: '800'},
  content: {paddingHorizontal: 22, paddingBottom: 44, gap: 28},
  section: {gap: 10},
  sectionTitle: {color: colors.muted, fontSize: 12, fontWeight: '900', letterSpacing: 1.6, textTransform: 'uppercase'},
  sectionBody: {backgroundColor: colors.surface, borderRadius: 20, paddingHorizontal: 18, overflow: 'hidden'},
  mountingChoice: {minHeight: 64, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.line},
  mountingLabel: {color: colors.text, fontSize: 18, fontWeight: '700'},
  mountingValue: {color: colors.cyan, fontSize: 15, fontWeight: '700'},
  safetyNote: {color: colors.muted, fontSize: 15, lineHeight: 22},
});
