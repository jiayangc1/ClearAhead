import React, {useEffect, useRef} from 'react';
import {Animated, StyleSheet, Switch, Text, View, type AccessibilityActionEvent} from 'react-native';
import {colors} from '../config';
import {motion, SpringPressable} from './Motion';
import {useReducedMotion} from '../hooks/useReducedMotion';

export function PrimaryButton({label, hint, onPress, destructive = false, disabled = false}: {label: string; hint?: string; onPress: () => void; destructive?: boolean; disabled?: boolean}) {
  return (
    <SpringPressable
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityHint={hint}
      disabled={disabled}
      onPress={onPress}
      style={[styles.primaryButton, destructive && styles.destructiveButton, disabled && styles.disabled]}
    >
      <Text style={styles.primaryButtonText}>{label}</Text>
    </SpringPressable>
  );
}

export function ToggleRow({label, description, value, onValueChange, disabled = false}: {label: string; description?: string; value: boolean; onValueChange: (value: boolean) => void; disabled?: boolean}) {
  return (
    <View style={styles.row} accessible={false}>
      <View style={styles.rowCopy}>
        <Text style={styles.rowLabel}>{label}</Text>
        {description ? <Text style={styles.rowDescription}>{description}</Text> : null}
      </View>
      <Switch
        accessibilityLabel={label}
        accessibilityHint={description}
        disabled={disabled}
        value={value}
        onValueChange={onValueChange}
        trackColor={{false: colors.line, true: colors.accentStrong}}
        ios_backgroundColor={colors.line}
        thumbColor={colors.surface}
      />
    </View>
  );
}

/** Two or three mutually exclusive choices shown side by side. */
export function SegmentedRow<T extends string>({label, options, value, onChange}: {label: string; options: ReadonlyArray<{value: T; label: string}>; value: T; onChange: (value: T) => void}) {
  return (
    <View style={styles.segmentedRow}>
      <Text style={styles.rowLabel}>{label}</Text>
      <View accessibilityRole="radiogroup" accessibilityLabel={label} style={styles.segments}>
        {options.map(option => {
          const selected = option.value === value;
          return (
            <SpringPressable
              key={option.value}
              accessibilityRole="radio"
              accessibilityLabel={option.label}
              accessibilityState={{checked: selected}}
              onPress={() => onChange(option.value)}
              containerStyle={styles.segmentContainer}
              style={[styles.segment, selected && styles.segmentSelected]}
            >
              <Text style={[styles.segmentText, selected && styles.segmentTextSelected]}>{option.label}</Text>
            </SpringPressable>
          );
        })}
      </View>
    </View>
  );
}

export function AdjustableRow({label, valueLabel, onIncrement, onDecrement}: {label: string; valueLabel: string; onIncrement: () => void; onDecrement: () => void}) {
  const reduceMotion = useReducedMotion();
  const valueScale = useRef(new Animated.Value(1)).current;
  const previousValue = useRef(valueLabel);

  useEffect(() => {
    if (previousValue.current === valueLabel) {
      return;
    }
    previousValue.current = valueLabel;
    if (reduceMotion) {
      return;
    }
    valueScale.setValue(0.88);
    Animated.spring(valueScale, {
      toValue: 1,
      ...motion.spring,
      useNativeDriver: true,
    }).start();
  }, [reduceMotion, valueLabel, valueScale]);

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
      style={styles.adjustable}
    >
      <View style={styles.rowCopy}>
        <Text style={styles.rowLabel}>{label}</Text>
        <Animated.Text style={[styles.adjustableValue, {transform: [{scale: valueScale}]}]}>{valueLabel}</Animated.Text>
      </View>
      <View style={styles.stepper} accessible={false}>
        <SpringPressable accessibilityElementsHidden importantForAccessibility="no-hide-descendants" hitSlop={8} onPress={onDecrement} style={styles.stepButton}>
          <Text style={styles.stepText}>−</Text>
        </SpringPressable>
        <SpringPressable accessibilityElementsHidden importantForAccessibility="no-hide-descendants" hitSlop={8} onPress={onIncrement} style={styles.stepButton}>
          <Text style={styles.stepText}>+</Text>
        </SpringPressable>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  primaryButton: {
    minHeight: 64,
    borderRadius: 32,
    backgroundColor: colors.accent,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 24,
  },
  destructiveButton: {backgroundColor: colors.coral},
  primaryButtonText: {
    color: colors.ink,
    fontSize: 19,
    lineHeight: 25,
    fontWeight: '700',
  },
  disabled: {opacity: 0.45},
  row: {
    minHeight: 60,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 16,
    paddingVertical: 10,
  },
  rowCopy: {flex: 1},
  rowLabel: {
    color: colors.ink,
    fontSize: 17,
    lineHeight: 22,
    fontWeight: '600',
  },
  rowDescription: {
    color: colors.muted,
    fontSize: 14,
    lineHeight: 19,
    marginTop: 2,
  },
  segmentedRow: {paddingVertical: 10, gap: 10},
  segments: {
    flexDirection: 'row',
    gap: 4,
    padding: 4,
    borderRadius: 16,
    backgroundColor: colors.surfaceRaised,
  },
  segmentContainer: {flex: 1},
  segment: {
    minHeight: 44,
    borderRadius: 12,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 8,
  },
  segmentSelected: {backgroundColor: colors.accent},
  segmentText: {color: colors.muted, fontSize: 15, fontWeight: '600', textAlign: 'center'},
  segmentTextSelected: {color: colors.ink, fontWeight: '700'},
  adjustable: {
    minHeight: 60,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 16,
    paddingVertical: 8,
  },
  adjustableValue: {
    alignSelf: 'flex-start',
    color: colors.accentInk,
    fontSize: 15,
    fontWeight: '600',
    fontVariant: ['tabular-nums'],
    marginTop: 2,
  },
  stepper: {flexDirection: 'row', gap: 8},
  stepButton: {
    width: 48,
    height: 48,
    borderRadius: 24,
    backgroundColor: colors.surfaceRaised,
    alignItems: 'center',
    justifyContent: 'center',
  },
  stepText: {
    color: colors.ink,
    fontSize: 26,
    lineHeight: 30,
    fontWeight: '500',
  },
});
