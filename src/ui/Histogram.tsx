import { memo } from 'react';
import { StyleSheet, View } from 'react-native';
import Svg, { Path } from 'react-native-svg';

import type { Histogram as HistogramData } from '@/engine/stats';
import { colors } from './theme';

/** A filled path for one channel, on a 256 × 100 grid. Tall bins are compressed so shadows and highlights stay readable. */
export function histogramPath(bins: number[], height = 100): string {
  let peak = 0;
  for (let i = 1; i < bins.length - 1; i++) peak = Math.max(peak, bins[i]);
  peak = Math.max(peak, 1e-6);
  let path = `M0 ${height}`;
  for (let i = 0; i < bins.length; i++) {
    const level = Math.min(1, Math.sqrt(bins[i] / peak));
    path += `L${i} ${(height - level * height).toFixed(1)}`;
  }
  return `${path}L${bins.length - 1} ${height}Z`;
}

export const Histogram = memo(function Histogram(props: { data: HistogramData | null; width: number; height: number }) {
  const { data } = props;
  return (
    <View style={[styles.box, { width: props.width, height: props.height }]} pointerEvents="none">
      {data ? (
        <Svg width={props.width} height={props.height} viewBox="0 0 255 100" preserveAspectRatio="none">
          <Path d={histogramPath(data.red)} fill="#FF5A5A" opacity={0.5} />
          <Path d={histogramPath(data.green)} fill="#57D46B" opacity={0.5} />
          <Path d={histogramPath(data.blue)} fill="#5B8CFF" opacity={0.5} />
          <Path d={histogramPath(data.luminance)} fill="#FFFFFF" opacity={0.55} />
        </Svg>
      ) : null}
      {data && data.shadowClipping > 0.002 ? <View style={[styles.clip, styles.clipLeft]} /> : null}
      {data && data.highlightClipping > 0.002 ? <View style={[styles.clip, styles.clipRight]} /> : null}
    </View>
  );
});

const styles = StyleSheet.create({
  box: { backgroundColor: 'rgba(0,0,0,0.55)', borderRadius: 6, overflow: 'hidden', borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border },
  clip: { position: 'absolute', top: 4, width: 7, height: 7, borderRadius: 4 },
  clipLeft: { left: 4, backgroundColor: '#5B8CFF' },
  clipRight: { right: 4, backgroundColor: colors.danger },
});
