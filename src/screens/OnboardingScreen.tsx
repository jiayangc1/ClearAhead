import React, { useEffect, useRef, useState } from 'react';
import {
  AccessibilityInfo,
  findNodeHandle,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { BrandLogo } from '../components/BrandLogo';
import { colors } from '../config';
import { PrimaryButton } from '../components/Controls';
import { Entrance, SpringPressable } from '../components/Motion';
import type { MountingMode } from '../types';

export function OnboardingScreen({
  mountingMode,
  hasCameraPermission,
  canRequestCameraPermission,
  requestCameraPermission,
  onMountingModeChange,
  onTestFeedback,
  onComplete,
}: {
  mountingMode: MountingMode;
  hasCameraPermission: boolean;
  canRequestCameraPermission: boolean;
  requestCameraPermission: () => Promise<boolean>;
  onMountingModeChange: (mode: MountingMode) => void;
  onTestFeedback: () => Promise<void>;
  onComplete: () => void;
}) {
  const [step, setStep] = useState(0);
  const [isTestingFeedback, setIsTestingFeedback] = useState(false);
  const [feedbackError, setFeedbackError] = useState<string>();
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
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

  const testFeedback = () => {
    setIsTestingFeedback(true);
    setFeedbackError(undefined);
    onTestFeedback()
      .catch(error => {
        if (!mounted.current) {
          return;
        }
        const message =
          error instanceof Error
            ? error.message
            : 'Feedback test failed. Please try again.';
        setFeedbackError(message);
        AccessibilityInfo.announceForAccessibility(message);
      })
      .finally(() => {
        if (mounted.current) {
          setIsTestingFeedback(false);
        }
      });
  };

  return (
    <SafeAreaView style={styles.safeArea}>
      <ScrollView
        ref={scrollRef}
        contentContainerStyle={styles.content}
        accessibilityViewIsModal
        keyboardShouldPersistTaps="handled"
      >
        <View style={styles.brandRow}>
          <BrandLogo width={52} />
          <View style={styles.progressCopy}>
            <Text style={styles.eyebrow}>SETUP {step + 1} OF 3</Text>
            <View style={styles.progressTrack}>
              {[0, 1, 2].map(index => (
                <View
                  key={index}
                  style={[
                    styles.progressSegment,
                    index <= step && styles.progressSegmentActive,
                  ]}
                />
              ))}
            </View>
          </View>
        </View>
        <StepTransition step={step}>
          {step === 0 ? (
            <>
              <Text
                ref={titleRef}
                accessibilityRole="header"
                style={styles.title}
              >
                Awareness, not a guarantee.
              </Text>
              <Text style={styles.body}>
                Clear Ahead turns nearby camera events into haptic and audio
                cues. It can miss hazards or estimate them incorrectly.
              </Text>
              <View style={styles.warning}>
                <Text style={styles.warningLabel}>SAFETY LIMIT</Text>
                <Text style={styles.warningText}>
                  Keep using your cane, guide dog, mobility training, and
                  judgment. Do not use this app as collision avoidance.
                </Text>
              </View>
              <PrimaryButton
                label="I understand"
                hint="Continues to phone position setup"
                onPress={() => setStep(1)}
              />
            </>
          ) : null}

          {step === 1 ? (
            <>
              <Text
                ref={titleRef}
                accessibilityRole="header"
                style={styles.title}
              >
                Where will you carry your phone?
              </Text>
              <Text style={styles.body}>
                This changes how Clear Ahead interprets the camera angle. You
                can change it later.
              </Text>
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
              <PrimaryButton
                label="Continue"
                hint="Continues to camera permission"
                onPress={() => setStep(2)}
              />
            </>
          ) : null}

          {step === 2 ? (
            <>
              <Text
                ref={titleRef}
                accessibilityRole="header"
                style={styles.title}
              >
                Camera access stays on this phone.
              </Text>
              <Text style={styles.body}>
                Frames are analyzed on-device. Clear Ahead does not save,
                upload, or share camera images.
              </Text>
              <View
                style={styles.permissionState}
                accessibilityLiveRegion="polite"
              >
                <Text style={styles.permissionLabel}>CAMERA</Text>
                <Text style={styles.permissionValue}>
                  {hasCameraPermission ? 'Ready' : 'Permission needed'}
                </Text>
              </View>
              {!hasCameraPermission && canRequestCameraPermission ? (
                <PrimaryButton
                  label="Allow camera access"
                  hint="Opens the iOS camera permission prompt"
                  onPress={() => requestCameraPermission()}
                />
              ) : null}
              {!hasCameraPermission && !canRequestCameraPermission ? (
                <Text accessibilityRole="alert" style={styles.permissionHelp}>
                  Camera access is blocked. Open iOS Settings, choose Clear
                  Ahead, then enable Camera.
                </Text>
              ) : null}
              <SpringPressable
                accessibilityRole="button"
                accessibilityLabel="Test feedback cues"
                accessibilityHint="Plays a short left and center person warning while you remain seated"
                disabled={isTestingFeedback}
                onPress={testFeedback}
                pressedScale={0.96}
                style={[
                  styles.testButton,
                  isTestingFeedback && styles.testButtonDisabled,
                ]}
              >
                <Text style={styles.testButtonText}>
                  {isTestingFeedback
                    ? 'Playing feedback…'
                    : 'Test feedback cues'}
                </Text>
              </SpringPressable>
              {feedbackError ? (
                <Text accessibilityRole="alert" style={styles.permissionHelp}>
                  {feedbackError}
                </Text>
              ) : null}
              <PrimaryButton
                label={
                  hasCameraPermission
                    ? 'Finish setup'
                    : 'Continue without camera'
                }
                hint="Opens the Clear Ahead home screen"
                onPress={onComplete}
              />
            </>
          ) : null}
        </StepTransition>
      </ScrollView>
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
  if (step === 0) {
    return <View style={styles.stepContent}>{children}</View>;
  }

  return (
    <Entrance key={`setup-${step}`} distance={22} style={styles.stepContent}>
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
      <View style={[styles.radio, selected && styles.radioSelected]}>
        {selected ? <View style={styles.radioCore} /> : null}
      </View>
      <View style={styles.choiceCopy}>
        <Text style={styles.choiceLabel}>{label}</Text>
        <Text style={styles.choiceDescription}>{description}</Text>
      </View>
    </SpringPressable>
  );
}

const styles = StyleSheet.create({
  safeArea: { flex: 1, backgroundColor: colors.night },
  content: { flexGrow: 1, padding: 24, paddingTop: 38, gap: 22 },
  brandRow: { flexDirection: 'row', alignItems: 'center', gap: 14 },
  progressCopy: { flex: 1, gap: 8 },
  progressTrack: { flexDirection: 'row', gap: 6 },
  progressSegment: {
    height: 3,
    flex: 1,
    borderRadius: 2,
    backgroundColor: colors.line,
  },
  progressSegmentActive: {
    backgroundColor: colors.cyan,
    shadowColor: colors.cyan,
    shadowOpacity: 0.8,
    shadowRadius: 5,
  },
  stepContent: { gap: 22 },
  eyebrow: {
    color: colors.cyan,
    fontSize: 12,
    fontWeight: '800',
    letterSpacing: 1.6,
  },
  title: { color: colors.text, fontSize: 39, fontWeight: '800' },
  body: { color: colors.muted, fontSize: 19, lineHeight: 28 },
  warning: {
    backgroundColor: colors.surface,
    borderLeftWidth: 5,
    borderLeftColor: colors.amber,
    borderRadius: 16,
    padding: 20,
    gap: 8,
  },
  warningLabel: {
    color: colors.amber,
    fontSize: 12,
    fontWeight: '900',
    letterSpacing: 1.4,
  },
  warningText: {
    color: colors.text,
    fontSize: 18,
    lineHeight: 26,
    fontWeight: '600',
  },
  choice: {
    minHeight: 96,
    borderRadius: 18,
    borderWidth: 2,
    borderColor: colors.line,
    backgroundColor: colors.surface,
    padding: 18,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 15,
  },
  choiceSelected: {
    borderColor: colors.cyan,
    backgroundColor: colors.surfaceRaised,
  },
  radio: {
    width: 24,
    height: 24,
    borderRadius: 12,
    borderWidth: 3,
    borderColor: colors.muted,
  },
  radioSelected: { borderWidth: 7, borderColor: colors.cyan },
  radioCore: {
    position: 'absolute',
    width: 6,
    height: 6,
    borderRadius: 3,
    backgroundColor: colors.text,
    alignSelf: 'center',
    top: 2,
  },
  choiceCopy: { flex: 1 },
  choiceLabel: { color: colors.text, fontSize: 20, fontWeight: '800' },
  choiceDescription: {
    color: colors.muted,
    fontSize: 16,
    lineHeight: 22,
    marginTop: 4,
  },
  permissionState: {
    padding: 22,
    borderRadius: 18,
    backgroundColor: colors.surface,
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  permissionLabel: {
    color: colors.muted,
    fontSize: 13,
    fontWeight: '800',
    letterSpacing: 1.4,
  },
  permissionValue: { color: colors.cyan, fontSize: 17, fontWeight: '800' },
  permissionHelp: { color: colors.amber, fontSize: 17, lineHeight: 24 },
  testButton: {
    minHeight: 56,
    borderRadius: 17,
    borderWidth: 2,
    borderColor: colors.cyan,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 18,
  },
  testButtonText: { color: colors.cyan, fontSize: 17, fontWeight: '800' },
  testButtonDisabled: { opacity: 0.5 },
});
