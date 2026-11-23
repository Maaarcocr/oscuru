import Slider from '@react-native-community/slider';
import { memo, type ReactNode } from 'react';
import { Pressable, StyleSheet, Text, View, type StyleProp, type ViewStyle } from 'react-native';

import { Icon, type IconName } from './icons';
import { colors, radius, spacing } from './theme';

export function IconButton(props: {
  icon: IconName;
  label: string;
  onPress?: () => void;
  onPressIn?: () => void;
  onPressOut?: () => void;
  disabled?: boolean;
  active?: boolean;
  testID?: string;
  size?: number;
}) {
  const tint = props.disabled ? colors.faint : props.active ? colors.accent : colors.text;
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={props.label}
      accessibilityState={{ disabled: props.disabled, selected: props.active }}
      testID={props.testID}
      disabled={props.disabled}
      hitSlop={6}
      onPress={props.onPress}
      onPressIn={props.onPressIn}
      onPressOut={props.onPressOut}
      style={({ pressed }) => [styles.iconButton, pressed && styles.pressed]}>
      <Icon name={props.icon} size={props.size ?? 22} color={tint} />
    </Pressable>
  );
}

export function Chip(props: { label: string; selected?: boolean; onPress: () => void; swatch?: string; testID?: string }) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityState={{ selected: props.selected }}
      testID={props.testID}
      onPress={props.onPress}
      style={({ pressed }) => [styles.chip, props.selected && styles.chipSelected, pressed && styles.pressed]}>
      {props.swatch ? <View style={[styles.swatch, { backgroundColor: props.swatch }]} /> : null}
      <Text style={[styles.chipText, props.selected && styles.chipTextSelected]}>{props.label}</Text>
    </Pressable>
  );
}

export function TextButton(props: { label: string; onPress: () => void; tone?: 'accent' | 'plain' | 'danger'; disabled?: boolean; testID?: string; style?: StyleProp<ViewStyle> }) {
  const tone = props.tone ?? 'plain';
  return (
    <Pressable
      accessibilityRole="button"
      testID={props.testID}
      disabled={props.disabled}
      onPress={props.onPress}
      style={({ pressed }) => [styles.textButton, tone === 'accent' && styles.textButtonAccent, props.disabled && styles.disabled, pressed && styles.pressed, props.style]}>
      <Text style={[styles.textButtonLabel, tone === 'accent' && styles.textButtonLabelAccent, tone === 'danger' && { color: colors.danger }]}>{props.label}</Text>
    </Pressable>
  );
}

export function SectionTitle(props: { children: ReactNode; action?: ReactNode }) {
  return (
    <View style={styles.sectionTitle}>
      <Text style={styles.sectionTitleText}>{props.children}</Text>
      {props.action}
    </View>
  );
}

export interface SliderRowProps {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  /** The value a double tap on the label goes back to. */
  resetTo: number;
  onChange: (value: number) => void;
  /** Called when the finger lifts (and after a reset). */
  onCommit: () => void;
  format?: (value: number) => string;
  testID?: string;
}

function defaultFormat(value: number, step: number): string {
  if (step >= 1) return String(Math.round(value));
  return value.toFixed(step >= 0.1 ? 1 : 2);
}

/** A labelled slider. Tap the value to reset it. */
export const SliderRow = memo(function SliderRow(props: SliderRowProps) {
  const shown = props.format ? props.format(props.value) : defaultFormat(props.value, props.step);
  const changed = Math.abs(props.value - props.resetTo) > props.step / 2;
  return (
    <View style={styles.sliderRow}>
      <View style={styles.sliderHeader}>
        <Text style={styles.sliderLabel}>{props.label}</Text>
        <Pressable
          hitSlop={8}
          disabled={!changed}
          accessibilityRole="button"
          accessibilityLabel={`${props.label}: ${shown}`}
          onPress={() => {
            props.onChange(props.resetTo);
            props.onCommit();
          }}>
          <Text style={[styles.sliderValue, changed && styles.sliderValueChanged]}>{shown}</Text>
        </Pressable>
      </View>
      <Slider
        testID={props.testID}
        accessibilityLabel={props.label}
        style={styles.slider}
        value={props.value}
        minimumValue={props.min}
        maximumValue={props.max}
        step={props.step}
        tapToSeek
        minimumTrackTintColor={colors.accent}
        maximumTrackTintColor={colors.border}
        thumbTintColor={colors.text}
        onValueChange={props.onChange}
        onSlidingComplete={props.onCommit}
      />
    </View>
  );
});

const styles = StyleSheet.create({
  iconButton: { width: 40, height: 40, alignItems: 'center', justifyContent: 'center', borderRadius: radius.m },
  pressed: { opacity: 0.55 },
  disabled: { opacity: 0.4 },
  chip: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingHorizontal: spacing.m,
    height: 34,
    borderRadius: 17,
    backgroundColor: colors.raised,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  chipSelected: { backgroundColor: colors.accent, borderColor: colors.accent },
  chipText: { color: colors.text, fontSize: 14 },
  chipTextSelected: { color: colors.onAccent, fontWeight: '600' },
  swatch: { width: 12, height: 12, borderRadius: 6 },
  textButton: { paddingHorizontal: spacing.l, height: 44, borderRadius: radius.m, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.raised },
  textButtonAccent: { backgroundColor: colors.accent },
  textButtonLabel: { color: colors.text, fontSize: 16, fontWeight: '500' },
  textButtonLabelAccent: { color: colors.onAccent, fontWeight: '600' },
  sectionTitle: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginTop: spacing.m, marginBottom: spacing.xs, minHeight: 28 },
  sectionTitleText: { color: colors.dim, fontSize: 12, fontWeight: '600', letterSpacing: 0.6, textTransform: 'uppercase' },
  sliderRow: { marginVertical: 2 },
  sliderHeader: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'baseline' },
  sliderLabel: { color: colors.text, fontSize: 14 },
  sliderValue: { color: colors.dim, fontSize: 14, fontVariant: ['tabular-nums'], minWidth: 48, textAlign: 'right' },
  sliderValueChanged: { color: colors.accent },
  slider: { height: 34 },
});
