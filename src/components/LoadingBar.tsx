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
  container: { width: '100%', alignSelf: 'center', gap: 10, paddingVertical: 4 },
  track: { height: 8, borderRadius: 4, overflow: 'hidden', backgroundColor: colors.line },
  fill: { height: '100%', borderRadius: 4, backgroundColor: colors.accentStrong },
  text: { color: colors.muted, fontSize: 13, textAlign: 'center' },
});
