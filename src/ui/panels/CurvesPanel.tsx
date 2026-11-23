import { useState } from 'react';
import { StyleSheet, Text, useWindowDimensions, View } from 'react-native';

import { CURVE_CHANNELS, isIdentityCurve, setCurve, type CurveChannel } from '@/engine/state';
import { t, type StringKey } from '@/i18n';
import { Chip, TextButton } from '../controls';
import { CurveEditor } from '../CurveEditor';
import { colors, spacing } from '../theme';
import type { PanelProps } from './shared';

const CHANNEL_COLORS: Record<CurveChannel, string> = { rgb: '#F2F2F3', red: '#FF5A5A', green: '#57D46B', blue: '#5B8CFF' };

export function CurvesPanel({ session, snapshot, height }: PanelProps & { height: number }) {
  const [channel, setChannel] = useState<CurveChannel>('rgb');
  const { width } = useWindowDimensions();
  const size = Math.max(160, Math.min(height - spacing.s, width - 150));
  const histogram = snapshot.analysis?.histogram;
  const backdrop = histogram ? (channel === 'rgb' ? histogram.luminance : histogram[channel]) : undefined;
  const points = snapshot.state.curves[channel];
  const label = `${t('tab.curves')} ${t(`channel.${channel}` as StringKey)}`;
  return (
    <View style={styles.row}>
      <CurveEditor
        size={size}
        points={points}
        color={CHANNEL_COLORS[channel]}
        backdrop={backdrop}
        onChange={(next) => session.update((state) => setCurve(state, channel, next))}
        onCommit={() => session.commit(label)}
      />
      <View style={styles.side}>
        {CURVE_CHANNELS.map((name) => (
          <Chip
            key={name}
            testID={`curve-${name}`}
            label={t(`channel.${name}` as StringKey) + (isIdentityCurve(snapshot.state.curves[name]) ? '' : ' •')}
            swatch={CHANNEL_COLORS[name]}
            selected={name === channel}
            onPress={() => setChannel(name)}
          />
        ))}
        <TextButton
          label={t('action.reset')}
          disabled={isIdentityCurve(points)}
          onPress={() =>
            session.change(
              (state) =>
                setCurve(state, channel, [
                  [0, 0],
                  [1, 1],
                ]),
              label,
            )
          }
        />
        <Text style={styles.hint}>{t('curves.hint')}</Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  row: { flex: 1, flexDirection: 'row', paddingHorizontal: spacing.l, gap: spacing.m },
  side: { flex: 1, gap: spacing.s, alignItems: 'flex-start' },
  hint: { color: colors.faint, fontSize: 11, lineHeight: 15 },
});
