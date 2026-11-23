/**
 * Turns an editing state into what the native renderer needs: plain filter parameters plus the
 * tone and colour tables. All the mapping from photographic settings to filter amounts lives here,
 * so it can be tested without a phone and adjusted without a new native build.
 */

import { buildColorCube, buildToneTables, CUBE_SIZE, TONE_TABLE_SIZE } from './color';
import { defaultState, type EditingState, type PhotoDefaults } from './state';

export interface LocalContrastPass {
  /** Blur radius as a fraction of the photo's long edge, so previews match exports. */
  radius: number;
  /** Unsharp-mask intensity. Negative softens. */
  intensity: number;
}

export interface RenderRecipe {
  exposureEV: number;
  /** White balance, or null to leave the photo as shot. */
  temperature: number | null;
  tint: number | null;
  /** Local shadow lift, 0 (off) to 1. */
  shadowAmount: number;
  /** Local highlight recovery, 1 (off) down to 0. */
  highlightAmount: number;
  localContrast: LocalContrastPass[];
  /** 0–1. Null leaves the RAW decoder's default. */
  sharpening: number | null;
  noiseReduction: number | null;
  colorNoiseReduction: number | null;
  /** −1 (lighten corners) to 1 (darken corners). */
  vignette: number;
  rotation: number;
  flipHorizontal: boolean;
  flipVertical: boolean;
  angle: number;
  cropX: number;
  cropY: number;
  cropWidth: number;
  cropHeight: number;
  toneTableSize: number;
  cubeSize: number;
}

export interface RenderInput {
  recipe: RenderRecipe;
  /** Float32 RGB triples for the tone stage, as bytes. Empty when the stage does nothing. */
  toneTable: Uint8Array;
  /** Float32 RGBA colour cube, red fastest, as bytes. Empty when the stage does nothing. */
  cube: Uint8Array;
}

const NO_BYTES = new Uint8Array(0);

const bytesOf = (table: Float32Array | null): Uint8Array =>
  table ? new Uint8Array(table.buffer, table.byteOffset, table.byteLength) : NO_BYTES;

export function buildRenderInput(state: EditingState, defaults?: Partial<PhotoDefaults>): RenderInput {
  const base = defaultState(defaults);
  const { global, detail, crop } = state;
  const localContrast: LocalContrastPass[] = [];
  if (global.clarity !== 0) localContrast.push({ radius: 0.02, intensity: (global.clarity / 100) * 0.7 });
  if (global.texture !== 0) localContrast.push({ radius: 0.003, intensity: (global.texture / 100) * 0.6 });
  const whiteBalanceTouched = global.temperature !== base.global.temperature || global.tint !== base.global.tint;
  const unlessDefault = (value: number, start: number): number | null => (value === start ? null : value / 100);
  return {
    recipe: {
      exposureEV: global.exposureEV,
      temperature: whiteBalanceTouched ? global.temperature : null,
      tint: whiteBalanceTouched ? global.tint : null,
      shadowAmount: global.shadows > 0 ? (global.shadows / 100) * 0.8 : 0,
      highlightAmount: global.highlights < 0 ? 1 + (global.highlights / 100) * 0.7 : 1,
      localContrast,
      sharpening: unlessDefault(detail.sharpening, base.detail.sharpening),
      noiseReduction: unlessDefault(detail.noiseReduction, base.detail.noiseReduction),
      colorNoiseReduction: unlessDefault(detail.colorNoiseReduction, base.detail.colorNoiseReduction),
      vignette: -global.vignette / 100,
      rotation: crop.rotation,
      flipHorizontal: crop.flipHorizontal,
      flipVertical: crop.flipVertical,
      angle: crop.angle,
      cropX: crop.x,
      cropY: crop.y,
      cropWidth: crop.width,
      cropHeight: crop.height,
      toneTableSize: TONE_TABLE_SIZE,
      cubeSize: CUBE_SIZE,
    },
    toneTable: bytesOf(buildToneTables(state)),
    cube: bytesOf(buildColorCube(state)),
  };
}
