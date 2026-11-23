/**
 * Browser preview only. A stand-in for the native engine that draws on a canvas, so the app's
 * screens can be run and looked at without an iPhone. It reads ordinary images (no RAW), treats
 * Display P3 as sRGB, and approximates everything Core Image does. Nothing here ships in the app.
 */

import type { PhotoInfo } from '@/engine/photo';
import type { RenderRecipe } from '@/engine/recipe';

import type { NativeRenderOptions, NativeRenderResult, PickedPhoto } from './index';

export type { NativeRenderOptions, NativeRenderResult, PickedPhoto } from './index';

export const isEngineAvailable = true;

const sessions = new Map<string, ImageBitmap>();
const slots = new Map<string, string>();
const PREVIEW_CAP = 1400;

const toLinear = new Float32Array(256);
for (let i = 0; i < 256; i++) {
  const v = i / 255;
  toLinear[i] = v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
}
const ENCODE_STEPS = 4095;
const toEncoded = new Float32Array(ENCODE_STEPS + 1);
for (let i = 0; i <= ENCODE_STEPS; i++) {
  const v = i / ENCODE_STEPS;
  toEncoded[i] = v <= 0.0031308 ? v * 12.92 : 1.055 * v ** (1 / 2.4) - 0.055;
}
const encode = (linear: number): number => toEncoded[Math.round(Math.min(1, Math.max(0, linear)) * ENCODE_STEPS)];

function pickFile(): Promise<File | null> {
  return new Promise((resolve) => {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = 'image/*';
    input.onchange = () => resolve(input.files?.[0] ?? null);
    input.oncancel = () => resolve(null);
    input.click();
  });
}

function draw(source: ImageBitmap, recipe: RenderRecipe, options: NativeRenderOptions): HTMLCanvasElement {
  const turned = recipe.rotation === 90 || recipe.rotation === 270;
  const frameWidth = turned ? source.height : source.width;
  const frameHeight = turned ? source.width : source.height;
  const radians = (recipe.angle * Math.PI) / 180;
  const long = Math.max(frameWidth / frameHeight, frameHeight / frameWidth);
  const trim = Math.abs(recipe.angle) > 0.001 ? 1 / (Math.cos(Math.abs(radians)) + long * Math.sin(Math.abs(radians))) : 1;
  const trimmedWidth = frameWidth * trim;
  const trimmedHeight = frameHeight * trim;
  const crop = options.fullFrame ? { x: 0, y: 0, width: 1, height: 1 } : { x: recipe.cropX, y: recipe.cropY, width: recipe.cropWidth, height: recipe.cropHeight };
  const fullWidth = trimmedWidth * crop.width;
  const fullHeight = trimmedHeight * crop.height;
  const edge = options.maxEdge > 0 ? Math.min(options.maxEdge, PREVIEW_CAP) : Math.max(fullWidth, fullHeight);
  const scale = Math.min(1, edge / Math.max(fullWidth, fullHeight));

  const canvas = document.createElement('canvas');
  canvas.width = Math.max(1, Math.round(fullWidth * scale));
  canvas.height = Math.max(1, Math.round(fullHeight * scale));
  const context = canvas.getContext('2d', { willReadFrequently: true })!;
  context.imageSmoothingQuality = 'high';
  context.scale(scale, scale);
  context.translate(-crop.x * trimmedWidth, -crop.y * trimmedHeight);
  context.translate(trimmedWidth / 2, trimmedHeight / 2);
  context.rotate(radians);
  context.rotate((recipe.rotation * Math.PI) / 180);
  context.scale(recipe.flipHorizontal ? -1 : 1, recipe.flipVertical ? -1 : 1);
  context.drawImage(source, -source.width / 2, -source.height / 2);
  return canvas;
}

function process(canvas: HTMLCanvasElement, recipe: RenderRecipe, toneTable: Uint8Array, cubeBytes: Uint8Array, vignette: boolean): void {
  const context = canvas.getContext('2d', { willReadFrequently: true })!;
  const image = context.getImageData(0, 0, canvas.width, canvas.height);
  const data = image.data;
  const gain = 2 ** recipe.exposureEV;
  // A rough white balance: warmer for higher temperatures, magenta for positive tint.
  const warmth = recipe.temperature ? Math.log2(recipe.temperature / 6500) : 0;
  const tint = (recipe.tint ?? 0) / 150;
  const gainR = gain * 2 ** (warmth * 0.55);
  const gainG = gain * 2 ** (-tint * 0.35);
  const gainB = gain * 2 ** (-warmth * 0.75);
  const tone = toneTable.length > 0 ? new Float32Array(toneTable.buffer, toneTable.byteOffset, toneTable.byteLength / 4) : null;
  const toneLast = recipe.toneTableSize - 1;
  const cube = cubeBytes.length > 0 ? new Float32Array(cubeBytes.buffer, cubeBytes.byteOffset, cubeBytes.byteLength / 4) : null;
  const n = recipe.cubeSize;
  const lift = recipe.shadowAmount;
  const recover = 1 - recipe.highlightAmount;
  const { width, height } = canvas;

  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const offset = (y * width + x) * 4;
      let r = encode(toLinear[data[offset]] * gainR);
      let g = encode(toLinear[data[offset + 1]] * gainG);
      let b = encode(toLinear[data[offset + 2]] * gainB);
      if (lift > 0 || recover > 0) {
        const luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        const factor = 1 + lift * 1.2 * (1 - luma) ** 3 - recover * 0.5 * luma ** 3;
        r = Math.min(1, r * factor);
        g = Math.min(1, g * factor);
        b = Math.min(1, b * factor);
      }
      if (tone) {
        r = tone[Math.round(r * toneLast) * 3];
        g = tone[Math.round(g * toneLast) * 3 + 1];
        b = tone[Math.round(b * toneLast) * 3 + 2];
      }
      if (cube) {
        // Trilinear lookup, red fastest.
        const fr = r * (n - 1);
        const fg = g * (n - 1);
        const fb = b * (n - 1);
        const r0 = Math.min(n - 2, Math.floor(fr));
        const g0 = Math.min(n - 2, Math.floor(fg));
        const b0 = Math.min(n - 2, Math.floor(fb));
        const tr = fr - r0;
        const tg = fg - g0;
        const tb = fb - b0;
        const out = [0, 0, 0];
        for (let corner = 0; corner < 8; corner++) {
          const dr = corner & 1;
          const dg = (corner >> 1) & 1;
          const db = (corner >> 2) & 1;
          const weight = (dr ? tr : 1 - tr) * (dg ? tg : 1 - tg) * (db ? tb : 1 - tb);
          const index = (((b0 + db) * n + (g0 + dg)) * n + (r0 + dr)) * 4;
          out[0] += cube[index] * weight;
          out[1] += cube[index + 1] * weight;
          out[2] += cube[index + 2] * weight;
        }
        [r, g, b] = out;
      }
      if (vignette && recipe.vignette !== 0) {
        const dx = (x / width - 0.5) * 2;
        const dy = (y / height - 0.5) * 2;
        const distance = Math.sqrt((dx * dx + dy * dy) / 2) * Math.SQRT2 * 0.5;
        const amount = Math.min(1, Math.max(0, (distance - 0.3) / 0.45));
        const factor = 2 ** (-1.6 * recipe.vignette * amount * 0.45);
        r *= factor;
        g *= factor;
        b *= factor;
      }
      data[offset] = Math.round(Math.min(1, Math.max(0, r)) * 255);
      data[offset + 1] = Math.round(Math.min(1, Math.max(0, g)) * 255);
      data[offset + 2] = Math.round(Math.min(1, Math.max(0, b)) * 255);
    }
  }
  context.putImageData(image, 0, 0);
}

function statistics(canvas: HTMLCanvasElement, edge: number): { pixels: Uint8Array; width: number; height: number } {
  const scale = Math.min(1, edge / Math.max(canvas.width, canvas.height));
  const small = document.createElement('canvas');
  small.width = Math.max(1, Math.round(canvas.width * scale));
  small.height = Math.max(1, Math.round(canvas.height * scale));
  const context = small.getContext('2d', { willReadFrequently: true })!;
  context.drawImage(canvas, 0, 0, small.width, small.height);
  return { pixels: new Uint8Array(context.getImageData(0, 0, small.width, small.height).data.buffer), width: small.width, height: small.height };
}

export const OscuruEngine = {
  async pickPhoto(): Promise<PickedPhoto | null> {
    const file = await pickFile();
    return file ? { uri: URL.createObjectURL(file), name: file.name, typeIdentifier: file.type } : null;
  },

  async open(sessionId: string, uri: string): Promise<PhotoInfo> {
    const blob = await (await fetch(uri)).blob();
    const bitmap = await createImageBitmap(blob);
    sessions.set(sessionId, bitmap);
    return {
      fileName: uri.split('/').pop() ?? 'photo',
      typeIdentifier: blob.type || 'public.image',
      isRaw: false,
      width: bitmap.width,
      height: bitmap.height,
      asShot: { temperature: 6500, tint: 0 },
      defaults: { temperature: 6500, tint: 0, sharpening: 0, noiseReduction: 0, colorNoiseReduction: 0 },
    };
  },

  async render(sessionId: string, recipe: RenderRecipe, toneTable: Uint8Array, cube: Uint8Array, options: NativeRenderOptions): Promise<NativeRenderResult> {
    const source = sessions.get(sessionId);
    if (!source) throw new Error(`No open photo with id ${sessionId}`);
    const canvas = draw(source, recipe, options);
    process(canvas, recipe, toneTable, cube, !options.fullFrame);
    const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, 'image/jpeg', options.quality));
    if (!blob) throw new Error('Rendering failed');
    const key = `${sessionId}/${options.slot}`;
    const previous = slots.get(key);
    const uri = URL.createObjectURL(blob);
    slots.set(key, uri);
    // The screen may still be showing the previous picture for a moment.
    if (previous) setTimeout(() => URL.revokeObjectURL(previous), 5000);
    const stats = options.statsEdge > 0 ? statistics(canvas, options.statsEdge) : { pixels: new Uint8Array(0), width: 0, height: 0 };
    return { uri, width: canvas.width, height: canvas.height, statsWidth: stats.width, statsHeight: stats.height, statsPixels: stats.pixels };
  },

  async close(sessionId: string): Promise<void> {
    sessions.get(sessionId)?.close();
    sessions.delete(sessionId);
  },
};
