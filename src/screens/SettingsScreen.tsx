import React, {useEffect, useRef, useState} from 'react';
import {Animated, Easing, ScrollView, StyleSheet, Text, View} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import {ChevronDown} from 'lucide-react-native';
import {BrandLogo} from '../components/BrandLogo';
import {BottomNavigation} from '../components/BottomNavigation';
import {AdjustableRow, ToggleRow} from '../components/Controls';
import {motion, SpringPressable} from '../components/Motion';
import {colors} from '../config';
import {useReducedMotion} from '../hooks/useReducedMotion';
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
  onHome,
  onAssist,
  onSettings,
  hasCameraPermission,
}: {
  preferences: AppPreferences;
  onChange: (update: Partial<AppPreferences>) => void;
  onHome: () => void;
  onAssist: () => void;
  onSettings: () => void;
  hasCameraPermission: boolean;
}) {
  const [openSection, setOpenSection] = useState<string | null>('Performance');
  const sectionProps = (title: string) => ({
    title,
    expanded: openSection === title,
    onToggle: () => setOpenSection(current => (current === title ? null : title)),
  });

  const toggleSpeechCategory = (kind: EventKind, enabled: boolean) => {
    const next = enabled ? [...new Set([...preferences.spokenCategories, kind])] : preferences.spokenCategories.filter(category => category !== kind);
    onChange({spokenCategories: next});
  };

  return (
    <SafeAreaView style={styles.safeArea}>
      <View style={styles.header}>
        <BrandLogo width={64} />
        <Text accessibilityRole="header" style={styles.title}>
          Settings
        </Text>
        <Text style={styles.subtitle}>Tune feedback and detection for the way you move.</Text>
      </View>
      <ScrollView contentContainerStyle={styles.content}>
        <Section {...sectionProps('Performance')}>
          <Text style={styles.sectionHelp}>Choose how often the app checks for nearby objects and depth. The processed rate can be lower than the camera capture rate.</Text>
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
          <ToggleRow label="Haptics" description="Vibration patterns for direction and urgency." value={preferences.hapticsEnabled} onValueChange={value => onChange({hapticsEnabled: value})} />
          <ToggleRow
            label="Directional audio"
            description={'Pitch shows distance, pulse speed shows urgency, and stereo position shows direction.'}
            value={preferences.audioEnabled}
            onValueChange={value => onChange({audioEnabled: value})}
          />
          <ToggleRow label="Speech" description="Brief spoken labels for selected events." value={preferences.speechEnabled} onValueChange={value => onChange({speechEnabled: value})} />
          <AdjustableRow
            label="Haptic strength"
            valueLabel={`${Math.round(preferences.hapticIntensity * 100)} percent`}
            onIncrement={() =>
              onChange({
                hapticIntensity: stepValue(preferences.hapticIntensity, 'increment', 0.1, 0.1, 1),
              })
            }
            onDecrement={() =>
              onChange({
                hapticIntensity: stepValue(preferences.hapticIntensity, 'decrement', 0.1, 0.1, 1),
              })
            }
          />
          <AdjustableRow
            label="Audio volume"
            valueLabel={`${Math.round(preferences.audioVolume * 100)} percent`}
            onIncrement={() =>
              onChange({
                audioVolume: stepValue(preferences.audioVolume, 'increment', 0.1, 0.1, 1),
              })
            }
            onDecrement={() =>
              onChange({
                audioVolume: stepValue(preferences.audioVolume, 'decrement', 0.1, 0.1, 1),
              })
            }
          />
          <AdjustableRow
            label="Cue frequency"
            valueLabel={`${Math.round(preferences.feedbackFrequency * 100)} percent`}
            onIncrement={() =>
              onChange({
                feedbackFrequency: stepValue(preferences.feedbackFrequency, 'increment', 0.1, 0.1, 1),
              })
            }
            onDecrement={() =>
              onChange({
                feedbackFrequency: stepValue(preferences.feedbackFrequency, 'decrement', 0.1, 0.1, 1),
              })
            }
          />
        </Section>

        <Section {...sectionProps('Detection')}>
          <Text style={styles.sectionHelp}>
            Collision warnings combine several frames of relative movement, depth, and the projected walking path. Higher sensitivity accepts less evidence and may warn more often.
          </Text>
          <AdjustableRow
            label="Sensitivity"
            valueLabel={`${Math.round(preferences.sensitivity * 100)} percent`}
            onIncrement={() =>
              onChange({
                sensitivity: stepValue(preferences.sensitivity, 'increment', 0.05, 0.2, 1),
              })
            }
            onDecrement={() =>
              onChange({
                sensitivity: stepValue(preferences.sensitivity, 'decrement', 0.05, 0.2, 1),
              })
            }
          />
          <AdjustableRow
            label="Warning range"
            valueLabel={`${preferences.warningDistanceMeters.toFixed(1)} meters`}
            onIncrement={() =>
              onChange({
                warningDistanceMeters: stepValue(preferences.warningDistanceMeters, 'increment', 0.5, 1, 12),
              })
            }
            onDecrement={() =>
              onChange({
                warningDistanceMeters: stepValue(preferences.warningDistanceMeters, 'decrement', 0.5, 1, 12),
              })
            }
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

        <Text style={styles.safetyNote}>Clear Ahead is experimental and can miss hazards. It does not replace a cane, guide dog, or mobility training.</Text>
      </ScrollView>
      <BottomNavigation active="settings" onHome={onHome} onAssist={onAssist} onSettings={onSettings} assistDisabled={!hasCameraPermission} />
    </SafeAreaView>
  );
}

function Section({title, expanded, onToggle, children}: {title: string; expanded: boolean; onToggle: () => void; children: React.ReactNode}) {
  const reduceMotion = useReducedMotion();
  const progress = useRef(new Animated.Value(expanded ? 1 : 0)).current;
  const previousExpanded = useRef(expanded);
  const [contentHeight, setContentHeight] = useState(0);

  useEffect(() => {
    if (previousExpanded.current === expanded) {
      return;
    }
    previousExpanded.current = expanded;
    progress.stopAnimation();
    if (reduceMotion) {
      progress.setValue(expanded ? 1 : 0);
      return;
    }
    Animated.timing(progress, {
      toValue: expanded ? 1 : 0,
      duration: motion.standard,
      easing: Easing.out(Easing.cubic),
      useNativeDriver: false,
    }).start();
  }, [expanded, progress, reduceMotion]);

  const animatedHeight = contentHeight
    ? progress.interpolate({
        inputRange: [0, 1],
        outputRange: [0, contentHeight],
      })
    : expanded
    ? undefined
    : 0;

  return (
    <View style={styles.section}>
      <SpringPressable accessibilityRole="button" accessibilityLabel={`${title} settings`} accessibilityState={{expanded}} onPress={onToggle} pressedScale={0.98} style={styles.sectionHeader}>
        <Text style={styles.sectionTitle}>{title}</Text>
        <Animated.View
          accessibilityElementsHidden
          style={{
            transform: [
              {
                rotate: progress.interpolate({
                  inputRange: [0, 1],
                  outputRange: ['0deg', '180deg'],
                }),
              },
            ],
          }}
        >
          <ChevronDown color={colors.cyan} size={24} strokeWidth={2.5} />
        </Animated.View>
      </SpringPressable>
      <Animated.View
        pointerEvents={expanded ? 'auto' : 'none'}
        accessibilityElementsHidden={!expanded}
        importantForAccessibility={expanded ? 'auto' : 'no-hide-descendants'}
        style={[styles.sectionBodyClip, {height: animatedHeight, opacity: progress}]}
      >
        <View
          style={styles.sectionBodySpacing}
          onLayout={event => {
            const nextHeight = event.nativeEvent.layout.height;
            if (nextHeight !== contentHeight) {
              setContentHeight(nextHeight);
            }
          }}
        >
          <View style={styles.sectionBody}>{children}</View>
        </View>
      </Animated.View>
    </View>
  );
}

function ProcessingChoice({mode, current, label, description, onPress}: {mode: ProcessingMode; current: ProcessingMode; label: string; description: string; onPress: () => void}) {
  return (
    <SpringPressable
      accessibilityRole="radio"
      accessibilityLabel={`${label}. ${description}`}
      accessibilityState={{checked: mode === current}}
      onPress={onPress}
      pressedScale={0.975}
      style={[styles.processingChoice, mode === current && styles.processingChoiceSelected]}
    >
      {mode === current ? <View style={styles.selectedRailGlow} /> : null}
      <Text style={styles.mountingLabel}>{label}</Text>
      <Text style={styles.processingDescription}>{description}</Text>
    </SpringPressable>
  );
}

function MountingChoice({mode, current, label, onPress}: {mode: MountingMode; current: MountingMode; label: string; onPress: () => void}) {
  return (
    <SpringPressable accessibilityRole="radio" accessibilityState={{checked: mode === current}} onPress={onPress} pressedScale={0.97} style={styles.mountingChoice}>
      <Text style={styles.mountingLabel}>{label}</Text>
      <Text style={styles.mountingValue}>{mode === current ? 'Selected' : 'Select'}</Text>
    </SpringPressable>
  );
}

const styles = StyleSheet.create({
  safeArea: {flex: 1, backgroundColor: colors.night},
  header: {paddingHorizontal: 20, paddingTop: 28, paddingBottom: 24},
  title: {
    color: colors.text,
    fontSize: 36,
    lineHeight: 41,
    fontWeight: '800',
    letterSpacing: -1.2,
    marginTop: 10,
  },
  subtitle: {color: colors.muted, fontSize: 16, lineHeight: 23, marginTop: 8},
  content: {paddingHorizontal: 20, paddingBottom: 32, gap: 18},
  section: {},
  sectionHeader: {
    minHeight: 56,
    paddingHorizontal: 16,
    borderRadius: 10,
    backgroundColor: colors.surfaceRaised,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  sectionTitle: {color: colors.text, fontSize: 18, fontWeight: '800'},
  sectionBody: {
    backgroundColor: colors.surface,
    borderRadius: 10,
    paddingHorizontal: 16,
    overflow: 'hidden',
  },
  sectionBodyClip: {overflow: 'hidden'},
  sectionBodySpacing: {paddingTop: 8},
  sectionHelp: {
    color: colors.muted,
    fontSize: 15,
    lineHeight: 21,
    paddingTop: 18,
    paddingBottom: 8,
  },
  processingChoice: {
    minHeight: 92,
    paddingVertical: 14,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.line,
  },
  processingChoiceSelected: {
    borderLeftWidth: 4,
    borderLeftColor: colors.cyan,
    paddingLeft: 12,
  },
  selectedRailGlow: {
    position: 'absolute',
    left: -4,
    top: 14,
    bottom: 14,
    width: 4,
    borderRadius: 2,
    backgroundColor: colors.cyan,
    shadowColor: colors.cyan,
    shadowOpacity: 0.9,
    shadowRadius: 7,
  },
  processingDescription: {
    color: colors.muted,
    fontSize: 15,
    lineHeight: 21,
    marginTop: 4,
  },
  mountingChoice: {
    minHeight: 64,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.line,
  },
  mountingLabel: {color: colors.text, fontSize: 18, fontWeight: '700'},
  mountingValue: {color: colors.cyan, fontSize: 15, fontWeight: '700'},
  safetyNote: {color: colors.muted, fontSize: 15, lineHeight: 22},
});
