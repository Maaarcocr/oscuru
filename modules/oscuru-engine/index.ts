import { requireOptionalNativeModule } from 'expo';

import type { RenderRecipe } from '@/engine/recipe';
import type { PhotoInfo } from '@/engine/photo';

export interface NativeRenderOptions {
  /** Long edge in pixels; 0 renders at full resolution. */
  maxEdge: number;
  format: 'jpeg' | 'heic';
  quality: number;
  colorSpace: 'p3' | 'srgb';
  /** Long edge of the sRGB bitmap returned for statistics; 0 for none. */
  statsEdge: number;
  /** Ignore the crop rectangle and vignette. */
  fullFrame: boolean;
  /** Each slot keeps one file per photo: a new render replaces the previous one. */
  slot: string;
}

export interface NativeRenderResult {
  uri: string;
  width: number;
  height: number;
  statsWidth: number;
  statsHeight: number;
  statsPixels: Uint8Array;
}

export interface PickedPhoto {
  uri: string;
  name: string;
  typeIdentifier: string;
}

interface OscuruEngineModule {
  pickPhoto(): Promise<PickedPhoto | null>;
  open(sessionId: string, uri: string): Promise<PhotoInfo>;
  render(sessionId: string, recipe: RenderRecipe, toneTable: Uint8Array, cube: Uint8Array, options: NativeRenderOptions): Promise<NativeRenderResult>;
  close(sessionId: string): Promise<void>;
}

const native = requireOptionalNativeModule<OscuruEngineModule>('OscuruEngine');

/** False in Expo Go and anywhere else the app was built without the native engine. */
export const isEngineAvailable = native != null;

function engine(): OscuruEngineModule {
  if (!native) {
    throw new Error('The rendering engine is not part of this build. Oscuru needs its own build (not Expo Go).');
  }
  return native;
}

export const OscuruEngine: OscuruEngineModule = {
  pickPhoto: () => engine().pickPhoto(),
  open: (sessionId, uri) => engine().open(sessionId, uri),
  render: (sessionId, recipe, toneTable, cube, options) => engine().render(sessionId, recipe, toneTable, cube, options),
  close: (sessionId) => engine().close(sessionId),
};
