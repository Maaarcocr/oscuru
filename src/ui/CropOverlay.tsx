import { useState } from 'react';
import { PanResponder, StyleSheet, View, type PanResponderInstance } from 'react-native';

import { moveCrop, resizeCrop, type Corner, type Rect } from '@/editor/crop';
import { colors } from './theme';
import { useResponder } from './useResponder';

const HANDLE = 44;

export interface CropOverlayProps {
  /** Where the whole frame is drawn inside the preview, in points. */
  frame: Rect;
  crop: Rect;
  /** Locked width-to-height ratio in frame fractions, or null. */
  ratio: number | null;
  onChange: (crop: Rect) => void;
}

type Target = Corner | 'move';

function createResponders(latest: () => CropOverlayProps & { setDraft: (draft: Rect | null) => void }): Record<Target, PanResponderInstance> {
  const make = (target: Target): PanResponderInstance => {
    let start: Rect | null = null;
    let draft: Rect | null = null;
    return PanResponder.create({
      onStartShouldSetPanResponder: () => true,
      onMoveShouldSetPanResponder: () => true,
      onPanResponderTerminationRequest: () => false,
      onPanResponderGrant: () => {
        start = latest().crop;
        draft = null;
      },
      onPanResponderMove: (_, gesture) => {
        const { frame, ratio, setDraft } = latest();
        if (!start) return;
        const dx = gesture.dx / frame.width;
        const dy = gesture.dy / frame.height;
        draft = target === 'move' ? moveCrop(start, dx, dy) : resizeCrop(start, target, dx, dy, ratio);
        setDraft(draft);
      },
      onPanResponderRelease: () => {
        const { onChange, setDraft } = latest();
        const result = draft;
        start = null;
        draft = null;
        setDraft(null);
        if (result) onChange(result);
      },
      onPanResponderTerminate: () => {
        start = null;
        draft = null;
        latest().setDraft(null);
      },
    });
  };
  return { move: make('move'), tl: make('tl'), tr: make('tr'), bl: make('bl'), br: make('br') };
}

/** The crop rectangle over the full frame: drag inside to move it, drag a corner to resize. */
export function CropOverlay(props: CropOverlayProps) {
  // While a finger is down the rectangle follows it locally; the photo is only changed on release.
  const [draft, setDraft] = useState<Rect | null>(null);
  const responders = useResponder({ ...props, setDraft }, createResponders);

  const { frame } = props;
  const crop = draft ?? props.crop;
  const left = frame.x + crop.x * frame.width;
  const top = frame.y + crop.y * frame.height;
  const width = crop.width * frame.width;
  const height = crop.height * frame.height;

  const corner = (name: Corner) => {
    const isLeft = name === 'tl' || name === 'bl';
    const isTop = name === 'tl' || name === 'tr';
    return (
      <View
        key={name}
        testID={`crop-${name}`}
        {...responders[name].panHandlers}
        style={[styles.handle, { left: (isLeft ? left : left + width) - HANDLE / 2, top: (isTop ? top : top + height) - HANDLE / 2 }]}>
        <View
          style={[
            styles.bracket,
            isLeft ? { left: HANDLE / 2 - 2, borderLeftWidth: 3 } : { right: HANDLE / 2 - 2, borderRightWidth: 3 },
            isTop ? { top: HANDLE / 2 - 2, borderTopWidth: 3 } : { bottom: HANDLE / 2 - 2, borderBottomWidth: 3 },
          ]}
        />
      </View>
    );
  };

  return (
    <View style={StyleSheet.absoluteFill} pointerEvents="box-none" testID="crop-overlay">
      {/* Everything outside the crop is dimmed. */}
      <View pointerEvents="none" style={[styles.shade, { left: frame.x, top: frame.y, width: frame.width, height: top - frame.y }]} />
      <View pointerEvents="none" style={[styles.shade, { left: frame.x, top: top + height, width: frame.width, height: frame.y + frame.height - top - height }]} />
      <View pointerEvents="none" style={[styles.shade, { left: frame.x, top, width: left - frame.x, height }]} />
      <View pointerEvents="none" style={[styles.shade, { left: left + width, top, width: frame.x + frame.width - left - width, height }]} />
      <View {...responders.move.panHandlers} style={[styles.rect, { left, top, width, height }]}>
        <View pointerEvents="none" style={[styles.third, { left: '33.33%', top: 0, bottom: 0, width: StyleSheet.hairlineWidth }]} />
        <View pointerEvents="none" style={[styles.third, { left: '66.66%', top: 0, bottom: 0, width: StyleSheet.hairlineWidth }]} />
        <View pointerEvents="none" style={[styles.third, { top: '33.33%', left: 0, right: 0, height: StyleSheet.hairlineWidth }]} />
        <View pointerEvents="none" style={[styles.third, { top: '66.66%', left: 0, right: 0, height: StyleSheet.hairlineWidth }]} />
      </View>
      {(['tl', 'tr', 'bl', 'br'] as const).map(corner)}
    </View>
  );
}

const styles = StyleSheet.create({
  shade: { position: 'absolute', backgroundColor: 'rgba(0,0,0,0.6)' },
  rect: { position: 'absolute', borderWidth: 1, borderColor: colors.text },
  third: { position: 'absolute', backgroundColor: 'rgba(255,255,255,0.35)' },
  handle: { position: 'absolute', width: HANDLE, height: HANDLE },
  bracket: { position: 'absolute', width: 18, height: 18, borderColor: colors.text },
});
