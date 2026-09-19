import React from 'react';
import {Pressable, StyleSheet, Text, View} from 'react-native';
import {colors} from '../config';
import {BrandLogo} from './BrandLogo';

type Tab = 'home' | 'assist' | 'settings';

export function BottomNavigation({
  active,
  onHome,
  onAssist,
  onSettings,
  assistDisabled = false,
}: {
  active: Exclude<Tab, 'assist'>;
  onHome: () => void;
  onAssist: () => void;
  onSettings: () => void;
  assistDisabled?: boolean;
}) {
  return (
    <View accessibilityRole="tablist" style={styles.navigation}>
      <NavigationItem
        label="Home"
        selected={active === 'home'}
        onPress={onHome}
      />
      <Pressable
        accessibilityRole="tab"
        accessibilityLabel={assistDisabled ? 'Assist unavailable' : 'Start Assist Mode'}
        accessibilityHint={assistDisabled ? 'Camera access is required' : 'Starts the camera and environmental feedback'}
        accessibilityState={{selected: false, disabled: assistDisabled}}
        disabled={assistDisabled}
        onPress={onAssist}
        style={({pressed}) => [
          styles.assistItem,
          assistDisabled && styles.disabled,
          pressed && styles.pressed,
        ]}>
        <BrandLogo width={24} accessible={false} />
        <Text style={styles.assistLabel}>Assist</Text>
      </Pressable>
      <NavigationItem
        label="Settings"
        selected={active === 'settings'}
        onPress={onSettings}
      />
    </View>
  );
}

function NavigationItem({
  label,
  selected,
  onPress,
}: {
  label: string;
  selected: boolean;
  onPress: () => void;
}) {
  return (
    <Pressable
      accessibilityRole="tab"
      accessibilityLabel={label}
      accessibilityState={{selected}}
      onPress={onPress}
      style={({pressed}) => [styles.item, pressed && styles.pressed]}>
      <View
        accessibilityElementsHidden
        style={[styles.indicator, selected && styles.indicatorSelected]}
      />
      <Text style={[styles.label, selected && styles.labelSelected]}>{label}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  navigation: {
    minHeight: 72,
    flexDirection: 'row',
    alignItems: 'stretch',
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.line,
    backgroundColor: '#080808FA',
    paddingHorizontal: 8,
    paddingTop: 7,
  },
  item: {
    flex: 1,
    minHeight: 58,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 9,
  },
  indicator: {
    width: 18,
    height: 2,
    borderRadius: 1,
    backgroundColor: colors.line,
  },
  indicatorSelected: {backgroundColor: colors.cyan},
  label: {color: colors.muted, fontSize: 13, fontWeight: '600'},
  labelSelected: {color: colors.text},
  assistItem: {
    flex: 1.15,
    minHeight: 58,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: colors.cyan,
    backgroundColor: colors.surfaceRaised,
  },
  assistLabel: {color: colors.text, fontSize: 15, fontWeight: '800'},
  pressed: {opacity: 0.7},
  disabled: {opacity: 0.4},
});
