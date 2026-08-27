import React, {useState} from 'react';
import {Pressable, ScrollView, StyleSheet, Text, View} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import {colors} from '../config';
import {PrimaryButton} from '../components/Controls';
import type {MountingMode} from '../types';

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

  const testFeedback = () => {
    setIsTestingFeedback(true);
    onTestFeedback()
      .catch(() => undefined)
      .finally(() => setIsTestingFeedback(false));
  };

  return (
    <SafeAreaView style={styles.safeArea}>
      <ScrollView
        contentContainerStyle={styles.content}
        accessibilityViewIsModal
        keyboardShouldPersistTaps="handled">
        <Text style={styles.eyebrow}>CLEAR AHEAD · SETUP {step + 1} OF 3</Text>
        {step === 0 ? (
          <>
            <Text accessibilityRole="header" style={styles.title}>
              Awareness, not a guarantee.
            </Text>
            <Text style={styles.body}>
              Clear Ahead turns nearby camera events into haptic and audio cues.
              It can miss hazards or estimate them incorrectly.
            </Text>
            <View style={styles.warning}>
              <Text style={styles.warningLabel}>SAFETY LIMIT</Text>
              <Text style={styles.warningText}>
                Keep using your cane, guide dog, mobility training, and judgment.
                Do not use this app as collision avoidance.
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
            <Text accessibilityRole="header" style={styles.title}>
              Where will you carry your phone?
            </Text>
            <Text style={styles.body}>
              This changes how Clear Ahead interprets the camera angle. You can
              change it later.
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
            <Text accessibilityRole="header" style={styles.title}>
              Camera access stays on this phone.
            </Text>
            <Text style={styles.body}>
              Frames are analyzed on-device. Clear Ahead does not save, upload,
              or share camera images.
            </Text>
            <View style={styles.permissionState} accessibilityLiveRegion="polite">
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
                Camera access is blocked. Open iOS Settings, choose Clear Ahead,
                then enable Camera.
              </Text>
            ) : null}
            <Pressable
              accessibilityRole="button"
              accessibilityLabel="Test feedback cues"
              accessibilityHint="Plays a short left and center person warning while you remain seated"
              disabled={isTestingFeedback}
              onPress={testFeedback}
              style={({pressed}) => [
                styles.testButton,
                pressed && styles.pressed,
                isTestingFeedback && {opacity: 0.5},
              ]}>
              <Text style={styles.testButtonText}>
                {isTestingFeedback ? 'Playing feedback…' : 'Test feedback cues'}
              </Text>
            </Pressable>
            <PrimaryButton
              label={hasCameraPermission ? 'Finish setup' : 'Continue without camera'}
              hint="Opens the Clear Ahead home screen"
              onPress={onComplete}
            />
          </>
        ) : null}
      </ScrollView>
    </SafeAreaView>
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
    <Pressable
      accessibilityRole="radio"
      accessibilityState={{checked: selected}}
      onPress={onPress}
      style={({pressed}) => [
        styles.choice,
        selected && styles.choiceSelected,
        pressed && styles.pressed,
      ]}>
      <View style={[styles.radio, selected && styles.radioSelected]} />
      <View style={styles.choiceCopy}>
        <Text style={styles.choiceLabel}>{label}</Text>
        <Text style={styles.choiceDescription}>{description}</Text>
      </View>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  safeArea: {flex: 1, backgroundColor: colors.night},
  content: {flexGrow: 1, padding: 24, paddingTop: 38, gap: 22},
  eyebrow: {color: colors.cyan, fontSize: 12, fontWeight: '800', letterSpacing: 1.6},
  title: {color: colors.text, fontSize: 39, lineHeight: 43, fontWeight: '800'},
  body: {color: colors.muted, fontSize: 19, lineHeight: 28},
  warning: {
    backgroundColor: colors.surface,
    borderLeftWidth: 5,
    borderLeftColor: colors.amber,
    borderRadius: 16,
    padding: 20,
    gap: 8,
  },
  warningLabel: {color: colors.amber, fontSize: 12, fontWeight: '900', letterSpacing: 1.4},
  warningText: {color: colors.text, fontSize: 18, lineHeight: 26, fontWeight: '600'},
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
  choiceSelected: {borderColor: colors.cyan, backgroundColor: colors.surfaceRaised},
  radio: {width: 24, height: 24, borderRadius: 12, borderWidth: 3, borderColor: colors.muted},
  radioSelected: {borderWidth: 7, borderColor: colors.cyan},
  choiceCopy: {flex: 1},
  choiceLabel: {color: colors.text, fontSize: 20, fontWeight: '800'},
  choiceDescription: {color: colors.muted, fontSize: 16, lineHeight: 22, marginTop: 4},
  permissionState: {
    padding: 22,
    borderRadius: 18,
    backgroundColor: colors.surface,
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  permissionLabel: {color: colors.muted, fontSize: 13, fontWeight: '800', letterSpacing: 1.4},
  permissionValue: {color: colors.cyan, fontSize: 17, fontWeight: '800'},
  permissionHelp: {color: colors.amber, fontSize: 17, lineHeight: 24},
  testButton: {
    minHeight: 56,
    borderRadius: 17,
    borderWidth: 2,
    borderColor: colors.cyan,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 18,
  },
  testButtonText: {color: colors.cyan, fontSize: 17, fontWeight: '800'},
  pressed: {opacity: 0.74},
});
