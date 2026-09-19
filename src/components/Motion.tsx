import React, {useEffect, useRef} from 'react';
import {Animated, Easing, Pressable, type PressableProps, type StyleProp, type ViewStyle} from 'react-native';
import {useReducedMotion} from '../hooks/useReducedMotion';

export const motion = {
  quick: 160,
  standard: 320,
  reveal: 560,
  spring: {damping: 15, stiffness: 220, mass: 0.75},
} as const;

export function Entrance({
  children,
  delay = 0,
  distance = 18,
  scaleFrom = 0.98,
  style,
}: {
  children: React.ReactNode;
  delay?: number;
  distance?: number;
  scaleFrom?: number;
  style?: StyleProp<ViewStyle>;
}) {
  const reduceMotion = useReducedMotion();
  const progress = useRef(new Animated.Value(reduceMotion ? 1 : 0)).current;

  useEffect(() => {
    if (reduceMotion) {
      progress.setValue(1);
      return;
    }

    progress.setValue(0);
    Animated.timing(progress, {
      toValue: 1,
      duration: motion.reveal,
      delay,
      easing: Easing.out(Easing.cubic),
      useNativeDriver: true,
    }).start();
  }, [delay, progress, reduceMotion]);

  return (
    <Animated.View
      style={[
        style,
        {
          opacity: progress,
          transform: [
            {
              translateY: progress.interpolate({
                inputRange: [0, 1],
                outputRange: [distance, 0],
              }),
            },
            {
              scale: progress.interpolate({
                inputRange: [0, 1],
                outputRange: [scaleFrom, 1],
              }),
            },
          ],
        },
      ]}
    >
      {children}
    </Animated.View>
  );
}

export function SpringPressable({
  children,
  style,
  containerStyle,
  pressedScale = 0.965,
  disabled,
  onPressIn,
  onPressOut,
  ...props
}: PressableProps & {
  containerStyle?: StyleProp<ViewStyle>;
  pressedScale?: number;
}) {
  const reduceMotion = useReducedMotion();
  const scale = useRef(new Animated.Value(1)).current;

  const springTo = (value: number) => {
    if (reduceMotion) {
      scale.setValue(1);
      return;
    }
    Animated.spring(scale, {
      toValue: value,
      ...motion.spring,
      useNativeDriver: true,
    }).start();
  };

  return (
    <Animated.View style={[containerStyle, {transform: [{scale}]}]} renderToHardwareTextureAndroid={!reduceMotion}>
      <Pressable
        {...props}
        disabled={disabled}
        onPressIn={event => {
          springTo(pressedScale);
          onPressIn?.(event);
        }}
        onPressOut={event => {
          springTo(1);
          onPressOut?.(event);
        }}
        style={style}
      >
        {children}
      </Pressable>
    </Animated.View>
  );
}

export function Pulse({children, minScale = 0.82, duration = 1200, style}: {children: React.ReactNode; minScale?: number; duration?: number; style?: StyleProp<ViewStyle>}) {
  const reduceMotion = useReducedMotion();
  const progress = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    if (reduceMotion) {
      progress.stopAnimation();
      progress.setValue(1);
      return;
    }

    const animation = Animated.loop(
      Animated.sequence([
        Animated.timing(progress, {
          toValue: 1,
          duration,
          easing: Easing.inOut(Easing.sin),
          useNativeDriver: true,
        }),
        Animated.timing(progress, {
          toValue: 0,
          duration,
          easing: Easing.inOut(Easing.sin),
          useNativeDriver: true,
        }),
      ]),
    );
    animation.start();
    return () => animation.stop();
  }, [duration, progress, reduceMotion]);

  return (
    <Animated.View
      style={[
        style,
        {
          opacity: progress.interpolate({
            inputRange: [0, 1],
            outputRange: [0.66, 1],
          }),
          transform: [
            {
              scale: progress.interpolate({
                inputRange: [0, 1],
                outputRange: [minScale, 1],
              }),
            },
          ],
        },
      ]}
    >
      {children}
    </Animated.View>
  );
}
