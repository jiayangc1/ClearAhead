import React from 'react';
import {Image, StyleSheet} from 'react-native';

const logo = require('../../assets/clear-ahead-logo.png');

export function BrandLogo({
  width = 72,
  accessible = true,
}: {
  width?: number;
  accessible?: boolean;
}) {
  return (
    <Image
      source={logo}
      accessible={accessible}
      accessibilityLabel={accessible ? 'Clear Ahead' : undefined}
      resizeMode="contain"
      style={[styles.logo, {width, height: width * 0.885}]}
    />
  );
}

const styles = StyleSheet.create({
  logo: {alignSelf: 'flex-start'},
});
