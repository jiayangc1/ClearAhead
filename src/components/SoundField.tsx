import React, {useEffect, useRef} from 'react';
import {Animated, Easing, StyleSheet, Text, View} from 'react-native';
import {colors} from '../config';
import {motion} from './Motion';
import {useReducedMotion} from '../hooks/useReducedMotion';
import type {SpatialEvent} from '../types';

export function SoundField({event}: {event?: SpatialEvent}) {
  const reduceMotion = useReducedMotion();
  const hasEvent = event != null;
  const eventId = event?.id;
  const reveal = useRef(new Animated.Value(event ? 1 : 0)).current;
  const scan = useRef(new Animated.Value(0)).current;
  const pulse = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    if (!hasEvent) {
      reveal.setValue(0);
      return;
    }
    if (reduceMotion) {
      reveal.setValue(1);
      return;
    }
    reveal.setValue(0);
    Animated.spring(reveal, {
      toValue: 1,
      ...motion.spring,
      useNativeDriver: true,
    }).start();
  }, [eventId, hasEvent, reduceMotion, reveal]);

  useEffect(() => {
    if (!hasEvent || reduceMotion) {
      scan.stopAnimation();
      pulse.stopAnimation();
      scan.setValue(0);
      pulse.setValue(reduceMotion && hasEvent ? 0.5 : 0);
      return;
    }
    const scanAnimation = Animated.loop(
      Animated.timing(scan, {
        toValue: 1,
        duration: 1900,
        easing: Easing.inOut(Easing.cubic),
        useNativeDriver: true,
      }),
    );
    const pulseAnimation = Animated.loop(
      Animated.sequence([
        Animated.timing(pulse, {
          toValue: 1,
          duration: 520,
          useNativeDriver: true,
        }),
        Animated.timing(pulse, {
          toValue: 0,
          duration: 720,
          useNativeDriver: true,
        }),
      ]),
    );
    scanAnimation.start();
    pulseAnimation.start();
    return () => {
      scanAnimation.stop();
      pulseAnimation.stop();
    };
  }, [hasEvent, pulse, reduceMotion, scan]);

  return (
    <View pointerEvents="none" accessible={false} importantForAccessibility="no-hide-descendants" style={StyleSheet.absoluteFill}>
      {event ? (
        <Animated.View
          style={[
            styles.directionGlow,
            event.direction === 'left' && styles.directionLeft,
            event.direction === 'center' && styles.directionCenter,
            event.direction === 'right' && styles.directionRight,
            {
              backgroundColor: event.collisionRisk === 'imminent' ? colors.critical : colors.amber,
            },
            {
              opacity: pulse.interpolate({
                inputRange: [0, 1],
                outputRange: [0.035, 0.13],
              }),
              transform: [
                {
                  scale: pulse.interpolate({
                    inputRange: [0, 1],
                    outputRange: [0.92, 1.08],
                  }),
                },
              ],
            },
          ]}
        />
      ) : null}
      {event?.box ? (
        <Animated.View
          style={[
            styles.detectionBox,
            {
              left: `${event.box.x * 100}%`,
              top: `${event.box.y * 100}%`,
              width: `${event.box.width * 100}%`,
              height: `${event.box.height * 100}%`,
            },
            {
              opacity: reveal,
              transform: [
                {
                  scale: reveal.interpolate({
                    inputRange: [0, 1],
                    outputRange: [0.86, 1],
                  }),
                },
              ],
            },
          ]}
        >
          <View style={[styles.corner, styles.topLeft, event.urgency > 0.76 ? styles.criticalCorner : styles.cautionCorner]} />
          <View style={[styles.corner, styles.topRight, event.urgency > 0.76 ? styles.criticalCorner : styles.cautionCorner]} />
          <View style={[styles.corner, styles.bottomLeft, event.urgency > 0.76 ? styles.criticalCorner : styles.cautionCorner]} />
          <View style={[styles.corner, styles.bottomRight, event.urgency > 0.76 ? styles.criticalCorner : styles.cautionCorner]} />
          <Text style={[styles.boxLabel, event.urgency > 0.76 && styles.criticalLabel]}>{event.kind.replace('-', ' ')}</Text>
          <Animated.View
            style={[
              styles.scanLine,
              {
                backgroundColor: event.urgency > 0.76 ? colors.critical : colors.amber,
              },
              {
                transform: [
                  {
                    translateY: scan.interpolate({
                      inputRange: [0, 1],
                      outputRange: [0, 160],
                    }),
                  },
                ],
              },
            ]}
          />
        </Animated.View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  directionGlow: {
    position: 'absolute',
    top: '12%',
    width: '62%',
    height: '58%',
    borderRadius: 999,
  },
  directionLeft: {left: '-22%'},
  directionCenter: {left: '19%'},
  directionRight: {right: '-22%'},
  detectionBox: {position: 'absolute', overflow: 'hidden'},
  corner: {position: 'absolute', width: 20, height: 20},
  cautionCorner: {borderColor: colors.amber},
  criticalCorner: {borderColor: colors.critical},
  topLeft: {left: 0, top: 0, borderLeftWidth: 2, borderTopWidth: 2},
  topRight: {right: 0, top: 0, borderRightWidth: 2, borderTopWidth: 2},
  bottomLeft: {left: 0, bottom: 0, borderLeftWidth: 2, borderBottomWidth: 2},
  bottomRight: {
    right: 0,
    bottom: 0,
    borderRightWidth: 2,
    borderBottomWidth: 2,
  },
  boxLabel: {
    alignSelf: 'flex-start',
    color: colors.night,
    backgroundColor: colors.amber,
    fontSize: 10,
    fontWeight: '800',
    paddingHorizontal: 6,
    paddingVertical: 3,
    textTransform: 'capitalize',
  },
  criticalLabel: {backgroundColor: colors.critical, color: colors.text},
  scanLine: {
    position: 'absolute',
    left: 2,
    right: 2,
    top: 0,
    height: 1,
    opacity: 0.75,
    shadowColor: colors.text,
    shadowOpacity: 0.7,
    shadowRadius: 4,
  },
});
