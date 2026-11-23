/** Geometry for the crop tool. Rectangles are fractions of the straightened frame, measured from its top-left corner. */

import type { PhotoInfo } from '@/engine/photo';
import { MIN_CROP_SIZE, type CropSettings } from '@/engine/state';

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export type Corner = 'tl' | 'tr' | 'bl' | 'br';

const clamp = (value: number, min: number, max: number): number => Math.min(max, Math.max(min, value));
const tidy = (value: number): number => Math.round(value * 10000) / 10000;

function tidyRect(rect: Rect): Rect {
  const width = clamp(tidy(rect.width), MIN_CROP_SIZE, 1);
  const height = clamp(tidy(rect.height), MIN_CROP_SIZE, 1);
  return { x: clamp(tidy(rect.x), 0, tidy(1 - width)), y: clamp(tidy(rect.y), 0, tidy(1 - height)), width, height };
}

/** Width divided by height of the frame the crop rectangle lives in, in pixels. */
export function frameAspect(info: Pick<PhotoInfo, 'width' | 'height'>, crop: Pick<CropSettings, 'rotation'>): number {
  return crop.rotation === 90 || crop.rotation === 270 ? info.height / info.width : info.width / info.height;
}

/** Width divided by height of the cropped photo, in pixels. */
export function cropAspect(info: Pick<PhotoInfo, 'width' | 'height'>, crop: CropSettings): number {
  return (frameAspect(info, crop) * crop.width) / crop.height;
}

/** The largest centred rectangle with the given pixel proportions. */
export function cropForAspect(frame: number, aspect: number): Rect {
  const ratio = aspect / frame;
  return tidyRect(ratio >= 1 ? { x: 0, y: (1 - 1 / ratio) / 2, width: 1, height: 1 / ratio } : { x: (1 - ratio) / 2, y: 0, width: ratio, height: 1 });
}

export function moveCrop(start: Rect, dx: number, dy: number): Rect {
  return tidyRect({ ...start, x: clamp(start.x + dx, 0, 1 - start.width), y: clamp(start.y + dy, 0, 1 - start.height) });
}

/**
 * Drags one corner by (dx, dy), keeping the opposite corner where it is. `ratio` is the locked
 * width-to-height ratio in frame fractions (pixel aspect divided by the frame's), or null when free.
 */
export function resizeCrop(start: Rect, corner: Corner, dx: number, dy: number, ratio: number | null): Rect {
  const left = corner === 'tl' || corner === 'bl';
  const top = corner === 'tl' || corner === 'tr';
  const anchorX = left ? start.x + start.width : start.x;
  const anchorY = top ? start.y + start.height : start.y;
  const maxWidth = left ? anchorX : 1 - anchorX;
  const maxHeight = top ? anchorY : 1 - anchorY;
  let width = clamp(start.width + (left ? -dx : dx), MIN_CROP_SIZE, maxWidth);
  let height = clamp(start.height + (top ? -dy : dy), MIN_CROP_SIZE, maxHeight);
  if (ratio) {
    height = width / ratio;
    if (height > maxHeight) {
      height = maxHeight;
      width = height * ratio;
    }
    if (height < MIN_CROP_SIZE) {
      height = MIN_CROP_SIZE;
      width = Math.min(maxWidth, height * ratio);
    }
  }
  return tidyRect({ x: left ? anchorX - width : anchorX, y: top ? anchorY - height : anchorY, width, height });
}

/** Turns the photo a quarter turn; the crop rectangle turns with it. */
export function rotateCrop(crop: CropSettings, direction: 'left' | 'right'): CropSettings {
  const rotation = ((crop.rotation + (direction === 'right' ? 90 : 270)) % 360) as CropSettings['rotation'];
  const rect: Rect =
    direction === 'right'
      ? { x: 1 - crop.y - crop.height, y: crop.x, width: crop.height, height: crop.width }
      : { x: crop.y, y: 1 - crop.x - crop.width, width: crop.height, height: crop.width };
  return { ...crop, ...tidyRect(rect), rotation };
}

/**
 * Mirrors the photo as it appears on screen. Flips happen before rotation in the pipeline, so on a
 * photo turned on its side a mirror across the screen is a flip of the other axis.
 */
export function flipCrop(crop: CropSettings, axis: 'horizontal' | 'vertical'): CropSettings {
  const sideways = crop.rotation === 90 || crop.rotation === 270;
  const flag = (axis === 'horizontal') !== sideways ? 'flipHorizontal' : 'flipVertical';
  const rect: Rect =
    axis === 'horizontal' ? { ...crop, x: 1 - crop.x - crop.width } : { ...crop, y: 1 - crop.y - crop.height };
  return { ...crop, ...tidyRect(rect), [flag]: !crop[flag], angle: crop.angle === 0 ? 0 : -crop.angle };
}
