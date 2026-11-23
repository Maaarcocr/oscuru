import Constants from 'expo-constants';
import { router } from 'expo-router';
import { useMemo, useState } from 'react';
import { ActivityIndicator, Alert, KeyboardAvoidingView, Platform, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { formatDollars, type SpendingLimits } from '@/agent/cost';
import { t, type StringKey } from '@/i18n';
import {
  accountStore,
  activeModel,
  connectWithKey,
  disconnect,
  finishSignIn,
  openSignInPageForCode,
  setLimits,
  setModel,
  signInWithOpenRouter,
  spendingSummary,
} from '@/platform/account';
import { useStore } from '@/platform/store';
import { IconButton, SectionTitle, TextButton } from '@/ui/controls';
import { colors, radius, spacing } from '@/ui/theme';

const SHOWN_MODELS = 40;

function Field(props: { value: string; onChangeText: (text: string) => void; placeholder: string; secure?: boolean; testID?: string; grow?: boolean }) {
  return (
    <TextInput
      testID={props.testID}
      style={[styles.field, props.grow && styles.grow]}
      value={props.value}
      onChangeText={props.onChangeText}
      placeholder={props.placeholder}
      placeholderTextColor={colors.faint}
      secureTextEntry={props.secure}
      autoCapitalize="none"
      autoCorrect={false}
      keyboardAppearance="dark"
    />
  );
}

export default function SettingsScreen() {
  const account = useStore(accountStore);
  const [busy, setBusy] = useState(false);
  const [code, setCode] = useState('');
  const [key, setKey] = useState('');
  const [showCode, setShowCode] = useState(false);
  const [search, setSearch] = useState('');
  // Recomputed whenever spending is recorded.
  const summary = useMemo(() => spendingSummary(), [account.spendingVersion, account.userId]); // eslint-disable-line react-hooks/exhaustive-deps

  const attempt = async (work: () => Promise<void>) => {
    if (busy) return;
    setBusy(true);
    try {
      await work();
    } catch (error) {
      Alert.alert(t('settings.connectFailed'), error instanceof Error ? error.message : String(error));
    } finally {
      setBusy(false);
    }
  };

  const signIn = () =>
    attempt(async () => {
      const result = await signInWithOpenRouter();
      if (result === 'needs_code') setShowCode(true);
    });

  const chosen = activeModel(account);
  const models = useMemo(() => {
    const query = search.trim().toLowerCase();
    const matching = account.models.filter((model) => !query || model.id.toLowerCase().includes(query) || model.name.toLowerCase().includes(query));
    return matching.sort((a, b) => (a.id === chosen ? -1 : b.id === chosen ? 1 : a.id.localeCompare(b.id))).slice(0, SHOWN_MODELS);
  }, [account.models, search, chosen]);

  const limitField = (scope: keyof SpendingLimits, label: StringKey) => (
    <View style={styles.limitRow} key={scope}>
      <Text style={styles.label}>{t(label)}</Text>
      <View style={styles.limitInput}>
        <Text style={styles.dim}>$</Text>
        <TextInput
          testID={`limit-${scope}`}
          style={styles.limitField}
          defaultValue={account.limits[scope] === 0 ? '' : String(account.limits[scope])}
          placeholder={t('settings.noLimit')}
          placeholderTextColor={colors.faint}
          keyboardType="decimal-pad"
          keyboardAppearance="dark"
          onEndEditing={(event) => {
            const value = Number(event.nativeEvent.text.replace(',', '.'));
            setLimits({ ...accountStore.get().limits, [scope]: Number.isFinite(value) && value > 0 ? value : 0 });
          }}
        />
      </View>
    </View>
  );

  return (
    <SafeAreaView style={styles.screen} edges={['top', 'bottom']}>
      <View style={styles.header}>
        <Text style={styles.title}>{t('settings.title')}</Text>
        <IconButton icon="close" label={t('action.close')} testID="close-settings" onPress={() => router.back()} />
      </View>
      <KeyboardAvoidingView style={styles.fill} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
        <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
          <SectionTitle>{t('settings.account')}</SectionTitle>
          {account.apiKey ? (
            <View style={styles.card}>
              <Text style={styles.label} testID="account-connected">
                {t('settings.connected')}
              </Text>
              {account.keyInfo ? (
                <>
                  <Text style={styles.dim}>{account.keyInfo.label}</Text>
                  <Text style={styles.dim}>
                    {t('settings.keyUsage', { used: formatDollars(account.keyInfo.usage) })}
                    {account.keyInfo.limit !== null && account.keyInfo.limitRemaining !== null
                      ? ` · ${t('settings.keyRemaining', { remaining: formatDollars(account.keyInfo.limitRemaining), limit: formatDollars(account.keyInfo.limit) })}`
                      : ` · ${t('settings.keyNoLimit')}`}
                  </Text>
                </>
              ) : null}
              <TextButton
                tone="danger"
                label={t('settings.disconnect')}
                testID="disconnect"
                style={styles.cardButton}
                onPress={() =>
                  Alert.alert(t('settings.disconnectTitle'), t('settings.disconnectBody'), [
                    { text: t('action.cancel'), style: 'cancel' },
                    { text: t('settings.disconnect'), style: 'destructive', onPress: () => void disconnect() },
                  ])
                }
              />
            </View>
          ) : (
            <View style={styles.card}>
              <Text style={styles.dim}>{t('settings.accountBody')}</Text>
              <TextButton tone="accent" label={t('settings.signIn')} testID="sign-in" style={styles.cardButton} disabled={busy} onPress={signIn} />
              <Pressable
                hitSlop={6}
                onPress={() => {
                  setShowCode(true);
                  void attempt(openSignInPageForCode);
                }}>
                <Text style={styles.link}>{t('settings.signInWithCode')}</Text>
              </Pressable>
              {showCode ? (
                <View style={styles.inline}>
                  <Field grow testID="code-field" value={code} onChangeText={setCode} placeholder={t('settings.codePlaceholder')} />
                  <TextButton label={t('settings.useCode')} disabled={busy || !code.trim()} onPress={() => attempt(() => finishSignIn(code))} />
                </View>
              ) : null}
              <Text style={[styles.dim, styles.or]}>{t('settings.orKey')}</Text>
              <View style={styles.inline}>
                <Field grow testID="key-field" value={key} onChangeText={setKey} placeholder="sk-or-v1-…" secure />
                <TextButton
                  label={t('settings.useKey')}
                  testID="use-key"
                  disabled={busy || !key.trim()}
                  onPress={() =>
                    attempt(async () => {
                      await connectWithKey(key);
                      setKey('');
                    })
                  }
                />
              </View>
              {busy ? <ActivityIndicator color={colors.accent} /> : null}
            </View>
          )}

          <SectionTitle>{t('settings.spending')}</SectionTitle>
          <View style={styles.card}>
            <Text style={styles.dim}>{t('settings.spendingBody')}</Text>
            {limitField('perRequest', 'settings.limitRequest')}
            {limitField('perDay', 'settings.limitDay')}
            {limitField('perMonth', 'settings.limitMonth')}
            <Text style={styles.dim} testID="spending-summary">
              {t('settings.spent', { today: formatDollars(summary.today), month: formatDollars(summary.month), count: summary.requestsToday })}
            </Text>
          </View>

          <SectionTitle>{t('settings.model')}</SectionTitle>
          <View style={styles.card}>
            <Text style={styles.dim}>{t('settings.modelBody')}</Text>
            <Field value={search} onChangeText={setSearch} placeholder={t('settings.modelSearch')} />
            {account.models.length === 0 ? <Text style={styles.label}>{chosen}</Text> : null}
            {models.map((model) => {
              const selected = model.id === chosen;
              return (
                <Pressable key={model.id} testID={`model-${model.id}`} style={styles.model} accessibilityRole="radio" accessibilityState={{ selected }} onPress={() => setModel(model.id)}>
                  <View style={[styles.radio, selected && styles.radioSelected]} />
                  <View style={styles.fill}>
                    <Text style={styles.label}>{model.name}</Text>
                    <Text style={styles.dim}>
                      {model.id} · {t('settings.modelPrice', { input: model.promptPrice.toFixed(2), output: model.completionPrice.toFixed(2) })}
                    </Text>
                  </View>
                </Pressable>
              );
            })}
            {account.model ? (
              <Pressable hitSlop={6} onPress={() => setModel(null)}>
                <Text style={styles.link}>{t('settings.modelDefault')}</Text>
              </Pressable>
            ) : null}
          </View>

          <SectionTitle>{t('settings.privacy')}</SectionTitle>
          <View style={styles.card}>
            <Text style={styles.dim}>{t('settings.privacyBody')}</Text>
          </View>
          <Text style={styles.version}>Oscuru {Constants.expoConfig?.version ?? ''}</Text>
        </ScrollView>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  fill: { flex: 1 },
  header: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: spacing.l, height: 52 },
  title: { color: colors.text, fontSize: 22, fontWeight: '700' },
  content: { paddingHorizontal: spacing.l, paddingBottom: spacing.xl * 2 },
  card: { backgroundColor: colors.surface, borderRadius: radius.m, padding: spacing.l, gap: spacing.s, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border },
  cardButton: { alignSelf: 'flex-start', marginTop: spacing.xs },
  label: { color: colors.text, fontSize: 15 },
  dim: { color: colors.dim, fontSize: 13, lineHeight: 18 },
  link: { color: colors.accent, fontSize: 14, paddingVertical: 4 },
  or: { marginTop: spacing.s },
  inline: { flexDirection: 'row', gap: spacing.s, alignItems: 'center' },
  grow: { flex: 1, minWidth: 0 },
  field: { height: 44, backgroundColor: colors.raised, borderRadius: radius.s, paddingHorizontal: spacing.m, color: colors.text, fontSize: 15 },
  limitRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  limitInput: { flexDirection: 'row', alignItems: 'center', gap: 4, backgroundColor: colors.raised, borderRadius: radius.s, paddingHorizontal: spacing.m, height: 40, width: 120 },
  limitField: { flex: 1, minWidth: 0, height: 40, color: colors.text, fontSize: 15, textAlign: 'right' },
  model: { flexDirection: 'row', alignItems: 'center', gap: spacing.m, paddingVertical: 6 },
  radio: { width: 18, height: 18, borderRadius: 9, borderWidth: 2, borderColor: colors.faint },
  radioSelected: { borderColor: colors.accent, backgroundColor: colors.accent },
  version: { color: colors.faint, fontSize: 12, textAlign: 'center', marginTop: spacing.xl },
});
