/**
 * The photos kept in the app. Each has its own folder in the documents directory:
 *
 *   photos/<id>/original.<ext>   a copy of the imported file, never written again
 *   photos/<id>/doc.json         name, what the engine reported, the editing state and its revision
 *   photos/<id>/thumb.jpg        the library thumbnail
 */

import * as Crypto from 'expo-crypto';
import { Directory, File, Paths } from 'expo-file-system';

import type { PhotoInfo } from '@/engine/photo';
import { defaultState, parseState, type EditingState } from '@/engine/state';
import { OscuruEngine } from '@modules/oscuru-engine';
import { createNativeRenderer } from './renderer';
import { createStore } from './store';

export interface PhotoDocument {
  id: string;
  name: string;
  addedAt: number;
  originalUri: string;
  thumbnailUri: string | null;
  info: PhotoInfo;
  state: EditingState;
  revision: number;
}

interface SavedDocument {
  version: 1;
  id: string;
  name: string;
  addedAt: number;
  originalFile: string;
  info: PhotoInfo;
  state: unknown;
  revision: number;
  /** Changes when the thumbnail is rewritten, so the grid shows the new picture. */
  thumbnailStamp?: number;
}

export const libraryStore = createStore<{ loaded: boolean; photos: PhotoDocument[] }>({ loaded: false, photos: [] });

const photosDirectory = (): Directory => new Directory(Paths.document, 'photos');
const photoDirectory = (id: string): Directory => new Directory(photosDirectory(), id);
const documentFile = (id: string): File => new File(photoDirectory(id), 'doc.json');
const thumbnailFile = (id: string): File => new File(photoDirectory(id), 'thumb.jpg');

function toDocument(saved: SavedDocument): PhotoDocument {
  let state: EditingState;
  try {
    state = parseState(saved.state);
  } catch {
    // A document written by a different version: keep the photo, start its edits over.
    state = defaultState(saved.info.defaults);
  }
  const thumbnail = thumbnailFile(saved.id);
  return {
    id: saved.id,
    name: saved.name,
    addedAt: saved.addedAt,
    originalUri: new File(photoDirectory(saved.id), saved.originalFile).uri,
    thumbnailUri: thumbnail.exists ? `${thumbnail.uri}?v=${saved.thumbnailStamp ?? 0}` : null,
    info: saved.info,
    state,
    revision: saved.revision,
  };
}

function readSaved(id: string): SavedDocument | null {
  try {
    const file = documentFile(id);
    if (!file.exists) return null;
    const saved = JSON.parse(file.textSync()) as SavedDocument;
    return saved && saved.version === 1 && saved.id === id ? saved : null;
  } catch {
    return null;
  }
}

function writeSaved(saved: SavedDocument): void {
  documentFile(saved.id).write(JSON.stringify(saved));
}

function replaceInStore(document: PhotoDocument): void {
  libraryStore.set((current) => {
    const others = current.photos.filter((photo) => photo.id !== document.id);
    return { loaded: true, photos: [document, ...others].sort((a, b) => b.addedAt - a.addedAt) };
  });
}

export function loadLibrary(): void {
  const directory = photosDirectory();
  if (!directory.exists) directory.create({ intermediates: true });
  const photos: PhotoDocument[] = [];
  for (const entry of directory.list()) {
    if (!(entry instanceof Directory)) continue;
    const saved = readSaved(entry.name);
    if (saved) photos.push(toDocument(saved));
  }
  photos.sort((a, b) => b.addedAt - a.addedAt);
  libraryStore.set({ loaded: true, photos });
}

export function getPhoto(id: string): PhotoDocument | null {
  return libraryStore.get().photos.find((photo) => photo.id === id) ?? null;
}

const extensionOf = (name: string): string => {
  const match = /\.([A-Za-z0-9]{1,8})$/.exec(name);
  return match ? match[1].toLowerCase() : 'img';
};

/** Copies a picked file into the library and opens it once to learn what it is. */
export async function importPhoto(source: { uri: string; name: string }): Promise<PhotoDocument> {
  const id = Crypto.randomUUID();
  const directory = photoDirectory(id);
  directory.create({ intermediates: true });
  const originalFile = `original.${extensionOf(source.name || source.uri)}`;
  const original = new File(directory, originalFile);
  try {
    await new File(source.uri).copy(original);
    const info = await OscuruEngine.open(id, original.uri);
    const saved: SavedDocument = {
      version: 1,
      id,
      name: source.name || info.fileName,
      addedAt: Date.now(),
      originalFile,
      info: { ...info, fileName: source.name || info.fileName },
      state: defaultState(info.defaults),
      revision: 1,
    };
    writeSaved(saved);
    await writeThumbnail(saved, defaultState(info.defaults));
    await OscuruEngine.close(id);
    const document = toDocument(readSaved(id) ?? saved);
    replaceInStore(document);
    return document;
  } catch (error) {
    await OscuruEngine.close(id).catch(() => undefined);
    if (directory.exists) directory.delete();
    throw error;
  }
}

async function writeThumbnail(saved: SavedDocument, state: EditingState, engineId: string = saved.id): Promise<void> {
  const frame = await createNativeRenderer(engineId, saved.info).render(state, { purpose: 'thumbnail' });
  const target = thumbnailFile(saved.id);
  if (target.exists) target.delete();
  await new File(frame.uri).copy(target);
  saved.thumbnailStamp = Date.now();
  writeSaved(saved);
}

/** Saves the editing state after a committed change. */
export function saveEdits(id: string, state: EditingState, revision: number): void {
  const saved = readSaved(id);
  if (!saved) return;
  saved.state = state;
  saved.revision = revision;
  writeSaved(saved);
  replaceInStore(toDocument(saved));
}

/** Redraws the library thumbnail from the current edits. The photo must be open in the engine as `engineId`. */
export async function refreshThumbnail(id: string, state: EditingState, engineId: string): Promise<void> {
  const saved = readSaved(id);
  if (!saved) return;
  await writeThumbnail(saved, state, engineId);
  replaceInStore(toDocument(saved));
}

export function deletePhoto(id: string): void {
  const directory = photoDirectory(id);
  if (directory.exists) directory.delete();
  libraryStore.set((current) => ({ loaded: true, photos: current.photos.filter((photo) => photo.id !== id) }));
}
