import { useState } from 'react';
import { ScrollView, StyleSheet, View } from 'react-native';

import {
  adjustHSL,
  COLOR_RANGES,
  GRADING_MIX_SPECS,
  GRADING_RANGES,
  GRADING_SPECS,
  HSL_SPECS,
  resetSection,
  setGrading,
  setGradingMix,
  type ColorGrading,
  type ColorRange,
  type GradingRange,
  type HSLAdjustments,
} from '@/engine/state';
import { t, type StringKey } from '@/i18n';
import { Chip, SectionTitle, SliderRow, TextButton } from '../controls';
import { spacing } from '../theme';
import { PanelScroll, type PanelProps } from './shared';

export const RANGE_SWATCHES: Record<ColorRange, string> = {
  red: '#E5484D',
  orange: '#F08C3A',
  yellow: '#E9C83E',
  green: '#4FB36B',
  aqua: '#3CC0C0',
  blue: '#3F7FE8',
  purple: '#8B5CE0',
  magenta: '#D94FB8',
};

const HSL_KEYS: (keyof HSLAdjustments)[] = ['hue', 'saturation', 'luminance'];

export function HSLPanel({ session, snapshot }: PanelProps) {
  const [color, setColor] = useState<ColorRange>('orange');
  const values = snapshot.state.hsl[color];
  return (
    <View style={styles.fill}>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.chipRow} contentContainerStyle={styles.chips}>
        {COLOR_RANGES.map((range) => {
          const touched = HSL_KEYS.some((key) => snapshot.state.hsl[range][key] !== 0);
          return (
            <Chip
              key={range}
              testID={`hsl-${range}`}
              label={t(`color.${range}` as StringKey) + (touched ? ' •' : '')}
              swatch={RANGE_SWATCHES[range]}
              selected={range === color}
              onPress={() => setColor(range)}
            />
          );
        })}
      </ScrollView>
      <PanelScroll>
        {HSL_KEYS.map((key) => {
          const label = t(`hsl.${key}` as StringKey);
          return (
            <SliderRow
              key={key}
              testID={`slider-hsl-${key}`}
              label={label}
              value={values[key]}
              min={HSL_SPECS[key].min}
              max={HSL_SPECS[key].max}
              step={1}
              resetTo={0}
              onChange={(value) => session.update((state) => (state.hsl[color][key] === value ? state : adjustHSL(state, color, { [key]: value })))}
              onCommit={() => session.commit(`${t(`color.${color}` as StringKey)} ${label}`)}
            />
          );
        })}
        <TextButton label={t('action.resetSection')} style={styles.reset} onPress={() => session.change((state) => resetSection(state, 'hsl', session.info.defaults), t('tab.hsl'))} />
      </PanelScroll>
    </View>
  );
}

const hueColor = (hue: number): string => `hsl(${Math.round(hue)}, 85%, 55%)`;

const GRADE_KEYS: (keyof ColorGrading)[] = ['hue', 'saturation', 'luminance'];

export function GradingPanel({ session, snapshot }: PanelProps) {
  const [range, setRange] = useState<GradingRange>('shadows');
  const { grading } = snapshot.state;
  const values = grading[range];
  const percent = (value: number): string => `${Math.round(value * 100)}`;
  return (
    <View style={styles.fill}>
      <View style={[styles.chips, styles.chipRow]}>
        {GRADING_RANGES.map((name) => (
          <Chip
            key={name}
            testID={`grading-${name}`}
            label={t(`grading.${name}` as StringKey)}
            swatch={grading[name].saturation > 0 ? hueColor(grading[name].hue) : undefined}
            selected={name === range}
            onPress={() => setRange(name)}
          />
        ))}
      </View>
      <PanelScroll>
        {GRADE_KEYS.map((key) => {
          const spec = GRADING_SPECS[key];
          const label = t(`grading.${key}` as StringKey);
          return (
            <SliderRow
              key={key}
              testID={`slider-grading-${key}`}
              label={label}
              value={values[key]}
              min={spec.min}
              max={spec.max}
              step={spec.step}
              resetTo={0}
              format={key === 'hue' ? (value) => `${Math.round(value)}°` : percent}
              onChange={(value) => session.update((state) => (state.grading[range][key] === value ? state : setGrading(state, range, { [key]: value })))}
              onCommit={() => session.commit(`${t(`grading.${range}` as StringKey)} ${label}`)}
            />
          );
        })}
        <SectionTitle>{t('section.gradingMix')}</SectionTitle>
        {(['blending', 'balance'] as const).map((key) => {
          const spec = GRADING_MIX_SPECS[key];
          const label = t(`grading.${key}` as StringKey);
          return (
            <SliderRow
              key={key}
              testID={`slider-grading-${key}`}
              label={label}
              value={grading[key]}
              min={spec.min}
              max={spec.max}
              step={spec.step}
              resetTo={spec.default}
              format={percent}
              onChange={(value) => session.update((state) => (state.grading[key] === value ? state : setGradingMix(state, { [key]: value })))}
              onCommit={() => session.commit(label)}
            />
          );
        })}
        <TextButton label={t('action.resetSection')} style={styles.reset} onPress={() => session.change((state) => resetSection(state, 'grading', session.info.defaults), t('tab.grading'))} />
      </PanelScroll>
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  chipRow: { flexGrow: 0, marginBottom: spacing.s },
  chips: { flexDirection: 'row', gap: spacing.s, paddingHorizontal: spacing.l },
  reset: { marginTop: spacing.m, alignSelf: 'flex-start' },
});
