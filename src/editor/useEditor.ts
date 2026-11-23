import { useEffect, useState } from 'react';

import { getPhoto, refreshThumbnail, saveEdits } from '@/platform/library';
import { createNativeRenderer } from '@/platform/renderer';
import { readBase64 } from '@/platform/storage';
import { OscuruEngine } from '@modules/oscuru-engine';
import { Assistant } from './assistant';
import { EditorSession } from './session';

export type EditorHandle =
  | { status: 'loading' }
  | { status: 'error'; message: string }
  | { status: 'ready'; session: EditorSession; assistant: Assistant; name: string };

/** Opens a photo from the library for editing, and tidies up when the screen goes away. */
export function useEditor(photoId: string): EditorHandle {
  const [handle, setHandle] = useState<EditorHandle>({ status: 'loading' });

  useEffect(() => {
    let cancelled = false;
    let session: EditorSession | null = null;
    let assistant: Assistant | null = null;
    // A fresh name per opening, so closing an earlier opening of the same photo cannot close this one.
    const engineId = `${photoId}-${Date.now().toString(36)}`;

    void (async () => {
      const document = getPhoto(photoId);
      if (!document) {
        setHandle({ status: 'error', message: 'This photo is no longer in the library.' });
        return;
      }
      try {
        const opened = await OscuruEngine.open(engineId, document.originalUri);
        if (cancelled) {
          await OscuruEngine.close(engineId);
          return;
        }
        const info = { ...opened, fileName: document.info.fileName };
        session = new EditorSession({
          id: photoId,
          info,
          renderer: createNativeRenderer(engineId, info),
          state: document.state,
          revision: document.revision,
          onCommit: (state, revision) => saveEdits(photoId, state, revision),
        });
        assistant = new Assistant(session, readBase64);
        setHandle({ status: 'ready', session, assistant, name: document.name });
      } catch (error) {
        if (!cancelled) setHandle({ status: 'error', message: error instanceof Error ? error.message : String(error) });
      }
    })();

    return () => {
      cancelled = true;
      const closing = session;
      assistant?.close();
      void (async () => {
        try {
          if (closing) await refreshThumbnail(photoId, closing.getSnapshot().state, engineId);
        } catch {
          // The thumbnail is a convenience; the edits themselves are already saved.
        } finally {
          closing?.close();
          await OscuruEngine.close(engineId).catch(() => undefined);
        }
      })();
    };
  }, [photoId]);

  return handle;
}
