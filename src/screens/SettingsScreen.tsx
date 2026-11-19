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
import { ChevronDown, ChevronLeft } from 'lucide-react-native';
import { useCameraDevices } from 'react-native-vision-camera';
import { AdjustableRow, SegmentedRow, ToggleRow } from '../components/Controls';
import { motion, SpringPressable } from '../components/Motion';
import { colors } from '../config';
import { useReducedMotion } from '../hooks/useReducedMotion';
import { ClearAheadModule } from '../native/ClearAheadModule';
import type {
  AppPreferences,
  EventKind,
  ModelVariant,
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
  onBack,
  hasCameraPermission,
}: {
  preferences: AppPreferences;
  storageError?: string;
  onChange: (update: Partial<AppPreferences>) => void;
  onBack: () => void;
  hasCameraPermission: boolean;
}) {
  const [openSection, setOpenSection] = useState<string | null>(null);
  const [modelStatus, setModelStatus] = useState(
    'Nano detector and depth are bundled with the app',
  );
  const modelRequest = useRef(0);
  const pendingModelVariant = useRef<ModelVariant | undefined>(undefined);
  const cameraDevices = useCameraDevices();
  const supportsLidar = cameraDevices.some(device => device.position === 'back'
    && device.type === 'lidar-depth' && device.mediaTypes.includes('depth'));
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
        <SpringPressable
          accessibilityRole="button"
          accessibilityLabel="Back"
          accessibilityHint="Returns to the home screen"
          hitSlop={8}
          onPress={onBack}
          pressedScale={0.9}
          style={styles.backButton}
        >
          <ChevronLeft color={colors.ink} size={26} strokeWidth={2.2} />
        </SpringPressable>
        <Text accessibilityRole="header" style={styles.title}>
          Settings
        </Text>
      </View>
      <ScrollView contentContainerStyle={styles.content}>
        {storageError ? (
          <Text accessibilityRole="alert" style={styles.alert}>
            {storageError}
          </Text>
        ) : null}

        <View style={styles.card}>
          <ToggleRow
            label="Voice"
            description="Spoken warnings."
            value={preferences.speechEnabled}
            onValueChange={value => onChange({ speechEnabled: value })}
          />
          {preferences.speechEnabled ? (
            <SegmentedRow
              label="Voice says"
              options={[
                { value: 'hazards', label: 'What is in my way' },
                { value: 'everything', label: 'Everything nearby' },
              ]}
              value={preferences.speechDetail}
              onChange={speechDetail => onChange({ speechDetail })}
            />
          ) : null}
          <ToggleRow
            label="Sounds"
            description="Tones that get louder as things get closer."
            value={preferences.audioEnabled}
            onValueChange={value => onChange({ audioEnabled: value })}
          />
          <ToggleRow
            label="Vibration"
            description="Pulses when something is in your way."
            value={preferences.hapticsEnabled}
            onValueChange={value => onChange({ hapticsEnabled: value })}
          />
        </View>

        <View style={styles.card}>
          <SegmentedRow
            label="Phone position"
            options={[
              { value: 'handheld', label: 'In my hand' },
              { value: 'chest', label: 'On my chest' },
            ]}
            value={preferences.mountingMode}
            onChange={mountingMode => onChange({ mountingMode })}
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
          <AdjustableRow
            label="Sensitivity"
            valueLabel={`${Math.round(preferences.sensitivity * 100)} percent`}
            onIncrement={() =>
              onChange({ sensitivity: stepValue(preferences.sensitivity, 'increment', 0.05, 0.2, 1) })
            }
            onDecrement={() =>
              onChange({ sensitivity: stepValue(preferences.sensitivity, 'decrement', 0.05, 0.2, 1) })
            }
          />
        </View>

        <Section {...sectionProps('Sound and vibration')}>
          <ToggleRow
            label="Continuous tones"
            description="Keep tones playing for everything in view. Off leaves voice and vibration only."
            value={preferences.continuousAudio}
            onValueChange={value => onChange({ continuousAudio: value })}
          />
          <AdjustableRow
            label="Volume"
            valueLabel={`${Math.round(preferences.audioVolume * 100)} percent`}
            onIncrement={() =>
              onChange({ audioVolume: stepValue(preferences.audioVolume, 'increment', 0.1, 0.1, 1) })
            }
            onDecrement={() =>
              onChange({ audioVolume: stepValue(preferences.audioVolume, 'decrement', 0.1, 0.1, 1) })
            }
          />
          <AdjustableRow
            label="Vibration strength"
            valueLabel={`${Math.round(preferences.hapticIntensity * 100)} percent`}
            onIncrement={() =>
              onChange({ hapticIntensity: stepValue(preferences.hapticIntensity, 'increment', 0.1, 0.1, 1) })
            }
            onDecrement={() =>
              onChange({ hapticIntensity: stepValue(preferences.hapticIntensity, 'decrement', 0.1, 0.1, 1) })
            }
          />
          <Text style={styles.subheading}>Voice names</Text>
          {speechCategories.map(category => (
            <ToggleRow
              key={category.kind}
              label={category.label}
              value={preferences.spokenCategories.includes(category.kind)}
              onValueChange={value => toggleSpeechCategory(category.kind, value)}
            />
          ))}
          <Text style={styles.help}>Warnings are always spoken while Voice is on.</Text>
        </Section>

        <Section {...sectionProps('Calibration')}>
          <Text style={styles.help}>
            Measure heights above level ground. Offsets are how far the camera sits forward and right of the
            midpoint between your ears. Without these, distances are estimates.
          </Text>
          {(['cameraHeightMeters', 'earHeightMeters'] as const).map(key => (
            <AdjustableRow
              key={key}
              label={key === 'cameraHeightMeters' ? 'Camera height' : 'Ear height'}
              valueLabel={preferences[key] >= 0.4 ? `${preferences[key].toFixed(1)} meters` : 'Not set'}
              onIncrement={() => onChange({ [key]: preferences[key] < 0.4 ? 0.4 : stepValue(preferences[key], 'increment', 0.1, 0, 2.5) })}
              onDecrement={() => onChange({ [key]: preferences[key] <= 0.4 ? 0 : stepValue(preferences[key], 'decrement', 0.1, 0, 2.5) })}
            />
          ))}
          {(['cameraForwardOffsetMeters', 'cameraRightOffsetMeters'] as const).map(key => (
            <AdjustableRow
              key={key}
              label={key === 'cameraForwardOffsetMeters' ? 'Camera forward of ears' : 'Camera right of ears'}
              valueLabel={`${preferences[key].toFixed(2)} meters`}
              onIncrement={() => onChange({ [key]: stepValue(preferences[key], 'increment', 0.05, key === 'cameraRightOffsetMeters' ? -0.5 : 0, key === 'cameraRightOffsetMeters' ? 0.5 : 0.8) })}
              onDecrement={() => onChange({ [key]: stepValue(preferences[key], 'decrement', 0.05, key === 'cameraRightOffsetMeters' ? -0.5 : 0, key === 'cameraRightOffsetMeters' ? 0.5 : 0.8) })}
            />
          ))}
        </Section>

        <Section {...sectionProps('Advanced')}>
          <SegmentedRow<ProcessingMode>
            label="Processing"
            options={[
              { value: 'responsive', label: 'Faster' },
              { value: 'detailed', label: 'More detail' },
            ]}
            value={preferences.processingMode}
            onChange={processingMode => onChange({ processingMode })}
          />
          <ToggleRow
            label="Outlines"
            description="Outline hazards on the camera view."
            value={preferences.showBoundingBoxes}
            onValueChange={value => onChange({ showBoundingBoxes: value })}
          />
          {preferences.showBoundingBoxes ? (
            <SegmentedRow
              label="Outline"
              options={[
                { value: 'less', label: 'Stops only' },
                { value: 'standard', label: 'Hazards' },
                { value: 'verbose', label: 'Everything' },
              ]}
              value={preferences.boundingBoxVerbosity}
              onChange={boundingBoxVerbosity => onChange({ boundingBoxVerbosity })}
            />
          ) : null}
          <ToggleRow
            label="LiDAR"
            description={supportsLidar
              ? 'Measure close objects with the LiDAR sensor.'
              : hasCameraPermission ? 'This phone has no rear LiDAR sensor.'
              : 'Allow camera access to check for LiDAR.'}
            value={preferences.lidarEnabled && supportsLidar}
            disabled={!supportsLidar}
            onValueChange={value => onChange({ lidarEnabled: value })}
          />
          <ToggleRow
            label="Depth map"
            description="Show estimated distances as colors."
            value={preferences.depthMapEnabled}
            onValueChange={value => onChange({ depthMapEnabled: value })}
          />
          <ToggleRow
            label="Diagnostics"
            description="Show frame rates and audio status."
            value={preferences.showFps}
            onValueChange={value => onChange({ showFps: value })}
          />
          <Text style={styles.subheading}>Model</Text>
          <Text style={styles.help}>
            Nano is built in. Larger models download from Ultralytics and stay on this phone.
          </Text>
          {(['n', 's', 'm', 'l', 'x'] as ModelVariant[]).map(variant => (
            <ChoiceRow
              key={variant}
              label={modelNames[variant]}
              accessibilityLabel={`YOLO26 ${modelNames[variant]}`}
              selected={preferences.modelVariant === variant}
              onPress={() => selectModel(variant)}
            />
          ))}
          <Text accessibilityLiveRegion="polite" style={styles.help}>
            {modelStatus}
          </Text>
          <Text style={styles.subheading}>Camera</Text>
          <ChoiceRow
            label="Automatic"
            selected={
              preferences.cameraDeviceId === 'standard' ||
              (preferences.cameraDeviceId !== 'widest' && !hasSelectedCamera)
            }
            onPress={() => onChange({ cameraDeviceId: 'standard' })}
          />
          {backCameras.map(device => (
            <ChoiceRow
              key={device.id}
              label={`${cameraMagnification(device.type, device.focalLength, backCameras)} · ${device.name}`}
              selected={preferences.cameraDeviceId === device.id}
              onPress={() => onChange({ cameraDeviceId: device.id })}
            />
          ))}
        </Section>

        <Section {...sectionProps('About')}>
          <Text style={styles.help}>
            Clear Ahead is free software under the GNU Affero General Public
            License version 3, provided without warranty. YOLO26 models are
            supplied under the same license.
          </Text>
          <Pressable
            accessibilityRole="link"
            accessibilityLabel="View Clear Ahead source code and license"
            onPress={() => Linking.openURL('https://github.com/jiayangc1/ClearAhead')}
            style={styles.link}
          >
            <Text style={styles.linkText}>View source code and license</Text>
          </Pressable>
        </Section>

        <Text style={styles.safetyNote}>
          Clear Ahead is experimental and can miss hazards. It does not replace
          a cane, guide dog, or mobility training.
        </Text>
      </ScrollView>
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
        accessibilityLabel={title}
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
          <ChevronDown color={colors.muted} size={22} strokeWidth={2.2} />
        </Animated.View>
      </SpringPressable>
      {expanded ? (
        <View style={styles.sectionBody}>{children}</View>
      ) : null}
    </View>
  );
}

const modelNames: Record<ModelVariant, string> = {
  n: 'Nano',
  s: 'Small',
  m: 'Medium',
  l: 'Large',
  x: 'Extra large',
};

function ChoiceRow({
  label,
  accessibilityLabel,
  selected,
  onPress,
}: {
  label: string;
  accessibilityLabel?: string;
  selected: boolean;
  onPress: () => void;
}) {
  return (
    <SpringPressable
      accessibilityRole="radio"
      accessibilityLabel={accessibilityLabel ?? label}
      accessibilityState={{ checked: selected }}
      onPress={onPress}
      pressedScale={0.975}
      style={styles.choice}
    >
      <Text style={styles.choiceLabel}>{label}</Text>
      <View style={[styles.radio, selected && styles.radioSelected]} />
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
  safeArea: { flex: 1, backgroundColor: colors.background },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    paddingHorizontal: 20,
    paddingTop: 8,
    paddingBottom: 12,
  },
  backButton: {
    width: 48,
    height: 48,
    borderRadius: 24,
    backgroundColor: colors.surfaceRaised,
    alignItems: 'center',
    justifyContent: 'center',
  },
  title: {
    color: colors.ink,
    fontSize: 28,
    lineHeight: 34,
    fontWeight: '700',
    letterSpacing: -0.6,
  },
  content: { paddingHorizontal: 20, paddingBottom: 32, gap: 14 },
  card: {
    backgroundColor: colors.surface,
    borderRadius: 24,
    paddingHorizontal: 18,
    paddingVertical: 8,
  },
  section: {
    backgroundColor: colors.surface,
    borderRadius: 24,
    paddingHorizontal: 18,
  },
  sectionHeader: {
    minHeight: 60,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  sectionTitle: { color: colors.ink, fontSize: 17, fontWeight: '600' },
  sectionBody: { paddingBottom: 12 },
  subheading: {
    color: colors.ink,
    fontSize: 15,
    fontWeight: '700',
    paddingTop: 16,
    paddingBottom: 2,
  },
  help: {
    color: colors.muted,
    fontSize: 14,
    lineHeight: 20,
    paddingVertical: 6,
  },
  choice: {
    minHeight: 52,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 12,
  },
  choiceLabel: { color: colors.ink, fontSize: 16, fontWeight: '500', flex: 1 },
  radio: {
    width: 24,
    height: 24,
    borderRadius: 12,
    borderWidth: 2,
    borderColor: colors.line,
  },
  radioSelected: { borderWidth: 7, borderColor: colors.accentStrong },
  link: { minHeight: 44, justifyContent: 'center' },
  linkText: { color: colors.accentInk, fontSize: 15, fontWeight: '700' },
  alert: {
    color: colors.peachInk,
    backgroundColor: colors.peach,
    fontSize: 15,
    lineHeight: 21,
    fontWeight: '600',
    paddingHorizontal: 16,
    paddingVertical: 12,
    borderRadius: 16,
    overflow: 'hidden',
  },
  safetyNote: {
    color: colors.muted,
    fontSize: 13,
    lineHeight: 19,
    textAlign: 'center',
    paddingHorizontal: 12,
  },
});
