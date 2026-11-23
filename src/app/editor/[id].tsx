import { router, useLocalSearchParams } from 'expo-router';
import * as Sharing from 'expo-sharing';
import { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Alert, KeyboardAvoidingView, Platform, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import type { Assistant } from '@/editor/assistant';
import { frameAspect } from '@/editor/crop';
import type { EditorSession } from '@/editor/session';
import { useEditor } from '@/editor/useEditor';
import { setCrop } from '@/engine/state';
import { t, type StringKey } from '@/i18n';
import { IconButton } from '@/ui/controls';
import { Icon, type IconName } from '@/ui/icons';
import { AssistantPanel } from '@/ui/panels/AssistantPanel';
import { ColorPanel, DetailPanel, LightPanel } from '@/ui/panels/BasicPanels';
import { GradingPanel, HSLPanel } from '@/ui/panels/ColorPanels';
import { CropPanel } from '@/ui/panels/CropPanel';
import { CurvesPanel } from '@/ui/panels/CurvesPanel';
import { useSnapshot } from '@/ui/panels/shared';
import { PreviewView } from '@/ui/PreviewView';
import { colors, spacing } from '@/ui/theme';

type Tab = 'assistant' | 'light' | 'color' | 'curves' | 'hsl' | 'grading' | 'detail' | 'crop';

const TABS: { id: Tab; icon: IconName }[] = [
  { id: 'assistant', icon: 'assistant' },
  { id: 'light', icon: 'light' },
  { id: 'color', icon: 'color' },
  { id: 'curves', icon: 'curves' },
  { id: 'hsl', icon: 'hsl' },
  { id: 'grading', icon: 'grading' },
  { id: 'detail', icon: 'detail' },
  { id: 'crop', icon: 'crop' },
];

const PANEL_HEIGHT = 292;

export default function EditorScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const editor = useEditor(id);
  if (editor.status === 'ready') return <Editor session={editor.session} assistant={editor.assistant} name={editor.name} />;
  return (
    <SafeAreaView style={styles.screen}>
      <View style={styles.topBar}>
        <IconButton icon="back" label={t('action.back')} onPress={() => router.back()} />
      </View>
      <View style={styles.centre}>
        {editor.status === 'loading' ? <ActivityIndicator color={colors.accent} /> : <Text style={styles.failure}>{editor.message}</Text>}
      </View>
    </SafeAreaView>
  );
}

function Editor({ session, assistant, name }: { session: EditorSession; assistant: Assistant; name: string }) {
  const snapshot = useSnapshot(session);
  const [tab, setTab] = useState<Tab>('assistant');
  const [showHistogram, setShowHistogram] = useState(true);
  const [aspect, setAspect] = useState<number | null>(null);
  const [compareUri, setCompareUri] = useState<string | null>(null);
  const [exporting, setExporting] = useState(false);
  const comparing = useRef(false);

  useEffect(() => {
    session.setFullFrame(tab === 'crop');
  }, [session, tab]);

  const startCompare = () => {
    comparing.current = true;
    session
      .renderOriginal()
      .then((frame) => {
        if (comparing.current) setCompareUri(frame.uri);
      })
      .catch(() => undefined);
  };
  const endCompare = () => {
    comparing.current = false;
    setCompareUri(null);
  };

  const exportAs = async (format: 'jpeg' | 'heic') => {
    if (exporting) return;
    setExporting(true);
    try {
      await session.settled();
      const frame = await session.renderOnce({ purpose: 'export', format });
      await Sharing.shareAsync(frame.uri, { mimeType: format === 'heic' ? 'image/heic' : 'image/jpeg', UTI: format === 'heic' ? 'public.heic' : 'public.jpeg' });
    } catch (error) {
      Alert.alert(t('export.failed'), error instanceof Error ? error.message : String(error));
    } finally {
      setExporting(false);
    }
  };
  const chooseExport = () =>
    Alert.alert(t('export.title'), t('export.body'), [
      { text: 'JPEG', onPress: () => void exportAs('jpeg') },
      { text: 'HEIC', onPress: () => void exportAs('heic') },
      { text: t('action.cancel'), style: 'cancel' },
    ]);

  const { crop } = snapshot.state;
  const panel = { session, snapshot };
  const cropTool =
    tab === 'crop'
      ? {
          rect: { x: crop.x, y: crop.y, width: crop.width, height: crop.height },
          ratio: aspect === null ? null : aspect / frameAspect(session.info, crop),
          onChange: (rect: { x: number; y: number; width: number; height: number }) => session.change((state) => setCrop(state, rect), t('tab.crop')),
        }
      : null;

  return (
    <SafeAreaView style={styles.screen} edges={['top', 'bottom']}>
      <KeyboardAvoidingView style={styles.fill} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
        <View style={styles.topBar}>
          <IconButton icon="back" label={t('action.back')} testID="editor-back" onPress={() => router.back()} />
          <Text style={styles.name} numberOfLines={1}>
            {name}
          </Text>
          <IconButton icon="undo" label={t('action.undo')} testID="undo" disabled={!snapshot.canUndo} onPress={() => session.undo()} />
          <IconButton icon="redo" label={t('action.redo')} testID="redo" disabled={!snapshot.canRedo} onPress={() => session.redo()} />
          <IconButton icon="histogram" label={t('action.histogram')} testID="toggle-histogram" active={showHistogram} onPress={() => setShowHistogram(!showHistogram)} />
          <IconButton icon="compare" label={t('action.compare')} testID="compare" active={compareUri !== null} onPressIn={startCompare} onPressOut={endCompare} />
          {exporting ? <ActivityIndicator style={styles.exporting} color={colors.accent} /> : <IconButton icon="share" label={t('action.export')} testID="export" onPress={chooseExport} />}
        </View>

        <PreviewView
          frame={snapshot.frame}
          compareUri={compareUri}
          compareLabel={t('editor.original')}
          histogram={snapshot.analysis?.histogram ?? null}
          showHistogram={showHistogram}
          busy={snapshot.rendering}
          error={snapshot.renderError}
          crop={cropTool}
        />

        <View style={styles.panel}>
          {tab === 'assistant' ? <AssistantPanel {...panel} assistant={assistant} /> : null}
          {tab === 'light' ? <LightPanel {...panel} /> : null}
          {tab === 'color' ? <ColorPanel {...panel} /> : null}
          {tab === 'curves' ? <CurvesPanel {...panel} height={PANEL_HEIGHT - spacing.m} /> : null}
          {tab === 'hsl' ? <HSLPanel {...panel} /> : null}
          {tab === 'grading' ? <GradingPanel {...panel} /> : null}
          {tab === 'detail' ? <DetailPanel {...panel} /> : null}
          {tab === 'crop' ? (
            <CropPanel
              {...panel}
              aspect={aspect}
              onAspect={setAspect}
            />
          ) : null}
        </View>

        <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.tabs} contentContainerStyle={styles.tabsContent} keyboardShouldPersistTaps="handled">
          {TABS.map(({ id, icon }) => {
            const selected = id === tab;
            return (
              <Pressable key={id} testID={`tab-${id}`} accessibilityRole="tab" accessibilityState={{ selected }} onPress={() => setTab(id)} style={styles.tab}>
                <Icon name={icon} size={22} color={selected ? colors.accent : colors.dim} />
                <Text style={[styles.tabLabel, selected && styles.tabLabelSelected]}>{t(`tab.${id}` as StringKey)}</Text>
              </Pressable>
            );
          })}
        </ScrollView>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  fill: { flex: 1 },
  topBar: { flexDirection: 'row', alignItems: 'center', height: 48, paddingHorizontal: spacing.s },
  name: { flex: 1, color: colors.dim, fontSize: 14, marginHorizontal: spacing.xs },
  exporting: { width: 40 },
  centre: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: spacing.xl },
  failure: { color: colors.danger, fontSize: 15, textAlign: 'center', lineHeight: 21 },
  panel: { height: PANEL_HEIGHT, paddingTop: spacing.m, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: colors.border, backgroundColor: colors.background },
  tabs: { flexGrow: 0, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: colors.border },
  tabsContent: { paddingHorizontal: spacing.s },
  tab: { alignItems: 'center', justifyContent: 'center', minWidth: 68, height: 54, paddingHorizontal: spacing.s, gap: 3 },
  tabLabel: { color: colors.dim, fontSize: 11 },
  tabLabelSelected: { color: colors.accent, fontWeight: '600' },
});
