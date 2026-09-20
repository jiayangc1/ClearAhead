import React from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { colors } from '../config';
import type { ObjectDetectionOverlay, SpatialEvent } from '../types';

export function SoundField({
  event,
  detections,
  showBoundingBoxes,
}: {
  event?: SpatialEvent;
  detections: ObjectDetectionOverlay[];
  showBoundingBoxes: boolean;
}) {
  return (
    <View
      pointerEvents="none"
      accessible={false}
      importantForAccessibility="no-hide-descendants"
      style={StyleSheet.absoluteFill}
    >
      {event ? (
        <View
          style={[
            styles.directionGlow,
            event.direction === 'left' && styles.directionLeft,
            event.direction === 'center' && styles.directionCenter,
            event.direction === 'right' && styles.directionRight,
            {
              backgroundColor:
                event.collisionRisk === 'imminent'
                  ? colors.critical
                  : colors.amber,
            },
          ]}
        />
      ) : null}
      {showBoundingBoxes
        ? detections.map((detection, index) => (
            <View
              key={`${detection.label}-${index}`}
              style={[
                styles.detectionBox,
                {
                  left: `${detection.box.x * 100}%`,
                  top: `${detection.box.y * 100}%`,
                  width: `${detection.box.width * 100}%`,
                  height: `${detection.box.height * 100}%`,
                },
              ]}
            >
              <View
                style={[styles.corner, styles.topLeft, styles.cautionCorner]}
              />
              <View
                style={[styles.corner, styles.topRight, styles.cautionCorner]}
              />
              <View
                style={[styles.corner, styles.bottomLeft, styles.cautionCorner]}
              />
              <View
                style={[
                  styles.corner,
                  styles.bottomRight,
                  styles.cautionCorner,
                ]}
              />
              <Text style={styles.boxLabel} numberOfLines={1}>
                {detection.label.toUpperCase()}{' '}
                {Math.round(detection.confidence * 100)}%
              </Text>
            </View>
          ))
        : null}
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
  directionLeft: { left: '-22%' },
  directionCenter: { left: '19%' },
  directionRight: { right: '-22%' },
  detectionBox: { position: 'absolute', overflow: 'hidden' },
  corner: { position: 'absolute', width: 20, height: 20 },
  cautionCorner: { borderColor: colors.amber },
  criticalCorner: { borderColor: colors.critical },
  topLeft: { left: 0, top: 0, borderLeftWidth: 2, borderTopWidth: 2 },
  topRight: { right: 0, top: 0, borderRightWidth: 2, borderTopWidth: 2 },
  bottomLeft: { left: 0, bottom: 0, borderLeftWidth: 2, borderBottomWidth: 2 },
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
  criticalLabel: { backgroundColor: colors.critical, color: colors.text },
});
