import React from 'react';
import {
  Pressable,
  StyleSheet,
  Switch,
  Text,
  View,
  type AccessibilityActionEvent,
} from 'react-native';
import {colors} from '../config';

export function PrimaryButton({
  label,
  hint,
  onPress,
  destructive = false,
  disabled = false,
}: {
  label: string;
  hint?: string;
  onPress: () => void;
  destructive?: boolean;
  disabled?: boolean;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityHint={hint}
      disabled={disabled}
      onPress={onPress}
      style={({pressed}) => [
        styles.primaryButton,
        destructive && styles.destructiveButton,
        disabled && styles.disabled,
        pressed && styles.pressed,
      ]}>
      <Text style={styles.primaryButtonText}>{label}</Text>
    </Pressable>
  );
}

export function ToggleRow({
  label,
  description,
  value,
  onValueChange,
}: {
  label: string;
  description: string;
  value: boolean;
  onValueChange: (value: boolean) => void;
}) {
  return (
    <View style={styles.row} accessible={false}>
      <View style={styles.rowCopy}>
        <Text style={styles.rowLabel}>{label}</Text>
        <Text style={styles.rowDescription}>{description}</Text>
      </View>
      <Switch
        accessibilityLabel={label}
        accessibilityHint={description}
        value={value}
        onValueChange={onValueChange}
        trackColor={{false: colors.line, true: colors.cyan}}
        thumbColor={value ? colors.night : colors.text}
      />
    </View>
  );
}

export function AdjustableRow({
  label,
  valueLabel,
  onIncrement,
  onDecrement,
}: {
  label: string;
  valueLabel: string;
  onIncrement: () => void;
  onDecrement: () => void;
}) {
  const onAccessibilityAction = (event: AccessibilityActionEvent) => {
    if (event.nativeEvent.actionName === 'increment') {
      onIncrement();
    } else if (event.nativeEvent.actionName === 'decrement') {
      onDecrement();
    }
  };

  return (
    <View
      accessible
      accessibilityRole="adjustable"
      accessibilityLabel={label}
      accessibilityValue={{text: valueLabel}}
      accessibilityActions={[
        {name: 'increment', label: `Increase ${label}`},
        {name: 'decrement', label: `Decrease ${label}`},
      ]}
      onAccessibilityAction={onAccessibilityAction}
      style={styles.adjustable}>
      <View>
        <Text style={styles.rowLabel}>{label}</Text>
        <Text style={styles.adjustableValue}>{valueLabel}</Text>
      </View>
      <View style={styles.stepper} accessible={false}>
        <Pressable
          accessibilityElementsHidden
          importantForAccessibility="no-hide-descendants"
          hitSlop={8}
          onPress={onDecrement}
          style={styles.stepButton}>
          <Text style={styles.stepText}>−</Text>
        </Pressable>
        <Pressable
          accessibilityElementsHidden
          importantForAccessibility="no-hide-descendants"
          hitSlop={8}
          onPress={onIncrement}
          style={styles.stepButton}>
          <Text style={styles.stepText}>+</Text>
        </Pressable>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  primaryButton: {
    minHeight: 58,
    borderRadius: 9,
    backgroundColor: colors.cyan,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 22,
  },
  destructiveButton: {backgroundColor: colors.critical},
  primaryButtonText: {
    color: colors.night,
    fontSize: 18,
    lineHeight: 25,
    fontWeight: '800',
  },
  pressed: {opacity: 0.74},
  disabled: {opacity: 0.4},
  row: {
    minHeight: 78,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 16,
    paddingVertical: 12,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.line,
  },
  rowCopy: {flex: 1},
  rowLabel: {color: colors.text, fontSize: 18, lineHeight: 23, fontWeight: '700'},
  rowDescription: {color: colors.muted, fontSize: 15, lineHeight: 21, marginTop: 3},
  adjustable: {
    minHeight: 80,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 16,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.line,
  },
  adjustableValue: {
    color: colors.cyan,
    fontSize: 17,
    fontVariant: ['tabular-nums'],
    marginTop: 4,
  },
  stepper: {flexDirection: 'row', gap: 8},
  stepButton: {
    width: 48,
    height: 48,
    borderRadius: 8,
    backgroundColor: colors.surfaceRaised,
    alignItems: 'center',
    justifyContent: 'center',
  },
  stepText: {color: colors.text, fontSize: 28, lineHeight: 30, fontWeight: '600'},
});
