import React from 'react';
import {Pressable, StyleSheet, Text, View} from 'react-native';
import {
  House,
  ScanEye,
  Settings,
  type LucideIcon,
} from 'lucide-react-native';
import {colors} from '../config';

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
        icon={House}
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
        <View
          accessibilityElementsHidden
          importantForAccessibility="no-hide-descendants">
          <ScanEye color={colors.cyan} size={23} strokeWidth={2.4} />
        </View>
        <Text style={styles.assistLabel}>Assist</Text>
      </Pressable>
      <NavigationItem
        icon={Settings}
        label="Settings"
        selected={active === 'settings'}
        onPress={onSettings}
      />
    </View>
  );
}

function NavigationItem({
  icon: Icon,
  label,
  selected,
  onPress,
}: {
  icon: LucideIcon;
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
        importantForAccessibility="no-hide-descendants">
        <Icon
          color={selected ? colors.cyan : colors.muted}
          size={22}
          strokeWidth={selected ? 2.4 : 2}
        />
      </View>
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
    paddingTop: 8,
    paddingBottom: 6,
  },
  item: {
    flex: 1,
    minHeight: 58,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 5,
  },
  label: {color: colors.muted, fontSize: 13, fontWeight: '600'},
  labelSelected: {color: colors.text},
  assistItem: {
    flex: 1,
    minHeight: 58,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 5,
    marginHorizontal: 4,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: colors.cyan,
    backgroundColor: colors.surfaceRaised,
  },
  assistLabel: {color: colors.text, fontSize: 15, fontWeight: '800'},
  pressed: {opacity: 0.7},
  disabled: {opacity: 0.4},
});
