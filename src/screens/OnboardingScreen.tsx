import React, { useEffect, useRef, useState } from 'react';
import {
  AccessibilityInfo,
  findNodeHandle,
  Linking,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { Check, ChevronLeft } from 'lucide-react-native';
import { BrandLogo } from '../components/BrandLogo';
import { colors } from '../config';
import { PrimaryButton } from '../components/Controls';
import { Entrance, SpringPressable } from '../components/Motion';
import type { MountingMode } from '../types';

const STEPS = [
  {
    name: 'safety limits',
    title: 'Awareness, not a guarantee.',
    body: 'Clear Ahead turns nearby camera events into haptic and audio cues. It can miss hazards or estimate them incorrectly.',
  },
  {
    name: 'phone position setup',
    title: 'Where will you carry your phone?',
    body: 'This changes how Clear Ahead interprets the camera angle. You can change it later.',
  },
  {
    name: 'camera permission',
    title: 'Camera access stays on this phone.',
    body: 'Frames are analyzed on-device. Clear Ahead does not save, upload, or share camera images.',
  },
] as const;

export function OnboardingScreen({
  mountingMode,
  hasCameraPermission,
  canRequestCameraPermission,
  requestCameraPermission,
  onMountingModeChange,
  onComplete,
}: {
  mountingMode: MountingMode;
  hasCameraPermission: boolean;
  canRequestCameraPermission: boolean;
  requestCameraPermission: () => Promise<boolean>;
  onMountingModeChange: (mode: MountingMode) => void;
  onComplete: () => void;
}) {
  const [step, setStep] = useState(0);
  const scrollRef = useRef<React.ElementRef<typeof ScrollView>>(null);
  const titleRef = useRef<React.ElementRef<typeof Text>>(null);

  useEffect(() => {
    scrollRef.current?.scrollTo({ y: 0, animated: false });
    const frame = requestAnimationFrame(() => {
      const node = findNodeHandle(titleRef.current);
      if (node) {
        AccessibilityInfo.setAccessibilityFocus(node);
      }
    });
    return () => cancelAnimationFrame(frame);
  }, [step]);

  const isLastStep = step === STEPS.length - 1;
  const { title, body } = STEPS[step];
  const cameraBlocked = !hasCameraPermission && !canRequestCameraPermission;

  let primary: { label: string; hint: string; onPress: () => void };
  if (!isLastStep) {
    primary = {
      label: step === 0 ? 'I understand' : 'Continue',
      hint: `Continues to ${STEPS[step + 1].name}`,
      onPress: () => setStep(step + 1),
    };
  } else if (hasCameraPermission) {
    primary = {
      label: 'Finish setup',
      hint: 'Opens the Clear Ahead home screen',
      onPress: onComplete,
    };
  } else if (cameraBlocked) {
    primary = {
      label: 'Open iOS Settings',
      hint: 'Opens Settings so you can enable Camera for Clear Ahead',
      onPress: () => {
        Linking.openSettings().catch(() => undefined);
      },
    };
  } else {
    primary = {
      label: 'Allow camera access',
      hint: 'Opens the iOS camera permission prompt',
      onPress: () => {
        requestCameraPermission().catch(() => undefined);
      },
    };
  }

  return (
    <SafeAreaView style={styles.safeArea}>
      <View style={styles.container} accessibilityViewIsModal>
        <View style={styles.topBar}>
          {step === 0 ? (
            <View style={styles.topBarSlot}>
              <BrandLogo width={34} />
            </View>
          ) : (
            <SpringPressable
              accessibilityRole="button"
              accessibilityLabel="Back"
              accessibilityHint={`Returns to ${STEPS[step - 1].name}`}
              hitSlop={8}
              onPress={() => setStep(step - 1)}
              pressedScale={0.9}
              style={styles.topBarSlot}
            >
              <ChevronLeft color={colors.ink} size={26} strokeWidth={2.2} />
            </SpringPressable>
          )}
          <View
            accessible
            accessibilityRole="progressbar"
            accessibilityLabel={`Setup step ${step + 1} of ${STEPS.length}`}
            accessibilityValue={{ min: 1, max: STEPS.length, now: step + 1 }}
            style={styles.progress}
          >
            <View style={styles.progressTrack}>
              {STEPS.map((item, index) => (
                <View
                  key={item.name}
                  style={[
                    styles.progressSegment,
                    index <= step && styles.progressSegmentActive,
                  ]}
                />
              ))}
            </View>
            <Text style={styles.eyebrow}>
              STEP {step + 1} OF {STEPS.length}
            </Text>
          </View>
        </View>

        <ScrollView
          ref={scrollRef}
          style={styles.scroll}
          contentContainerStyle={styles.content}
          keyboardShouldPersistTaps="handled"
        >
          <StepTransition step={step}>
            <Text
              ref={titleRef}
              accessibilityRole="header"
              style={styles.title}
            >
              {title}
            </Text>
            <Text style={styles.body}>{body}</Text>

            {step === 0 ? (
              <View style={styles.panel}>
                <Text style={styles.warningLabel}>SAFETY LIMIT</Text>
                <Text style={styles.warningText}>
                  Keep using your cane, guide dog, mobility training, and
                  judgment. Do not use this app as collision avoidance.
                </Text>
              </View>
            ) : null}

            {step === 1 ? (
              <View accessibilityRole="radiogroup" style={styles.choices}>
                <Choice
                  label="In my hand"
                  description="Camera points forward at about chest height."
                  selected={mountingMode === 'handheld'}
                  onPress={() => onMountingModeChange('handheld')}
                />
                <Choice
                  label="Chest mounted"
                  description="Phone stays upright with the rear camera unobstructed."
                  selected={mountingMode === 'chest'}
                  onPress={() => onMountingModeChange('chest')}
                />
              </View>
            ) : null}

            {step === 2 ? (
              <>
                <View
                  accessible
                  accessibilityLiveRegion="polite"
                  accessibilityLabel={`Camera. ${
                    hasCameraPermission ? 'Ready' : 'Permission needed'
                  }`}
                  style={[styles.panel, styles.statusRow]}
                >
                  <Text style={styles.statusLabel}>Camera</Text>
                  <View style={styles.statusValueRow}>
                    <View
                      style={[
                        styles.statusMark,
                        !hasCameraPermission && styles.statusMarkPending,
                      ]}
                    />
                    <Text style={styles.statusValue}>
                      {hasCameraPermission ? 'Ready' : 'Permission needed'}
                    </Text>
                  </View>
                </View>
                {cameraBlocked ? (
                  <Text accessibilityRole="alert" style={styles.help}>
                    Camera access is blocked. Open iOS Settings, choose Clear
                    Ahead, then enable Camera.
                  </Text>
                ) : null}
              </>
            ) : null}
          </StepTransition>
        </ScrollView>

        <View style={styles.footer}>
          <PrimaryButton
            label={primary.label}
            hint={primary.hint}
            onPress={primary.onPress}
          />
          {isLastStep && !hasCameraPermission ? (
            <SpringPressable
              accessibilityRole="button"
              accessibilityLabel="Continue without camera"
              accessibilityHint="Opens the Clear Ahead home screen. Assist Mode stays unavailable until camera access is on."
              onPress={onComplete}
              pressedScale={0.95}
              style={styles.quietButton}
            >
              <Text style={styles.quietText}>Continue without camera</Text>
            </SpringPressable>
          ) : null}
        </View>
      </View>
    </SafeAreaView>
  );
}

function StepTransition({
  step,
  children,
}: {
  step: number;
  children: React.ReactNode;
}) {
  return (
    <Entrance key={`setup-${step}`} distance={16} style={styles.stepContent}>
      {children}
    </Entrance>
  );
}

function Choice({
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
      style={[styles.choice, selected && styles.choiceSelected]}
    >
      <View style={styles.choiceCopy}>
        <Text style={styles.choiceLabel}>{label}</Text>
        <Text style={styles.choiceDescription}>{description}</Text>
      </View>
      <View style={[styles.radio, selected && styles.radioSelected]}>
        {selected ? (
          <Check color={colors.ink} size={15} strokeWidth={3.5} />
        ) : null}
      </View>
    </SpringPressable>
  );
}

const styles = StyleSheet.create({
  safeArea: { flex: 1, backgroundColor: colors.background },
  container: { flex: 1 },
  topBar: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    paddingHorizontal: 20,
    paddingTop: 12,
    paddingBottom: 8,
  },
  topBarSlot: {
    width: 44,
    height: 44,
    alignItems: 'center',
    justifyContent: 'center',
  },
  progress: { flex: 1, gap: 8 },
  progressTrack: { flexDirection: 'row', gap: 6 },
  progressSegment: {
    height: 3,
    flex: 1,
    borderRadius: 2,
    backgroundColor: colors.line,
  },
  progressSegmentActive: { backgroundColor: colors.accentStrong },
  eyebrow: {
    color: colors.muted,
    fontSize: 11,
    fontWeight: '800',
    letterSpacing: 1.5,
  },
  scroll: { flex: 1 },
  content: {
    flexGrow: 1,
    paddingHorizontal: 20,
    paddingTop: 24,
    paddingBottom: 24,
  },
  stepContent: { gap: 20 },
  title: {
    color: colors.ink,
    fontSize: 32,
    lineHeight: 38,
    fontWeight: '700',
    letterSpacing: -0.8,
  },
  body: { color: colors.muted, fontSize: 18, lineHeight: 27 },
  panel: {
    backgroundColor: colors.surface,
    borderColor: colors.line,
    borderWidth: 1,
    borderRadius: 20,
    padding: 18,
    gap: 8,
  },
  warningLabel: {
    color: colors.peachInk,
    fontSize: 11,
    fontWeight: '800',
    letterSpacing: 1.5,
  },
  warningText: {
    color: colors.ink,
    fontSize: 18,
    lineHeight: 26,
    fontWeight: '600',
  },
  choices: { gap: 12 },
  choice: {
    minHeight: 88,
    borderRadius: 20,
    borderWidth: 1,
    borderColor: colors.line,
    backgroundColor: colors.surface,
    padding: 16,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 16,
  },
  choiceSelected: {
    borderColor: colors.accentStrong,
    backgroundColor: colors.surfaceRaised,
  },
  choiceCopy: { flex: 1 },
  choiceLabel: {
    color: colors.ink,
    fontSize: 18,
    lineHeight: 23,
    fontWeight: '700',
  },
  choiceDescription: {
    color: colors.muted,
    fontSize: 15,
    lineHeight: 21,
    marginTop: 3,
  },
  radio: {
    width: 24,
    height: 24,
    borderRadius: 12,
    borderWidth: 2,
    borderColor: colors.muted,
    alignItems: 'center',
    justifyContent: 'center',
  },
  radioSelected: { borderColor: colors.accent, backgroundColor: colors.accent },
  statusRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 16,
  },
  statusLabel: { color: colors.muted, fontSize: 15, fontWeight: '600' },
  statusValueRow: { flexDirection: 'row', alignItems: 'center', gap: 9 },
  statusMark: {
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: colors.mintInk,
  },
  statusMarkPending: { backgroundColor: colors.peachInk },
  statusValue: { color: colors.ink, fontSize: 15, fontWeight: '700' },
  help: { color: colors.peachInk, fontSize: 16, lineHeight: 23 },
  footer: {
    paddingHorizontal: 20,
    paddingTop: 12,
    paddingBottom: 12,
    gap: 4,
  },
  quietButton: {
    minHeight: 50,
    alignItems: 'center',
    justifyContent: 'center',
  },
  quietText: { color: colors.muted, fontSize: 15, fontWeight: '700' },
});
