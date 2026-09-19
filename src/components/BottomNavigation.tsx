import React from 'react';
import {StyleSheet, Text, View} from 'react-native';
import {House, ScanEye, Settings, type LucideIcon} from 'lucide-react-native';
import {colors} from '../config';
import {SpringPressable} from './Motion';

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
      <NavigationItem icon={House} label="Home" selected={active === 'home'} onPress={onHome} />
      <SpringPressable
        accessibilityRole="tab"
        accessibilityLabel={assistDisabled ? 'Assist unavailable' : 'Start Assist Mode'}
        accessibilityHint={assistDisabled ? 'Camera access is required' : 'Starts the camera and environmental feedback'}
        accessibilityState={{selected: false, disabled: assistDisabled}}
        disabled={assistDisabled}
        onPress={onAssist}
        containerStyle={styles.assistItemContainer}
        pressedScale={0.93}
        style={[styles.assistItem, assistDisabled && styles.disabled]}
      >
        <View style={styles.assistContent}>
          <View accessibilityElementsHidden importantForAccessibility="no-hide-descendants">
            <ScanEye color={colors.cyan} size={24} strokeWidth={2.4} />
          </View>
          <Text style={styles.assistLabel}>Assist</Text>
        </View>
      </SpringPressable>
      <NavigationItem icon={Settings} label="Settings" selected={active === 'settings'} onPress={onSettings} />
    </View>
  );
}

function NavigationItem({icon: Icon, label, selected, onPress}: {icon: LucideIcon; label: string; selected: boolean; onPress: () => void}) {
  return (
    <SpringPressable accessibilityRole="tab" accessibilityLabel={label} accessibilityState={{selected}} onPress={onPress} containerStyle={styles.item} pressedScale={0.9} style={styles.itemContent}>
      {selected ? <View style={styles.selectedGlow} /> : null}
      <View accessibilityElementsHidden importantForAccessibility="no-hide-descendants">
        <Icon color={selected ? colors.cyan : colors.muted} size={22} strokeWidth={selected ? 2.4 : 2} />
      </View>
      <Text style={[styles.label, selected && styles.labelSelected]}>{label}</Text>
    </SpringPressable>
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
  },
  itemContent: {
    flex: 1,
    minHeight: 58,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 5,
  },
  label: {color: colors.muted, fontSize: 13, fontWeight: '600'},
  labelSelected: {color: colors.text},
  selectedGlow: {
    position: 'absolute',
    top: 1,
    width: 34,
    height: 3,
    borderRadius: 2,
    backgroundColor: colors.cyan,
    shadowColor: colors.cyan,
    shadowOpacity: 0.8,
    shadowRadius: 8,
  },
  assistItemContainer: {
    flex: 1,
    marginTop: -8,
    marginBottom: -6,
    marginHorizontal: 5,
  },
  assistItem: {
    flex: 1,
    minHeight: 58,
    borderTopLeftRadius: 22,
    borderTopRightRadius: 22,
    backgroundColor: '#13253A',
    overflow: 'hidden',
  },
  assistContent: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 5,
    paddingTop: 7,
  },
  assistLabel: {color: colors.text, fontSize: 15, fontWeight: '800'},
  disabled: {opacity: 0.4},
});
