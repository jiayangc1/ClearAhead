import React from 'react';
import {StyleSheet, Text, View} from 'react-native';
import {colors} from '../config';
import type {Direction, SpatialEvent} from '../types';

const directions: Direction[] = ['left', 'center', 'right'];

export function SoundField({event}: {event?: SpatialEvent}) {
  return (
    <View
      pointerEvents="none"
      accessible={false}
      importantForAccessibility="no-hide-descendants"
      style={StyleSheet.absoluteFill}>
      <View style={styles.sectors}>
        {directions.map(direction => (
          <View
            key={direction}
            style={[
              styles.sector,
              direction !== 'right' && styles.sectorDivider,
              event?.direction === direction && styles.activeSector,
            ]}>
            <Text style={styles.directionLabel}>{direction.toUpperCase()}</Text>
          </View>
        ))}
      </View>
      <View style={styles.horizon} />
      {event?.box ? (
        <View
          style={[
            styles.detectionBox,
            {
              left: `${event.box.x * 100}%`,
              top: `${event.box.y * 100}%`,
              width: `${event.box.width * 100}%`,
              height: `${event.box.height * 100}%`,
              borderColor:
                event.urgency > 0.76 ? colors.critical : colors.amber,
            },
          ]}>
          <Text style={styles.boxLabel} numberOfLines={1}>
            {(event.label ?? event.kind).toUpperCase()}
          </Text>
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  sectors: {flex: 1, flexDirection: 'row'},
  sector: {flex: 1, paddingTop: 14, alignItems: 'center'},
  sectorDivider: {borderRightWidth: 1, borderRightColor: '#F7FBFF44'},
  activeSector: {backgroundColor: '#55D6FF22'},
  directionLabel: {
    color: '#F7FBFFAA',
    fontSize: 11,
    fontWeight: '800',
    letterSpacing: 1.8,
  },
  horizon: {
    position: 'absolute',
    left: 20,
    right: 20,
    top: '62%',
    height: 1,
    backgroundColor: '#F7FBFF55',
  },
  detectionBox: {position: 'absolute', borderWidth: 3, borderRadius: 12},
  boxLabel: {
    alignSelf: 'flex-start',
    color: colors.night,
    backgroundColor: colors.amber,
    fontSize: 11,
    fontWeight: '900',
    paddingHorizontal: 6,
    paddingVertical: 3,
  },
});
