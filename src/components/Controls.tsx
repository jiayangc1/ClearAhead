import React, {useEffect, useRef} from 'react';
import {Animated, Easing, StyleSheet, Switch, Text, View, type AccessibilityActionEvent} from 'react-native';
import {colors} from '../config';
import {motion, SpringPressable} from './Motion';
import {useReducedMotion} from '../hooks/useReducedMotion';

export function PrimaryButton({label, hint, onPress, destructive = false, disabled = false}: {label: string; hint?: string; onPress: () => void; destructive?: boolean; disabled?: boolean}) {
  const reduceMotion = useReducedMotion();
  const sheen = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    if (reduceMotion || disabled) {
      sheen.stopAnimation();
      sheen.setValue(0);
      return;
    }

    const animation = Animated.loop(
      Animated.sequence([
        Animated.delay(1300),
        Animated.timing(sheen, {
          toValue: 1,
          duration: 740,
          easing: Easing.inOut(Easing.cubic),
          useNativeDriver: true,
        }),
        Animated.delay(1900),
        Animated.timing(sheen, {
          toValue: 0,
          duration: 0,
          useNativeDriver: true,
        }),
      ]),
    );
    animation.start();
    return () => animation.stop();
  }, [disabled, reduceMotion, sheen]);

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
      {!destructive && !disabled ? (
        <Animated.View
          pointerEvents="none"
          style={[
            styles.sheen,
            {
              transform: [
                {
                  translateX: sheen.interpolate({
                    inputRange: [0, 1],
                    outputRange: [-130, 430],
                  }),
                },
                {rotate: '-18deg'},
              ],
            },
          ]}
        />
      ) : null}
    </SpringPressable>
  );
}

export function ToggleRow({label, description, value, onValueChange}: {label: string; description: string; value: boolean; onValueChange: (value: boolean) => void}) {
  const reduceMotion = useReducedMotion();
  const emphasis = useRef(new Animated.Value(1)).current;
  const previousValue = useRef(value);

  useEffect(() => {
    if (previousValue.current === value) {
      return;
    }
    previousValue.current = value;
    if (reduceMotion) {
      return;
    }
    Animated.sequence([
      Animated.spring(emphasis, {
        toValue: 1.025,
        ...motion.spring,
        useNativeDriver: true,
      }),
      Animated.spring(emphasis, {
        toValue: 1,
        ...motion.spring,
        useNativeDriver: true,
      }),
    ]).start();
  }, [emphasis, reduceMotion, value]);

  return (
    <Animated.View style={[styles.row, {transform: [{scale: emphasis}]}]} accessible={false}>
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
    </Animated.View>
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
      <View>
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
    minHeight: 58,
    borderRadius: 9,
    backgroundColor: colors.cyan,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 22,
    overflow: 'hidden',
  },
  destructiveButton: {backgroundColor: colors.critical},
  primaryButtonText: {
    color: colors.night,
    fontSize: 18,
    lineHeight: 25,
    fontWeight: '800',
  },
  disabled: {opacity: 0.4},
  sheen: {
    position: 'absolute',
    top: -24,
    bottom: -24,
    width: 44,
    backgroundColor: '#FFFFFF38',
  },
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
  rowLabel: {
    color: colors.text,
    fontSize: 18,
    lineHeight: 23,
    fontWeight: '700',
  },
  rowDescription: {
    color: colors.muted,
    fontSize: 15,
    lineHeight: 21,
    marginTop: 3,
  },
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
  stepText: {
    color: colors.text,
    fontSize: 28,
    lineHeight: 30,
    fontWeight: '600',
  },
});
