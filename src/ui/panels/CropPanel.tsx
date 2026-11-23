import { ScrollView, StyleSheet, View } from 'react-native';

import { cropAspect, cropForAspect, flipCrop, frameAspect, rotateCrop } from '@/editor/crop';
import { CROP_ANGLE_SPEC, resetSection, setCrop } from '@/engine/state';
import { t } from '@/i18n';
import { Chip, IconButton, SliderRow, TextButton } from '../controls';
import { spacing } from '../theme';
import { PanelScroll, type PanelProps } from './shared';

/** Proportions offered in the crop tool, as width : height. */
const ASPECTS: [string, number][] = [
  ['1:1', 1],
  ['4:5', 4 / 5],
  ['5:4', 5 / 4],
  ['2:3', 2 / 3],
  ['3:2', 3 / 2],
  ['9:16', 9 / 16],
  ['16:9', 16 / 9],
];

export interface CropPanelProps extends PanelProps {
  /** The locked proportions in pixels, or null when the crop is free. */
  aspect: number | null;
  onAspect: (aspect: number | null) => void;
}

export function CropPanel({ session, snapshot, aspect, onAspect }: CropPanelProps) {
  const { crop } = snapshot.state;
  const frame = frameAspect(session.info, crop);
  const choose = (next: number | null) => {
    onAspect(next);
    if (next !== null && Math.abs(cropAspect(session.info, crop) - next) > 0.005) {
      session.change((state) => setCrop(state, cropForAspect(frame, next)), t('tab.crop'));
    }
  };
  const matches = (value: number): boolean => aspect !== null && Math.abs(aspect - value) < 0.005;
  const angleLabel = t('crop.straighten');
  return (
    <View style={styles.fill}>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.chipRow} contentContainerStyle={styles.chips}>
        <Chip testID="aspect-free" label={t('crop.free')} selected={aspect === null} onPress={() => choose(null)} />
        <Chip testID="aspect-original" label={t('crop.original')} selected={matches(frame)} onPress={() => choose(frame)} />
        {ASPECTS.map(([label, value]) => (
          <Chip key={label} testID={`aspect-${label}`} label={label} selected={matches(value) && !matches(frame)} onPress={() => choose(value)} />
        ))}
      </ScrollView>
      <PanelScroll>
        <SliderRow
          testID="slider-angle"
          label={angleLabel}
          value={crop.angle}
          min={CROP_ANGLE_SPEC.min}
          max={CROP_ANGLE_SPEC.max}
          step={CROP_ANGLE_SPEC.step}
          resetTo={0}
          format={(value) => `${value.toFixed(1)}°`}
          onChange={(value) => session.update((state) => (state.crop.angle === value ? state : setCrop(state, { angle: value })))}
          onCommit={() => session.commit(angleLabel)}
        />
        <View style={styles.buttons}>
          <IconButton icon="rotateLeft" label={t('crop.rotateLeft')} testID="rotate-left" onPress={() => session.change((state) => ({ ...state, crop: rotateCrop(state.crop, 'left') }), t('crop.rotateLeft'))} />
          <IconButton icon="rotateRight" label={t('crop.rotateRight')} testID="rotate-right" onPress={() => session.change((state) => ({ ...state, crop: rotateCrop(state.crop, 'right') }), t('crop.rotateRight'))} />
          <IconButton icon="flipHorizontal" label={t('crop.flipHorizontal')} testID="flip-horizontal" onPress={() => session.change((state) => ({ ...state, crop: flipCrop(state.crop, 'horizontal') }), t('crop.flipHorizontal'))} />
          <IconButton icon="flipVertical" label={t('crop.flipVertical')} testID="flip-vertical" onPress={() => session.change((state) => ({ ...state, crop: flipCrop(state.crop, 'vertical') }), t('crop.flipVertical'))} />
          <View style={styles.fill} />
          <TextButton
            label={t('action.reset')}
            onPress={() => {
              onAspect(null);
              session.change((state) => resetSection(state, 'crop', session.info.defaults), t('tab.crop'));
            }}
          />
        </View>
      </PanelScroll>
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  chipRow: { flexGrow: 0, marginBottom: spacing.s },
  chips: { flexDirection: 'row', gap: spacing.s, paddingHorizontal: spacing.l },
  buttons: { flexDirection: 'row', alignItems: 'center', gap: spacing.s, marginTop: spacing.s },
});
