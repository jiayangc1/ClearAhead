import React from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { colors } from '../config';

export function LoadingBar({ progress, message }: { progress: number; message: string }) {
  const percent = Math.round(Math.min(Math.max(progress, 0), 1) * 100);
  return (
    <View style={styles.container} accessibilityRole="progressbar" accessibilityLabel={message}
      accessibilityValue={{ min: 0, max: 100, now: percent }}>
      <View style={styles.track}><View style={[styles.fill, { width: `${percent}%` }]} /></View>
      <Text style={styles.text}>{message} · {percent}%</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { width: '85%', alignSelf: 'center', gap: 8 },
  track: { height: 6, borderRadius: 3, overflow: 'hidden', backgroundColor: colors.line },
  fill: { height: '100%', backgroundColor: colors.cyan },
  text: { color: colors.muted, fontSize: 13, textAlign: 'center' },
});
