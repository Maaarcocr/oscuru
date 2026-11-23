import { router } from 'expo-router';
import { useEffect, useRef, useState, type ComponentRef } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';

import { formatDollars } from '@/agent/cost';
import type { Assistant, TranscriptItem } from '@/editor/assistant';
import type { StateChange } from '@/engine/state';
import { t, type StringKey } from '@/i18n';
import { accountStore } from '@/platform/account';
import { useStore } from '@/platform/store';
import { Chip, IconButton, TextButton } from '../controls';
import { Icon } from '../icons';
import { colors, font, radius, spacing } from '../theme';
import type { PanelProps } from './shared';

const SUGGESTIONS: StringKey[] = ['suggest.cinematic', 'suggest.sky', 'suggest.natural', 'suggest.mono'];

function describeChange(change: StateChange): string {
  const show = (value: unknown): string => (typeof value === 'number' ? String(Math.round(value * 100) / 100) : JSON.stringify(value));
  if (change.path.startsWith('curves.')) return change.path;
  return `${change.path}  ${show(change.from)} → ${show(change.to)}`;
}

const SCRIPT_LABELS: Record<Extract<TranscriptItem, { kind: 'script' }>['state'], StringKey> = {
  running: 'script.running',
  applied: 'script.applied',
  unchanged: 'script.unchanged',
  failed: 'script.failed',
  stale: 'script.stale',
};

function ScriptCard({ item }: { item: Extract<TranscriptItem, { kind: 'script' }> }) {
  const [open, setOpen] = useState(false);
  const tone = item.state === 'failed' ? colors.danger : item.state === 'applied' ? colors.good : colors.dim;
  return (
    <View style={styles.script} testID="script-card">
      <Pressable style={styles.scriptHeader} onPress={() => setOpen(!open)} accessibilityRole="button" accessibilityState={{ expanded: open }}>
        {item.state === 'running' ? <ActivityIndicator size="small" color={colors.accent} /> : <View style={[styles.dot, { backgroundColor: tone }]} />}
        <Text style={styles.scriptTitle}>
          {t(SCRIPT_LABELS[item.state])}
          {item.state === 'applied' ? ` · ${t('script.changes', { count: item.changes.length })}` : ''}
        </Text>
        <Icon name={open ? 'chevronUp' : 'chevronDown'} size={16} color={colors.dim} />
      </Pressable>
      {open ? (
        <View style={styles.scriptBody}>
          {item.error ? <Text style={styles.scriptError}>{item.error}</Text> : null}
          {item.changes.map((change) => (
            <Text key={change.path} style={styles.change}>
              {describeChange(change)}
            </Text>
          ))}
          {item.logs.map((line, index) => (
            <Text key={index} style={styles.change}>
              › {line}
            </Text>
          ))}
          <Text style={styles.code} selectable>
            {item.code}
          </Text>
        </View>
      ) : null}
    </View>
  );
}

export function AssistantPanel({ session, snapshot, assistant }: PanelProps & { assistant: Assistant }) {
  const account = useStore(accountStore);
  const state = useStore(assistant.store);
  const [draft, setDraft] = useState('');
  const scroll = useRef<ComponentRef<typeof ScrollView>>(null);
  const running = state.activeRun !== null;

  const itemCount = state.items.length;
  useEffect(() => {
    // Follow the conversation as it grows; an empty one starts at the top.
    if (itemCount === 0) return;
    const timer = setTimeout(() => scroll.current?.scrollToEnd({ animated: true }), 50);
    return () => clearTimeout(timer);
  }, [itemCount, state.status]);

  if (account.loaded && !account.apiKey) {
    return (
      <View style={styles.connect}>
        <Text style={styles.connectTitle}>{t('assistant.connectTitle')}</Text>
        <Text style={styles.connectBody}>{t('assistant.connectBody')}</Text>
        <TextButton testID="assistant-connect" tone="accent" label={t('assistant.connectAction')} onPress={() => router.push('/settings')} />
      </View>
    );
  }

  const send = (text: string) => {
    if (!text.trim() || running) return;
    setDraft('');
    void assistant.send(text);
  };

  // The last item of each run carries that run's footer: what it cost and a way to take it back.
  const lastOfRun = new Map<string, string>();
  for (const item of state.items) lastOfRun.set(item.runId, item.id);

  return (
    <View style={styles.fill}>
      <ScrollView ref={scroll} style={styles.fill} contentContainerStyle={styles.transcript} keyboardShouldPersistTaps="handled">
        {state.items.length === 0 ? (
          <View>
            <Text style={styles.hint}>{t('assistant.hint')}</Text>
            <View style={styles.suggestions}>
              {SUGGESTIONS.map((key) => (
                <Chip key={key} label={t(key)} onPress={() => send(t(key))} />
              ))}
            </View>
            <Text style={styles.privacy}>{t('assistant.privacy')}</Text>
          </View>
        ) : null}
        {state.items.map((item) => {
          const footer = lastOfRun.get(item.runId) === item.id && state.activeRun !== item.runId;
          const cost = state.costs[item.runId];
          const canRevert = footer && session.hasRun(item.runId) && snapshot.revision > 0;
          return (
            <View key={item.id}>
              {item.kind === 'user' ? (
                <View style={styles.userBubble}>
                  <Text style={styles.userText}>{item.text}</Text>
                </View>
              ) : item.kind === 'assistant' ? (
                <Text style={styles.assistantText} selectable testID="assistant-text">
                  {item.text}
                </Text>
              ) : item.kind === 'script' ? (
                <ScriptCard item={item} />
              ) : (
                <View style={styles.notice}>
                  <Text style={[styles.noticeText, item.tone === 'error' && { color: colors.danger }]}>{t(item.message, item.values)}</Text>
                  {item.detail ? <Text style={styles.noticeDetail}>{item.detail}</Text> : null}
                </View>
              )}
              {footer && (cost !== undefined || canRevert) ? (
                <View style={styles.footer}>
                  {cost !== undefined ? <Text style={styles.cost}>{t('assistant.cost', { amount: formatDollars(cost) })}</Text> : <View />}
                  {canRevert ? (
                    <Pressable hitSlop={8} onPress={() => assistant.revert(item.runId)} testID="revert-run" accessibilityRole="button">
                      <Text style={styles.revert}>{t('assistant.revert')}</Text>
                    </Pressable>
                  ) : null}
                </View>
              ) : null}
            </View>
          );
        })}
        {running ? (
          <View style={styles.working}>
            <ActivityIndicator size="small" color={colors.accent} />
            <Text style={styles.workingText}>{t(state.status === 'running' ? 'assistant.running' : 'assistant.thinking')}</Text>
          </View>
        ) : null}
      </ScrollView>
      <View style={styles.inputRow}>
        <TextInput
          testID="assistant-input"
          style={styles.input}
          value={draft}
          onChangeText={setDraft}
          placeholder={t('assistant.placeholder')}
          placeholderTextColor={colors.faint}
          multiline
          editable={!running}
          keyboardAppearance="dark"
          returnKeyType="send"
          submitBehavior="submit"
          onSubmitEditing={() => send(draft)}
        />
        {running ? (
          <IconButton icon="stop" label={t('assistant.stop')} testID="assistant-stop" onPress={() => assistant.cancel()} active />
        ) : (
          <IconButton icon="send" label={t('assistant.send')} testID="assistant-send" disabled={!draft.trim()} onPress={() => send(draft)} active={!!draft.trim()} />
        )}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  transcript: { paddingHorizontal: spacing.l, paddingBottom: spacing.s, gap: spacing.s },
  hint: { color: colors.dim, fontSize: 14, lineHeight: 20 },
  suggestions: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.s, marginTop: spacing.m },
  privacy: { color: colors.faint, fontSize: 12, lineHeight: 16, marginTop: spacing.m },
  userBubble: { alignSelf: 'flex-end', maxWidth: '88%', backgroundColor: colors.raised, borderRadius: radius.l, paddingHorizontal: spacing.m, paddingVertical: spacing.s },
  userText: { color: colors.text, fontSize: 15, lineHeight: 20 },
  assistantText: { color: colors.text, fontSize: 15, lineHeight: 21 },
  script: { backgroundColor: colors.surface, borderRadius: radius.m, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border },
  scriptHeader: { flexDirection: 'row', alignItems: 'center', gap: spacing.s, paddingHorizontal: spacing.m, minHeight: 38 },
  scriptTitle: { flex: 1, color: colors.dim, fontSize: 13 },
  dot: { width: 8, height: 8, borderRadius: 4 },
  scriptBody: { paddingHorizontal: spacing.m, paddingBottom: spacing.m, gap: 3 },
  scriptError: { color: colors.danger, fontSize: 12, lineHeight: 16 },
  change: { color: colors.dim, fontSize: 12, fontFamily: font.mono },
  code: { color: colors.text, fontSize: 11, lineHeight: 15, fontFamily: font.mono, marginTop: spacing.s },
  notice: { paddingVertical: 2 },
  noticeText: { color: colors.dim, fontSize: 13, lineHeight: 18 },
  noticeDetail: { color: colors.faint, fontSize: 12, lineHeight: 16, marginTop: 2 },
  footer: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginTop: 4, marginBottom: spacing.s },
  cost: { color: colors.faint, fontSize: 12 },
  revert: { color: colors.accent, fontSize: 13, fontWeight: '500' },
  working: { flexDirection: 'row', alignItems: 'center', gap: spacing.s },
  workingText: { color: colors.dim, fontSize: 13 },
  inputRow: { flexDirection: 'row', alignItems: 'flex-end', gap: spacing.s, paddingHorizontal: spacing.l, paddingTop: spacing.s, paddingBottom: spacing.s },
  input: {
    flex: 1,
    minHeight: 40,
    maxHeight: 96,
    color: colors.text,
    fontSize: 16,
    backgroundColor: colors.raised,
    borderRadius: radius.l,
    paddingHorizontal: spacing.m,
    paddingTop: 10,
    paddingBottom: 10,
  },
  connect: { flex: 1, paddingHorizontal: spacing.l, gap: spacing.m, alignItems: 'flex-start' },
  connectTitle: { color: colors.text, fontSize: 17, fontWeight: '600' },
  connectBody: { color: colors.dim, fontSize: 14, lineHeight: 20 },
});
