import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  Animated,
  AppState,
  Linking,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ChevronDown } from 'lucide-react-native';
import { useCameraDevices } from 'react-native-vision-camera';
import { BrandLogo } from '../components/BrandLogo';
import { BottomNavigation } from '../components/BottomNavigation';
import { AdjustableRow, ToggleRow } from '../components/Controls';
import { motion, SpringPressable } from '../components/Motion';
import { colors, hasFeedbackChannel } from '../config';
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
];

export function SettingsScreen({
  preferences,
  storageError,
  onChange,
  onHome,
  onAssist,
  onSettings,
  hasCameraPermission,
}: {
  preferences: AppPreferences;
  storageError?: string;
  onChange: (update: Partial<AppPreferences>) => void;
  onHome: () => void;
  onAssist: () => void;
  onSettings: () => void;
  hasCameraPermission: boolean;
}) {
  const [openSection, setOpenSection] = useState<string | null>('Performance');
  const [modelStatus, setModelStatus] = useState(
    'Nano detector and depth are bundled with the app',
  );
  const modelRequest = useRef(0);
  const pendingModelVariant = useRef<ModelVariant | undefined>(undefined);
  const cameraDevices = useCameraDevices();
  const backCameras = useMemo(
    () =>
      cameraDevices
        .filter(device => device.position === 'back')
        .sort(
          (left, right) =>
            (left.focalLength ?? Number.MAX_VALUE) -
            (right.focalLength ?? Number.MAX_VALUE),
        ),
    [cameraDevices],
  );
  const hasSelectedCamera = backCameras.some(
    device => device.id === preferences.cameraDeviceId,
  );
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
    const requestState = modelRequest;
    const pendingSelection = pendingModelVariant;
    const subscription = ClearAheadModule.onModelDownload(payload => {
      if (payload.modelVariant === pendingSelection.current) {
        setModelStatus(payload.message);
      }
    });
    const cancelPending = () => {
      requestState.current += 1;
      if (pendingSelection.current) {
        pendingSelection.current = undefined;
        ClearAheadModule.cancelModelPreparation().catch(() => undefined);
        setModelStatus('Model download cancelled. Select a model to retry.');
      }
    };
    const lifecycle = AppState.addEventListener('change', state => {
      if (state !== 'active') {
        cancelPending();
      }
    });
    return () => {
      subscription?.remove();
      lifecycle.remove();
      requestState.current += 1;
      if (pendingSelection.current) {
        ClearAheadModule.cancelModelPreparation().catch(() => undefined);
      }
    };
  }, []);

  const selectModel = (modelVariant: ModelVariant) => {
    const request = ++modelRequest.current;
    pendingModelVariant.current = modelVariant;
    setModelStatus(`Preparing YOLO26${modelVariant} models…`);
    ClearAheadModule.prepareModels(modelVariant)
      .then(() => {
        if (request === modelRequest.current) {
          onChange({ modelVariant });
          pendingModelVariant.current = undefined;
          setModelStatus(
            `YOLO26${modelVariant} detector and depth models are ready`,
          );
        }
      })
      .catch(error => {
        if (request === modelRequest.current) {
          pendingModelVariant.current = undefined;
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
        {storageError ? (
          <Text accessibilityRole="alert" style={styles.safetyNote}>
            {storageError}
          </Text>
        ) : null}
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
            description="Brief spoken labels plus urgent collision and camera warnings."
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
          <Text style={styles.sectionHelp}>
            Choose ordinary spoken labels. Urgent collision and camera warnings
            still speak when Speech is on.
          </Text>
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
            Nano is bundled. Other models download from Ultralytics and stay on
            this device. Cellular downloads require your approval.
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
          <ToggleRow
            label="Depth map view"
            description="Replace the camera image with a red-near to blue-far view while keeping detector boxes visible."
            value={preferences.depthMapEnabled}
            onValueChange={value => onChange({ depthMapEnabled: value })}
          />
          <Text style={styles.advancedSubheading}>Camera field of view</Text>
          <Text style={styles.cameraHelp}>
            Available fields of view depend on this device. Automatic prefers
            the standard wide rear camera. Other lenses need device calibration.
          </Text>
          <CameraChoice
            label="Automatic · standard wide"
            description="Uses the standard wide rear camera when available."
            selected={
              preferences.cameraDeviceId === 'standard' ||
              (preferences.cameraDeviceId !== 'widest' && !hasSelectedCamera)
            }
            onPress={() => onChange({ cameraDeviceId: 'standard' })}
          />
          {backCameras.map(device => (
            <CameraChoice
              key={device.id}
              label={`${cameraMagnification(
                device.type,
                device.focalLength,
                backCameras,
              )} · ${device.name}`}
              description="Use this camera whenever Assist Mode starts."
              selected={preferences.cameraDeviceId === device.id}
              onPress={() => onChange({ cameraDeviceId: device.id })}
            />
          ))}
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
        assistDisabled={
          !hasCameraPermission || !hasFeedbackChannel(preferences)
        }
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

function CameraChoice({
  label,
  description,
  selected,
  onPress,
}: {
  label: string;
  description: string;
  selected: boolean;
  onPress: () => void;
}) {
  return (
    <SpringPressable
      accessibilityRole="radio"
      accessibilityLabel={`${label}. ${description}`}
      accessibilityState={{ checked: selected }}
      onPress={onPress}
      pressedScale={0.975}
      style={[styles.cameraChoice, selected && styles.processingChoiceSelected]}
    >
      <View style={styles.readOnlyCopy}>
        <Text style={styles.mountingLabel}>{label}</Text>
        <Text style={styles.processingDescription}>{description}</Text>
      </View>
      <Text style={styles.mountingValue}>
        {selected ? 'Selected' : 'Select'}
      </Text>
    </SpringPressable>
  );
}

function cameraMagnification(
  type: string,
  focalLength: number | undefined,
  cameras: Array<{ type: string; focalLength?: number }>,
): string {
  if (type === 'ultra-wide-angle') {
    return '0.5×';
  }
  if (type === 'wide-angle') {
    return '1×';
  }
  const standardFocalLength = cameras.find(
    camera => camera.type === 'wide-angle',
  )?.focalLength;
  if (focalLength && standardFocalLength) {
    const ratio = Math.round((focalLength / standardFocalLength) * 10) / 10;
    return `${ratio}×`;
  }
  return 'Rear';
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
  readOnlyCopy: { flex: 1 },
  advancedSubheading: {
    color: colors.text,
    fontSize: 19,
    fontWeight: '800',
    paddingTop: 20,
  },
  cameraHelp: {
    color: colors.muted,
    fontSize: 15,
    lineHeight: 21,
    paddingVertical: 8,
  },
  cameraChoice: {
    minHeight: 82,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 14,
    paddingVertical: 10,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.line,
  },
  licenseLink: { minHeight: 54, justifyContent: 'center' },
  licenseLinkText: { color: colors.cyan, fontSize: 16, fontWeight: '800' },
  mountingLabel: { color: colors.text, fontSize: 18, fontWeight: '700' },
  mountingValue: { color: colors.cyan, fontSize: 15, fontWeight: '700' },
  safetyNote: { color: colors.muted, fontSize: 15, lineHeight: 22 },
});
