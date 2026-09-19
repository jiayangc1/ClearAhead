import React from 'react';
import {StyleSheet, Text, View} from 'react-native';
import {colors} from '../config';
import type {SpatialEvent} from '../types';

export function SoundField({event}: {event?: SpatialEvent}) {
  return (
    <View pointerEvents="none" accessible={false} importantForAccessibility="no-hide-descendants" style={StyleSheet.absoluteFill}>
      {event ? (
        <View
          style={[
            styles.directionGlow,
            event.direction === 'left' && styles.directionLeft,
            event.direction === 'center' && styles.directionCenter,
            event.direction === 'right' && styles.directionRight,
            {
              backgroundColor: event.collisionRisk === 'imminent' ? colors.critical : colors.amber,
            },
          ]}
        />
      ) : null}
      {event?.box ? (
        <View
          style={[
            styles.detectionBox,
            {
              left: `${event.box.x * 100}%`,
              top: `${event.box.y * 100}%`,
              width: `${event.box.width * 100}%`,
              height: `${event.box.height * 100}%`,
            },
          ]}
        >
          <View style={[styles.corner, styles.topLeft, event.urgency > 0.76 ? styles.criticalCorner : styles.cautionCorner]} />
          <View style={[styles.corner, styles.topRight, event.urgency > 0.76 ? styles.criticalCorner : styles.cautionCorner]} />
          <View style={[styles.corner, styles.bottomLeft, event.urgency > 0.76 ? styles.criticalCorner : styles.cautionCorner]} />
          <View style={[styles.corner, styles.bottomRight, event.urgency > 0.76 ? styles.criticalCorner : styles.cautionCorner]} />
          <Text style={[styles.boxLabel, event.urgency > 0.76 && styles.criticalLabel]}>{event.kind.replace('-', ' ')}</Text>
        </View>
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
    opacity: 0.08,
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
});
