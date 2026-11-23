/** Renders editing states with the native engine, and measures the result. */

import type { PhotoInfo } from '@/engine/photo';
import { buildRenderInput } from '@/engine/recipe';
import type { EditingState } from '@/engine/state';
import { analyzePixels } from '@/engine/stats';
import type { RenderedFrame, Renderer, RenderPurpose, RenderRequest } from '@/editor/session';
import { OscuruEngine, type NativeRenderOptions } from '@modules/oscuru-engine';

type Preset = Pick<NativeRenderOptions, 'maxEdge' | 'quality' | 'colorSpace' | 'statsEdge' | 'slot'>;

const PRESETS: Record<RenderPurpose, Preset> = {
  preview: { maxEdge: 1800, quality: 0.85, colorSpace: 'p3', statsEdge: 192, slot: 'preview' },
  // Smaller and rougher while a control is moving, so the photo keeps up with the finger.
  drag: { maxEdge: 1000, quality: 0.7, colorSpace: 'p3', statsEdge: 128, slot: 'preview' },
  // Models read sRGB; a wide-gamut file would look washed out to them.
  agent: { maxEdge: 1024, quality: 0.82, colorSpace: 'srgb', statsEdge: 192, slot: 'agent' },
  original: { maxEdge: 1800, quality: 0.85, colorSpace: 'p3', statsEdge: 0, slot: 'original' },
  thumbnail: { maxEdge: 480, quality: 0.8, colorSpace: 'srgb', statsEdge: 0, slot: 'thumbnail' },
  export: { maxEdge: 0, quality: 0.95, colorSpace: 'p3', statsEdge: 0, slot: 'export' },
};

export function createNativeRenderer(sessionId: string, info: PhotoInfo): Renderer {
  return {
    async render(state: EditingState, request: RenderRequest): Promise<RenderedFrame> {
      const preset = PRESETS[request.purpose];
      const { recipe, toneTable, cube } = buildRenderInput(state, info.defaults);
      const result = await OscuruEngine.render(sessionId, recipe, toneTable, cube, {
        ...preset,
        maxEdge: request.purpose === 'agent' && request.maxEdge ? request.maxEdge : preset.maxEdge,
        format: request.format ?? 'jpeg',
        fullFrame: request.fullFrame ?? false,
      });
      const analysis = result.statsWidth > 0 ? analyzePixels(result.statsPixels, result.statsWidth, result.statsHeight) : null;
      return { uri: result.uri, width: result.width, height: result.height, analysis };
    },
  };
}
