import * as DocumentPicker from 'expo-document-picker';
import { Image } from 'expo-image';
import { router } from 'expo-router';
import { useState } from 'react';
import { ActivityIndicator, Alert, FlatList, Pressable, StyleSheet, Text, useWindowDimensions, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { t } from '@/i18n';
import { deletePhoto, importPhoto, libraryStore, type PhotoDocument } from '@/platform/library';
import { useStore } from '@/platform/store';
import { IconButton, TextButton } from '@/ui/controls';
import { Icon } from '@/ui/icons';
import { colors, spacing } from '@/ui/theme';
import { isEngineAvailable, OscuruEngine } from '@modules/oscuru-engine';

const COLUMNS = 3;
const GAP = 3;

export default function LibraryScreen() {
  const library = useStore(libraryStore);
  const { width } = useWindowDimensions();
  const [importing, setImporting] = useState(false);
  const tile = (width - GAP * (COLUMNS - 1)) / COLUMNS;

  const bringIn = async (pick: () => Promise<{ uri: string; name: string } | null>) => {
    if (importing) return;
    try {
      const picked = await pick();
      if (!picked) return;
      setImporting(true);
      const document = await importPhoto(picked);
      router.push({ pathname: '/editor/[id]', params: { id: document.id } });
    } catch (error) {
      Alert.alert(t('library.importFailed'), error instanceof Error ? error.message : String(error));
    } finally {
      setImporting(false);
    }
  };

  const fromPhotos = () => bringIn(() => OscuruEngine.pickPhoto());
  const fromFiles = () =>
    bringIn(async () => {
      const result = await DocumentPicker.getDocumentAsync({ type: ['public.image', 'public.camera-raw-image', 'com.adobe.raw-image'], copyToCacheDirectory: true });
      const asset = result.canceled ? null : result.assets[0];
      return asset ? { uri: asset.uri, name: asset.name } : null;
    });

  const confirmDelete = (photo: PhotoDocument) =>
    Alert.alert(t('library.deleteTitle'), t('library.deleteBody', { name: photo.name }), [
      { text: t('action.cancel'), style: 'cancel' },
      { text: t('action.delete'), style: 'destructive', onPress: () => deletePhoto(photo.id) },
    ]);

  return (
    <SafeAreaView style={styles.screen} edges={['top']}>
      <View style={styles.header}>
        <Text style={styles.title}>Oscuru</Text>
        <View style={styles.headerActions}>
          {importing ? <ActivityIndicator color={colors.accent} /> : null}
          <IconButton icon="settings" label={t('settings.title')} testID="open-settings" onPress={() => router.push('/settings')} />
        </View>
      </View>
      {!isEngineAvailable ? <Text style={styles.warning}>{t('library.noEngine')}</Text> : null}
      <FlatList
        data={library.photos}
        keyExtractor={(photo) => photo.id}
        numColumns={COLUMNS}
        columnWrapperStyle={{ gap: GAP }}
        contentContainerStyle={library.photos.length === 0 ? styles.emptyList : { gap: GAP, paddingBottom: 120 }}
        ListEmptyComponent={
          library.loaded ? (
            <View style={styles.empty}>
              <Icon name="photo" size={44} color={colors.faint} />
              <Text style={styles.emptyTitle}>{t('library.emptyTitle')}</Text>
              <Text style={styles.emptyBody}>{t('library.emptyBody')}</Text>
            </View>
          ) : undefined
        }
        renderItem={({ item }) => (
          <Pressable
            testID="library-photo"
            accessibilityRole="imagebutton"
            accessibilityLabel={item.name}
            onPress={() => router.push({ pathname: '/editor/[id]', params: { id: item.id } })}
            onLongPress={() => confirmDelete(item)}
            style={({ pressed }) => [{ width: tile, height: tile, backgroundColor: colors.surface }, pressed && { opacity: 0.7 }]}>
            {item.thumbnailUri ? <Image source={{ uri: item.thumbnailUri }} style={StyleSheet.absoluteFill} contentFit="cover" transition={0} /> : null}
            {item.info.isRaw ? (
              <View style={styles.rawBadge}>
                <Text style={styles.rawText}>RAW</Text>
              </View>
            ) : null}
          </Pressable>
        )}
      />
      <SafeAreaView edges={['bottom']} style={styles.importBar}>
        <TextButton testID="import-photos" tone="accent" label={t('library.fromPhotos')} onPress={fromPhotos} disabled={importing} style={styles.importButton} />
        <TextButton testID="import-files" label={t('library.fromFiles')} onPress={fromFiles} disabled={importing} style={styles.importButton} />
      </SafeAreaView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  header: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: spacing.l, height: 52 },
  headerActions: { flexDirection: 'row', alignItems: 'center', gap: spacing.s },
  title: { color: colors.text, fontSize: 28, fontWeight: '700', letterSpacing: 0.3 },
  warning: { color: colors.danger, fontSize: 13, lineHeight: 18, paddingHorizontal: spacing.l, paddingBottom: spacing.s },
  emptyList: { flexGrow: 1, justifyContent: 'center' },
  empty: { alignItems: 'center', paddingHorizontal: spacing.xl * 1.500, gap: spacing.s, paddingBottom: 120 },
  emptyTitle: { color: colors.text, fontSize: 18, fontWeight: '600', marginTop: spacing.s },
  emptyBody: { color: colors.dim, fontSize: 14, lineHeight: 20, textAlign: 'center' },
  rawBadge: { position: 'absolute', left: 6, bottom: 6, backgroundColor: 'rgba(0,0,0,0.6)', borderRadius: 4, paddingHorizontal: 5, paddingVertical: 1 },
  rawText: { color: colors.text, fontSize: 10, fontWeight: '700', letterSpacing: 0.6 },
  importBar: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    flexDirection: 'row',
    gap: spacing.s,
    paddingHorizontal: spacing.l,
    paddingTop: spacing.m,
    backgroundColor: 'rgba(11,11,12,0.94)',
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.border,
  },
  importButton: { flex: 1, marginBottom: spacing.m },
});
