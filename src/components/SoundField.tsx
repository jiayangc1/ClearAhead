import React, { useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import Svg, { Path } from 'react-native-svg';
import { colors } from '../config';
import type { BoundingBoxVerbosity, ScenePayload } from '../types';
import { projectSceneBox } from '../utils/sceneProjection';

export const SoundField = React.memo(function SoundFieldView({
  scene, showBoundingBoxes, boundingBoxVerbosity,
}: {
  scene?: ScenePayload;
  showBoundingBoxes: boolean;
  boundingBoxVerbosity: BoundingBoxVerbosity;
}) {
  const [viewAspect, setViewAspect] = useState(9 / 16);
  const imageAspect = scene?.imageAspectRatio ?? 9 / 16;
  const sources = showBoundingBoxes && scene?.state === 'available'
    // Nothing is drawn for ordinary scenery; only Verbose shows every source.
    // A hazard that has left the view has no outline; the card reports it.
    ? scene.sources.filter(source => !source.outOfView && (boundingBoxVerbosity === 'verbose'
      || (boundingBoxVerbosity === 'less' ? source.collisionRisk === 'imminent' : source.collisionRisk !== 'none'))) : [];
  return (
    <View pointerEvents="none" accessible={false} importantForAccessibility="no-hide-descendants"
      style={styles.field} onLayout={({ nativeEvent: { layout } }) => {
        if (layout.height > 0) setViewAspect(layout.width / layout.height);
      }}>
      <Svg width="100%" height="100%" viewBox={`0 0 ${imageAspect} 1`} preserveAspectRatio="xMidYMid slice">
        {sources.map(source => {
          const color = source.collisionRisk === 'imminent' ? colors.coral
            : source.collisionRisk === 'caution' ? colors.peach : colors.accent;
          const path = source.contours.map(contour => contour.map((point, index) =>
            `${index ? 'L' : 'M'}${point.x * imageAspect},${point.y}`).join(' ') + ' Z').join(' ');
          return <Path key={source.id} d={path} fill={color} fillOpacity={0.22} fillRule="evenodd" stroke={color} strokeWidth={0.004} />;
        })}
      </Svg>
      {sources.map(source => {
        if (!source.box) return null;
        const box = projectSceneBox(source.box, imageAspect, viewAspect);
        return (
          <View key={source.id} style={[styles.labelPosition, {
            left: `${Math.max(0, box.x) * 100}%`, top: `${Math.max(0, box.y) * 100}%`,
          }]}>
            <Text style={styles.label}>
              {source.label ?? 'surface'} · ~{source.approximateDistanceMeters?.toFixed(1)} m
              {boundingBoxVerbosity === 'verbose' ? ` · ${Math.round(source.confidence * 100)}%` : ''}
            </Text>
          </View>
        );
      })}
    </View>
  );
});

const styles = StyleSheet.create({
  field: { position: 'absolute', top: 0, right: 0, bottom: 0, left: 0, overflow: 'hidden' },
  labelPosition: { position: 'absolute' },
  label: {
    color: colors.ink, backgroundColor: '#FAF7F2E6', fontSize: 12, fontWeight: '600',
    paddingHorizontal: 8, paddingVertical: 4, borderRadius: 10, overflow: 'hidden',
  },
});
