import { Image } from 'expo-image';
import { useState } from 'react';
import { ActivityIndicator, ScrollView, StyleSheet, Text, View, type LayoutChangeEvent } from 'react-native';

import type { Rect } from '@/editor/crop';
import type { RenderedFrame } from '@/editor/session';
import type { Histogram as HistogramData } from '@/engine/stats';
import { CropOverlay } from './CropOverlay';
import { Histogram } from './Histogram';
import { colors, spacing } from './theme';

export interface PreviewViewProps {
  frame: RenderedFrame | null;
  /** Shown instead of the photo while the compare button is held. */
  compareUri: string | null;
  compareLabel: string;
  histogram: HistogramData | null;
  showHistogram: boolean;
  busy: boolean;
  error: string | null;
  /** Present while the crop tool is open: the photo then shows its whole frame. */
  crop: { rect: Rect; ratio: number | null; onChange: (rect: Rect) => void } | null;
}

const MARGIN = 12;

/** Where a picture of the given proportions sits when fitted inside a box, with a margin. */
export function fitRect(box: { width: number; height: number }, aspect: number, margin: number): Rect {
  const width = Math.max(1, box.width - margin * 2);
  const height = Math.max(1, box.height - margin * 2);
  const fitted = width / height > aspect ? { width: height * aspect, height } : { width, height: width / aspect };
  return { x: (box.width - fitted.width) / 2, y: (box.height - fitted.height) / 2, ...fitted };
}

export function PreviewView(props: PreviewViewProps) {
  const [box, setBox] = useState({ width: 0, height: 0 });
  const onLayout = (event: LayoutChangeEvent) => {
    const { width, height } = event.nativeEvent.layout;
    if (width !== box.width || height !== box.height) setBox({ width, height });
  };
  const { frame } = props;
  const ready = frame !== null && box.width > 0 && box.height > 0;
  // The crop handles need room at the edges; otherwise the photo goes edge to edge.
  const rect = ready ? fitRect(box, frame.width / frame.height, props.crop ? MARGIN * 2 : 0) : null;
  const uri = props.compareUri ?? frame?.uri;

  return (
    <View style={styles.box} onLayout={onLayout} testID="preview">
      {rect && uri ? (
        props.crop ? (
          <>
            <Image source={{ uri }} style={[styles.absolute, { left: rect.x, top: rect.y, width: rect.width, height: rect.height }]} contentFit="fill" transition={0} cachePolicy="none" />
            <CropOverlay frame={rect} crop={props.crop.rect} ratio={props.crop.ratio} onChange={props.crop.onChange} />
          </>
        ) : (
          <ScrollView
            style={StyleSheet.absoluteFill}
            contentContainerStyle={{ width: box.width, height: box.height, alignItems: 'center', justifyContent: 'center' }}
            maximumZoomScale={8}
            minimumZoomScale={1}
            bouncesZoom
            centerContent
            showsHorizontalScrollIndicator={false}
            showsVerticalScrollIndicator={false}>
            <Image
              source={{ uri }}
              style={{ width: rect.width, height: rect.height }}
              contentFit="fill"
              transition={0}
              cachePolicy="none"
              accessibilityLabel="Photo"
              testID="preview-image"
            />
          </ScrollView>
        )
      ) : null}
      {props.compareUri ? (
        <View style={styles.badge} pointerEvents="none">
          <Text style={styles.badgeText}>{props.compareLabel}</Text>
        </View>
      ) : null}
      {props.showHistogram && !props.crop ? (
        <View style={styles.histogram} pointerEvents="none">
          <Histogram data={props.histogram} width={132} height={64} />
        </View>
      ) : null}
      {props.busy && !frame ? <ActivityIndicator style={styles.spinner} color={colors.accent} /> : null}
      {props.error ? (
        <View style={styles.error}>
          <Text style={styles.errorText}>{props.error}</Text>
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  box: { flex: 1, backgroundColor: colors.background, overflow: 'hidden' },
  absolute: { position: 'absolute' },
  badge: { position: 'absolute', top: spacing.m, left: spacing.m, backgroundColor: 'rgba(0,0,0,0.6)', borderRadius: 6, paddingHorizontal: spacing.s, paddingVertical: 3 },
  badgeText: { color: colors.text, fontSize: 12, fontWeight: '600', letterSpacing: 0.5 },
  histogram: { position: 'absolute', top: spacing.m, right: spacing.m },
  spinner: { position: 'absolute', alignSelf: 'center', top: '48%' },
  error: { position: 'absolute', left: spacing.l, right: spacing.l, bottom: spacing.l, backgroundColor: 'rgba(40,10,8,0.9)', borderRadius: 8, padding: spacing.m },
  errorText: { color: colors.danger, fontSize: 13, lineHeight: 18 },
});
