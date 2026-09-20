import React, { useEffect, useRef, useState } from 'react';
import {
  Animated,
  Linking,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ChevronDown } from 'lucide-react-native';
import { BrandLogo } from '../components/BrandLogo';
import { BottomNavigation } from '../components/BottomNavigation';
import { AdjustableRow, ToggleRow } from '../components/Controls';
import { motion, SpringPressable } from '../components/Motion';
import { colors } from '../config';
import { useReducedMotion } from '../hooks/useReducedMotion';
import { ClearAheadModule } from '../native/ClearAheadModule';
import type {
  AppPreferences,
  EventKind,
  ModelVariant,
  MountingMode,
  ProcessingMode,
} from '../types';
import { stepValue } from '../utils/eventLogic';

const speechCategories: Array<{ kind: EventKind; label: string }> = [
  { kind: 'person', label: 'People' },
  { kind: 'vehicle', label: 'Vehicles' },
  { kind: 'obstacle', label: 'Obstacles' },
  { kind: 'furniture', label: 'Furniture' },
  { kind: 'device-warning', label: 'Device warnings' },
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
  const [modelStatus, setModelStatus] = useState(
    'Downloaded automatically when selected',
  );
  const modelRequest = useRef(0);
  const pendingModelVariant = useRef<ModelVariant | undefined>(undefined);
  const sectionProps = (title: string) => ({
    title,
    expanded: openSection === title,
    onToggle: () =>
      setOpenSection(current => (current === title ? null : title)),
  });

  const toggleSpeechCategory = (kind: EventKind, enabled: boolean) => {
    const next = enabled
      ? [...new Set([...preferences.spokenCategories, kind])]
      : preferences.spokenCategories.filter(category => category !== kind);
    onChange({ spokenCategories: next });
  };

  useEffect(() => {
    const subscription = ClearAheadModule.onModelDownload(payload => {
      if (payload.modelVariant === pendingModelVariant.current) {
        setModelStatus(payload.message);
      }
    });
    return () => subscription?.remove();
  }, []);

  const selectModel = (modelVariant: ModelVariant) => {
    const request = ++modelRequest.current;
    pendingModelVariant.current = modelVariant;
    onChange({ modelVariant });
    setModelStatus(`Preparing YOLO26${modelVariant} models…`);
    ClearAheadModule.prepareModels(modelVariant, preferences.modelQuantization)
      .then(() => {
        if (request === modelRequest.current) {
          setModelStatus(
            `YOLO26${modelVariant} detector and depth models are ready`,
          );
        }
      })
      .catch(error => {
        if (request === modelRequest.current) {
          setModelStatus(
            error instanceof Error ? error.message : 'Model download failed',
          );
        }
      });
  };

  return (
    <SafeAreaView style={styles.safeArea}>
      <View style={styles.header}>
        <BrandLogo width={64} />
        <Text accessibilityRole="header" style={styles.title}>
          Settings
        </Text>
        <Text style={styles.subtitle}>
          Tune feedback and detection for the way you move.
        </Text>
      </View>
      <ScrollView contentContainerStyle={styles.content}>
        <Section {...sectionProps('Performance')}>
          <Text style={styles.sectionHelp}>
            Choose how often the app checks for nearby objects and depth. The
            processed rate can be lower than the camera capture rate.
          </Text>
          <ProcessingChoice
            mode="responsive"
            current={preferences.processingMode}
            label="Responsive"
            description="Smaller frames and fewer depth checks. Favors quicker object updates. Generic obstacles may be reported less often."
            onPress={() => onChange({ processingMode: 'responsive' })}
          />
          <ProcessingChoice
            mode="detailed"
            current={preferences.processingMode}
            label="Detailed"
            description="Larger frames and more frequent depth checks. May slow updates on older iPhones."
            onPress={() => onChange({ processingMode: 'detailed' })}
          />
          <ToggleRow
            label="Show frame rates"
            description="Show processed, object, and depth updates during assist mode and the last reading on Home."
            value={preferences.showFps}
            onValueChange={value => onChange({ showFps: value })}
          />
        </Section>

        <Section {...sectionProps('Feedback')}>
          <ToggleRow
            label="Haptics"
            description="Vibration patterns for direction and urgency."
            value={preferences.hapticsEnabled}
            onValueChange={value => onChange({ hapticsEnabled: value })}
          />
          <ToggleRow
            label="Directional audio"
            description={
              'Pitch shows distance, pulse speed shows urgency, and stereo position shows direction.'
            }
            value={preferences.audioEnabled}
            onValueChange={value => onChange({ audioEnabled: value })}
          />
          <ToggleRow
            label="Speech"
            description="Brief spoken labels for selected events."
            value={preferences.speechEnabled}
            onValueChange={value => onChange({ speechEnabled: value })}
          />
          <AdjustableRow
            label="Haptic strength"
            valueLabel={`${Math.round(
              preferences.hapticIntensity * 100,
            )} percent`}
            onIncrement={() =>
              onChange({
                hapticIntensity: stepValue(
                  preferences.hapticIntensity,
                  'increment',
                  0.1,
                  0.1,
                  1,
                ),
              })
            }
            onDecrement={() =>
              onChange({
                hapticIntensity: stepValue(
                  preferences.hapticIntensity,
                  'decrement',
                  0.1,
                  0.1,
                  1,
                ),
              })
            }
          />
          <AdjustableRow
            label="Audio volume"
            valueLabel={`${Math.round(preferences.audioVolume * 100)} percent`}
            onIncrement={() =>
              onChange({
                audioVolume: stepValue(
                  preferences.audioVolume,
                  'increment',
                  0.1,
                  0.1,
                  1,
                ),
              })
            }
            onDecrement={() =>
              onChange({
                audioVolume: stepValue(
                  preferences.audioVolume,
                  'decrement',
                  0.1,
                  0.1,
                  1,
                ),
              })
            }
          />
          <AdjustableRow
            label="Cue frequency"
            valueLabel={`${Math.round(
              preferences.feedbackFrequency * 100,
            )} percent`}
            onIncrement={() =>
              onChange({
                feedbackFrequency: stepValue(
                  preferences.feedbackFrequency,
                  'increment',
                  0.1,
                  0.1,
                  1,
                ),
              })
            }
            onDecrement={() =>
              onChange({
                feedbackFrequency: stepValue(
                  preferences.feedbackFrequency,
                  'decrement',
                  0.1,
                  0.1,
                  1,
                ),
              })
            }
          />
        </Section>

        <Section {...sectionProps('Detection')}>
          <Text style={styles.sectionHelp}>
            Collision warnings combine several frames of relative movement,
            depth, and the projected walking path. Higher sensitivity accepts
            less evidence and may warn more often.
          </Text>
          <AdjustableRow
            label="Sensitivity"
            valueLabel={`${Math.round(preferences.sensitivity * 100)} percent`}
            onIncrement={() =>
              onChange({
                sensitivity: stepValue(
                  preferences.sensitivity,
                  'increment',
                  0.05,
                  0.2,
                  1,
                ),
              })
            }
            onDecrement={() =>
              onChange({
                sensitivity: stepValue(
                  preferences.sensitivity,
                  'decrement',
                  0.05,
                  0.2,
                  1,
                ),
              })
            }
          />
          <AdjustableRow
            label="Warning range"
            valueLabel={`${preferences.warningDistanceMeters.toFixed(
              1,
            )} meters`}
            onIncrement={() =>
              onChange({
                warningDistanceMeters: stepValue(
                  preferences.warningDistanceMeters,
                  'increment',
                  0.5,
                  1,
                  12,
                ),
              })
            }
            onDecrement={() =>
              onChange({
                warningDistanceMeters: stepValue(
                  preferences.warningDistanceMeters,
                  'decrement',
                  0.5,
                  1,
                  12,
                ),
              })
            }
          />
          <ToggleRow
            label="Bounding boxes"
            description="Draw boxes and labels around objects detected by YOLO26."
            value={preferences.showBoundingBoxes}
            onValueChange={value => onChange({ showBoundingBoxes: value })}
          />
        </Section>

        <Section {...sectionProps('Phone position')}>
          <MountingChoice
            mode="handheld"
            current={preferences.mountingMode}
            label="In my hand"
            onPress={() => onChange({ mountingMode: 'handheld' })}
          />
          <MountingChoice
            mode="chest"
            current={preferences.mountingMode}
            label="Chest mounted"
            onPress={() => onChange({ mountingMode: 'chest' })}
          />
        </Section>

        <Section {...sectionProps('Spoken events')}>
          {speechCategories.map(category => (
            <ToggleRow
              key={category.kind}
              label={category.label}
              description={`Speak when important ${category.label.toLowerCase()} are detected.`}
              value={preferences.spokenCategories.includes(category.kind)}
              onValueChange={value =>
                toggleSpeechCategory(category.kind, value)
              }
            />
          ))}
        </Section>

        <Section {...sectionProps('Advanced')}>
          <Text style={styles.sectionHelp}>
            Select one matched YOLO26 detector and depth pair. Models download
            in the background and stay cached on this device.
          </Text>
          {(['n', 's', 'm', 'l', 'x'] as ModelVariant[]).map(variant => (
            <ModelChoice
              key={variant}
              variant={variant}
              current={preferences.modelVariant}
              onPress={() => selectModel(variant)}
            />
          ))}
          <Text accessibilityLiveRegion="polite" style={styles.modelStatus}>
            {modelStatus}
          </Text>
          <View style={styles.readOnlySetting}>
            <View style={styles.readOnlyCopy}>
              <Text style={styles.mountingLabel}>Quantization</Text>
              <Text style={styles.processingDescription}>
                INT8 balances accuracy, size, and compatibility with the app's
                iOS 17 target.
              </Text>
            </View>
            <Text style={styles.mountingValue}>INT8</Text>
          </View>
          <ToggleRow
            label="Depth map view"
            description="Replace the camera image with a red-near to blue-far view while keeping detector boxes visible."
            value={preferences.depthMapEnabled}
            onValueChange={value => onChange({ depthMapEnabled: value })}
          />
        </Section>

        <Section {...sectionProps('About')}>
          <Text style={styles.sectionHelp}>
            Clear Ahead is free software under the GNU Affero General Public
            License version 3, provided without warranty. YOLO26 models are
            supplied under the same license.
          </Text>
          <Pressable
            accessibilityRole="link"
            accessibilityLabel="View Clear Ahead source code and license"
            onPress={() => Linking.openURL('https://github.com/jiayangc1/cac')}
            style={styles.licenseLink}
          >
            <Text style={styles.licenseLinkText}>
              View source code and license
            </Text>
          </Pressable>
        </Section>

        <Text style={styles.safetyNote}>
          Clear Ahead is experimental and can miss hazards. It does not replace
          a cane, guide dog, or mobility training.
        </Text>
      </ScrollView>
      <BottomNavigation
        active="settings"
        onHome={onHome}
        onAssist={onAssist}
        onSettings={onSettings}
        assistDisabled={!hasCameraPermission}
      />
    </SafeAreaView>
  );
}

function Section({
  title,
  expanded,
  onToggle,
  children,
}: {
  title: string;
  expanded: boolean;
  onToggle: () => void;
  children: React.ReactNode;
}) {
  const reduceMotion = useReducedMotion();
  const progress = useRef(new Animated.Value(expanded ? 1 : 0)).current;

  useEffect(() => {
    progress.stopAnimation();
    if (reduceMotion) {
      progress.setValue(expanded ? 1 : 0);
      return;
    }
    Animated.timing(progress, {
      toValue: expanded ? 1 : 0,
      duration: motion.standard,
      useNativeDriver: true,
    }).start();
  }, [expanded, progress, reduceMotion]);

  return (
    <View style={styles.section}>
      <SpringPressable
        accessibilityRole="button"
        accessibilityLabel={`${title} settings`}
        accessibilityState={{ expanded }}
        onPress={onToggle}
        pressedScale={0.98}
        style={styles.sectionHeader}
      >
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
      {expanded ? (
        <View style={styles.sectionBodySpacing}>
          <View style={styles.sectionBody}>{children}</View>
        </View>
      ) : null}
    </View>
  );
}

function ProcessingChoice({
  mode,
  current,
  label,
  description,
  onPress,
}: {
  mode: ProcessingMode;
  current: ProcessingMode;
  label: string;
  description: string;
  onPress: () => void;
}) {
  return (
    <SpringPressable
      accessibilityRole="radio"
      accessibilityLabel={`${label}. ${description}`}
      accessibilityState={{ checked: mode === current }}
      onPress={onPress}
      pressedScale={0.975}
      style={[
        styles.processingChoice,
        mode === current && styles.processingChoiceSelected,
      ]}
    >
      {mode === current ? <View style={styles.selectedRailGlow} /> : null}
      <Text style={styles.mountingLabel}>{label}</Text>
      <Text style={styles.processingDescription}>{description}</Text>
    </SpringPressable>
  );
}

function MountingChoice({
  mode,
  current,
  label,
  onPress,
}: {
  mode: MountingMode;
  current: MountingMode;
  label: string;
  onPress: () => void;
}) {
  return (
    <SpringPressable
      accessibilityRole="radio"
      accessibilityState={{ checked: mode === current }}
      onPress={onPress}
      pressedScale={0.97}
      style={styles.mountingChoice}
    >
      <Text style={styles.mountingLabel}>{label}</Text>
      <Text style={styles.mountingValue}>
        {mode === current ? 'Selected' : 'Select'}
      </Text>
    </SpringPressable>
  );
}

const modelNames: Record<ModelVariant, string> = {
  n: 'Nano',
  s: 'Small',
  m: 'Medium',
  l: 'Large',
  x: 'Extra large',
};

function ModelChoice({
  variant,
  current,
  onPress,
}: {
  variant: ModelVariant;
  current: ModelVariant;
  onPress: () => void;
}) {
  const selected = variant === current;
  return (
    <SpringPressable
      accessibilityRole="radio"
      accessibilityLabel={`YOLO26 ${modelNames[variant]}`}
      accessibilityState={{ checked: selected }}
      onPress={onPress}
      pressedScale={0.975}
      style={[styles.modelChoice, selected && styles.processingChoiceSelected]}
    >
      <Text style={styles.mountingLabel}>
        YOLO26{variant} · {modelNames[variant]}
      </Text>
      <Text style={styles.mountingValue}>
        {selected ? 'Selected' : 'Download'}
      </Text>
    </SpringPressable>
  );
}

const styles = StyleSheet.create({
  safeArea: { flex: 1, backgroundColor: colors.night },
  header: { paddingHorizontal: 20, paddingTop: 28, paddingBottom: 24 },
  title: {
    color: colors.text,
    fontSize: 36,
    lineHeight: 41,
    fontWeight: '800',
    letterSpacing: -1.2,
    marginTop: 10,
  },
  subtitle: { color: colors.muted, fontSize: 16, lineHeight: 23, marginTop: 8 },
  content: { paddingHorizontal: 20, paddingBottom: 32, gap: 18 },
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
  sectionTitle: { color: colors.text, fontSize: 18, fontWeight: '800' },
  sectionBody: {
    backgroundColor: colors.surface,
    borderRadius: 10,
    paddingHorizontal: 16,
    overflow: 'hidden',
  },
  sectionBodySpacing: { paddingTop: 8 },
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
  modelChoice: {
    minHeight: 62,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 12,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.line,
  },
  modelStatus: {
    color: colors.muted,
    fontSize: 14,
    lineHeight: 20,
    paddingVertical: 12,
  },
  readOnlySetting: {
    minHeight: 82,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 16,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.line,
  },
  readOnlyCopy: { flex: 1 },
  licenseLink: { minHeight: 54, justifyContent: 'center' },
  licenseLinkText: { color: colors.cyan, fontSize: 16, fontWeight: '800' },
  mountingLabel: { color: colors.text, fontSize: 18, fontWeight: '700' },
  mountingValue: { color: colors.cyan, fontSize: 15, fontWeight: '700' },
  safetyNote: { color: colors.muted, fontSize: 15, lineHeight: 22 },
});
