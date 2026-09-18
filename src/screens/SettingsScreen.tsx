import React, {useState} from 'react';
import {Pressable, ScrollView, StyleSheet, Text, View} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import {AdjustableRow, ToggleRow} from '../components/Controls';
import {colors} from '../config';
import type {AppPreferences, EventKind, MountingMode, ProcessingMode} from '../types';
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
  const [openSection, setOpenSection] = useState<string | null>('Performance');
  const sectionProps = (title: string) => ({
    title,
    expanded: openSection === title,
    onToggle: () => setOpenSection(current => current === title ? null : title),
  });

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
        <Section {...sectionProps('Performance')}>
          <Text style={styles.sectionHelp}>
            Choose how often the app checks for nearby objects and depth. The processed rate can be lower than the camera capture rate.
          </Text>
          <ProcessingChoice
            mode="responsive"
            current={preferences.processingMode}
            label="Responsive"
            description="Smaller frames and fewer depth checks. Favors quicker object updates. Generic obstacles may be reported less often."
            onPress={() => onChange({processingMode: 'responsive'})}
          />
          <ProcessingChoice
            mode="detailed"
            current={preferences.processingMode}
            label="Detailed"
            description="Larger frames and more frequent depth checks. May slow updates on older iPhones."
            onPress={() => onChange({processingMode: 'detailed'})}
          />
          <ToggleRow
            label="Show frame rates"
            description="Show processed, object, and depth updates during assist mode and the last reading on Home."
            value={preferences.showFps}
            onValueChange={value => onChange({showFps: value})}
          />
        </Section>

        <Section {...sectionProps('Feedback')}>
          <ToggleRow
            label="Haptics"
            description="Vibration patterns for direction and urgency."
            value={preferences.hapticsEnabled}
            onValueChange={value => onChange({hapticsEnabled: value})}
          />
          <ToggleRow
            label="Directional audio"
            description={
              'Pitch shows distance, pulse speed shows urgency, and stereo position shows direction.'
            }
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

        <Section {...sectionProps('Detection')}>
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

        <Section {...sectionProps('Phone position')}>
          <MountingChoice mode="handheld" current={preferences.mountingMode} label="In my hand" onPress={() => onChange({mountingMode: 'handheld'})} />
          <MountingChoice mode="chest" current={preferences.mountingMode} label="Chest mounted" onPress={() => onChange({mountingMode: 'chest'})} />
        </Section>

        <Section {...sectionProps('Spoken events')}>
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

function Section({title, expanded, onToggle, children}: {title: string; expanded: boolean; onToggle: () => void; children: React.ReactNode}) {
  return (
    <View style={styles.section}>
      <Pressable
        accessibilityRole="button"
        accessibilityLabel={`${title} settings`}
        accessibilityState={{expanded}}
        onPress={onToggle}
        style={styles.sectionHeader}>
        <Text style={styles.sectionTitle}>{title}</Text>
        <Text accessibilityElementsHidden style={styles.sectionIndicator}>
          {expanded ? '−' : '+'}
        </Text>
      </Pressable>
      {expanded ? <View style={styles.sectionBody}>{children}</View> : null}
    </View>
  );
}

function ProcessingChoice({mode, current, label, description, onPress}: {mode: ProcessingMode; current: ProcessingMode; label: string; description: string; onPress: () => void}) {
  return (
    <Pressable
      accessibilityRole="radio"
      accessibilityLabel={`${label}. ${description}`}
      accessibilityState={{checked: mode === current}}
      onPress={onPress}
      style={[styles.processingChoice, mode === current && styles.processingChoiceSelected]}>
      <Text style={styles.mountingLabel}>{label}</Text>
      <Text style={styles.processingDescription}>{description}</Text>
    </Pressable>
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
  section: {gap: 8},
  sectionHeader: {minHeight: 56, paddingHorizontal: 18, borderRadius: 16, backgroundColor: colors.surfaceRaised, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between'},
  sectionTitle: {color: colors.text, fontSize: 18, fontWeight: '800'},
  sectionIndicator: {color: colors.cyan, fontSize: 25, fontWeight: '700'},
  sectionBody: {backgroundColor: colors.surface, borderRadius: 20, paddingHorizontal: 18, overflow: 'hidden'},
  sectionHelp: {color: colors.muted, fontSize: 15, lineHeight: 21, paddingTop: 18, paddingBottom: 8},
  processingChoice: {minHeight: 92, paddingVertical: 14, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: colors.line},
  processingChoiceSelected: {borderLeftWidth: 4, borderLeftColor: colors.cyan, paddingLeft: 12},
  processingDescription: {color: colors.muted, fontSize: 15, lineHeight: 21, marginTop: 4},
  mountingChoice: {minHeight: 64, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.line},
  mountingLabel: {color: colors.text, fontSize: 18, fontWeight: '700'},
  mountingValue: {color: colors.cyan, fontSize: 15, fontWeight: '700'},
  safetyNote: {color: colors.muted, fontSize: 15, lineHeight: 22},
});
