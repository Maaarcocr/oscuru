/** Browser preview only: the library lives in memory and is gone when the page reloads. */

import type { EditingState } from '@/engine/state';
import { defaultState } from '@/engine/state';
import { OscuruEngine } from '@modules/oscuru-engine';
import type { PhotoDocument } from './library';
import { createNativeRenderer } from './renderer';
import { createStore } from './store';

export type { PhotoDocument } from './library';

export const libraryStore = createStore<{ loaded: boolean; photos: PhotoDocument[] }>({ loaded: false, photos: [] });

function replace(document: PhotoDocument): void {
  libraryStore.set((current) => ({ loaded: true, photos: [document, ...current.photos.filter((photo) => photo.id !== document.id)].sort((a, b) => b.addedAt - a.addedAt) }));
}

export function loadLibrary(): void {
  libraryStore.set((current) => ({ ...current, loaded: true }));
}

export function getPhoto(id: string): PhotoDocument | null {
  return libraryStore.get().photos.find((photo) => photo.id === id) ?? null;
}

export async function importPhoto(source: { uri: string; name: string }): Promise<PhotoDocument> {
  const id = `web-${Date.now().toString(36)}`;
  const info = { ...(await OscuruEngine.open(id, source.uri)), fileName: source.name };
  const state = defaultState(info.defaults);
  const thumbnail = await createNativeRenderer(id, info).render(state, { purpose: 'thumbnail' });
  await OscuruEngine.close(id);
  const document: PhotoDocument = { id, name: source.name, addedAt: Date.now(), originalUri: source.uri, thumbnailUri: thumbnail.uri, info, state, revision: 1 };
  replace(document);
  return document;
}

export function saveEdits(id: string, state: EditingState, revision: number): void {
  const document = getPhoto(id);
  if (document) replace({ ...document, state, revision });
}

export async function refreshThumbnail(id: string, state: EditingState, engineId: string): Promise<void> {
  const document = getPhoto(id);
  if (!document) return;
  const thumbnail = await createNativeRenderer(engineId, document.info).render(state, { purpose: 'thumbnail' });
  replace({ ...document, state, thumbnailUri: thumbnail.uri });
}

export function deletePhoto(id: string): void {
  libraryStore.set((current) => ({ loaded: true, photos: current.photos.filter((photo) => photo.id !== id) }));
}
