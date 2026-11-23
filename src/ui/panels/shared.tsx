import { useSyncExternalStore, type ReactNode } from 'react';
import { ScrollView, StyleSheet } from 'react-native';

import type { EditorSession, EditorSnapshot } from '@/editor/session';
import { adjustGlobal, GLOBAL_SPECS, type GlobalAdjustments, type ParamSpec } from '@/engine/state';
import { t, type StringKey } from '@/i18n';
import { SliderRow } from '../controls';
import { spacing } from '../theme';

export interface PanelProps {
  session: EditorSession;
  snapshot: EditorSnapshot;
}

export function useSnapshot(session: EditorSession): EditorSnapshot {
  return useSyncExternalStore(session.subscribe, session.getSnapshot, session.getSnapshot);
}

export function PanelScroll(props: { children: ReactNode }) {
  return (
    <ScrollView style={styles.scroll} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled" showsVerticalScrollIndicator={false}>
      {props.children}
    </ScrollView>
  );
}

/** A slider bound to one global adjustment. */
export function GlobalSlider(props: PanelProps & { name: keyof GlobalAdjustments; format?: (value: number) => string }) {
  const { session, snapshot, name } = props;
  const spec: ParamSpec = GLOBAL_SPECS[name];
  const label = t(`param.${name}` as StringKey);
  // White balance goes back to the photo's own, not to a generic value.
  const resetTo = name === 'temperature' || name === 'tint' ? Math.round(session.info.defaults[name]) : spec.default;
  return (
    <SliderRow
      testID={`slider-${name}`}
      label={label}
      value={snapshot.state.global[name]}
      min={spec.min}
      max={spec.max}
      step={spec.step}
      resetTo={resetTo}
      format={props.format}
      onChange={(value) => session.update((state) => (state.global[name] === value ? state : adjustGlobal(state, { [name]: value })))}
      onCommit={() => session.commit(label)}
    />
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1 },
  content: { paddingHorizontal: spacing.l, paddingBottom: spacing.l },
});
