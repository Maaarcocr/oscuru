/**
 * Histogram and statistics of a rendered preview. The renderer hands back a small sRGB RGBA8
 * bitmap of the developed photo; everything here is measured on those display-referred values.
 */

import { COLOR_RANGES, type ColorRange } from './state';
import { RANGE_HUES } from './color';

export const HISTOGRAM_BINS = 256;

export interface Histogram {
  bins: number;
  /** Fraction of pixels in each bin, 0 (black) to 255 (white). Each array sums to 1. */
  luminance: number[];
  red: number[];
  green: number[];
  blue: number[];
  /** Fraction of pixels with at least one channel at the very top / all channels at the very bottom. */
  highlightClipping: number;
  shadowClipping: number;
}

export interface ImageStatistics {
  /** Size of the bitmap the numbers were measured on. */
  width: number;
  height: number;
  meanLuminance: number;
  medianLuminance: number;
  /** Luminance below which the given percentage of pixels fall. */
  percentiles: { p1: number; p5: number; p25: number; p50: number; p75: number; p95: number; p99: number };
  /** Standard deviation of luminance. */
  contrast: number;
  /** p99 − p1. */
  dynamicRange: number;
  averageSaturation: number;
  meanRGB: [number, number, number];
  /** Mean of each channel minus the mean of all three: a positive red means a warm/red cast. */
  colorCast: { red: number; green: number; blue: number };
  highlightClipping: number;
  shadowClipping: number;
  clippedChannels: { red: number; green: number; blue: number };
  /** Mean luminance of a 3×3 grid, rows from the top, each row left to right. */
  zones: number[][];
  /** Share of clearly coloured pixels that fall in each HSL range, and the share that is near-neutral. */
  colorDistribution: Record<ColorRange, number> & { neutral: number };
}

export interface ImageAnalysis {
  histogram: Histogram;
  statistics: ImageStatistics;
}

const CLIP_HIGH = 253;
const CLIP_LOW = 2;

const round = (value: number, digits = 4): number => {
  const scale = 10 ** digits;
  return Math.round(value * scale) / scale;
};

/** Measures an sRGB RGBA8 bitmap (row-major, top row first). */
export function analyzePixels(pixels: Uint8Array, width: number, height: number): ImageAnalysis {
  const count = width * height;
  if (count === 0 || pixels.length < count * 4) throw new Error('analyzePixels: bitmap is empty or shorter than width × height');
  const luminance = new Array<number>(HISTOGRAM_BINS).fill(0);
  const red = new Array<number>(HISTOGRAM_BINS).fill(0);
  const green = new Array<number>(HISTOGRAM_BINS).fill(0);
  const blue = new Array<number>(HISTOGRAM_BINS).fill(0);
  const zoneSum = new Array<number>(9).fill(0);
  const zoneCount = new Array<number>(9).fill(0);
  const rangeCount = new Array<number>(8).fill(0);
  let neutral = 0;
  let highlightClipped = 0;
  let shadowClipped = 0;
  let clippedRed = 0;
  let clippedGreen = 0;
  let clippedBlue = 0;
  let sumR = 0;
  let sumG = 0;
  let sumB = 0;
  let sumY = 0;
  let sumY2 = 0;
  let sumSaturation = 0;

  for (let y = 0; y < height; y++) {
    const zoneRow = Math.min(2, Math.floor((y * 3) / height));
    for (let x = 0; x < width; x++) {
      const offset = (y * width + x) * 4;
      const r = pixels[offset];
      const g = pixels[offset + 1];
      const b = pixels[offset + 2];
      const value = 0.2126 * r + 0.7152 * g + 0.0722 * b;
      luminance[Math.min(255, Math.round(value))]++;
      red[r]++;
      green[g]++;
      blue[b]++;
      sumR += r;
      sumG += g;
      sumB += b;
      sumY += value;
      sumY2 += value * value;
      const zone = zoneRow * 3 + Math.min(2, Math.floor((x * 3) / width));
      zoneSum[zone] += value;
      zoneCount[zone]++;
      const max = Math.max(r, g, b);
      const min = Math.min(r, g, b);
      if (max >= CLIP_HIGH) highlightClipped++;
      if (max <= CLIP_LOW) shadowClipped++;
      if (r >= CLIP_HIGH) clippedRed++;
      if (g >= CLIP_HIGH) clippedGreen++;
      if (b >= CLIP_HIGH) clippedBlue++;
      const chroma = max - min;
      const saturation = max === 0 ? 0 : chroma / max;
      sumSaturation += saturation;
      if (saturation < 0.15 || max < 30) {
        neutral++;
      } else {
        let hue: number;
        if (max === r) hue = ((g - b) / chroma) % 6;
        else if (max === g) hue = (b - r) / chroma + 2;
        else hue = (r - g) / chroma + 4;
        hue *= 60;
        if (hue < 0) hue += 360;
        // Nearest range centre around the wheel.
        let best = 0;
        let bestDistance = 360;
        for (let i = 0; i < 8; i++) {
          const distance = Math.min(Math.abs(hue - RANGE_HUES[i]), 360 - Math.abs(hue - RANGE_HUES[i]));
          if (distance < bestDistance) {
            bestDistance = distance;
            best = i;
          }
        }
        rangeCount[best]++;
      }
    }
  }

  const percentile = (fraction: number): number => {
    const target = fraction * count;
    let seen = 0;
    for (let i = 0; i < HISTOGRAM_BINS; i++) {
      seen += luminance[i];
      if (seen >= target) return round(i / 255);
    }
    return 1;
  };
  const normalize = (bins: number[]): number[] => bins.map((value) => round(value / count, 5));
  const mean = sumY / count;
  const meanR = sumR / count / 255;
  const meanG = sumG / count / 255;
  const meanB = sumB / count / 255;
  const grey = (meanR + meanG + meanB) / 3;
  const p1 = percentile(0.01);
  const p99 = percentile(0.99);
  const coloured = count - neutral;
  const colorDistribution = { neutral: round(neutral / count) } as Record<ColorRange, number> & { neutral: number };
  COLOR_RANGES.forEach((color, i) => {
    colorDistribution[color] = coloured === 0 ? 0 : round(rangeCount[i] / count);
  });
  const zones: number[][] = [];
  for (let row = 0; row < 3; row++) {
    zones.push([0, 1, 2].map((column) => round(zoneSum[row * 3 + column] / Math.max(1, zoneCount[row * 3 + column]) / 255, 3)));
  }
  const highlightClipping = round(highlightClipped / count);
  const shadowClipping = round(shadowClipped / count);

  return {
    histogram: {
      bins: HISTOGRAM_BINS,
      luminance: normalize(luminance),
      red: normalize(red),
      green: normalize(green),
      blue: normalize(blue),
      highlightClipping,
      shadowClipping,
    },
    statistics: {
      width,
      height,
      meanLuminance: round(mean / 255),
      medianLuminance: percentile(0.5),
      percentiles: { p1, p5: percentile(0.05), p25: percentile(0.25), p50: percentile(0.5), p75: percentile(0.75), p95: percentile(0.95), p99 },
      contrast: round(Math.sqrt(Math.max(0, sumY2 / count - mean * mean)) / 255),
      dynamicRange: round(p99 - p1),
      averageSaturation: round(sumSaturation / count),
      meanRGB: [round(meanR), round(meanG), round(meanB)],
      colorCast: { red: round(meanR - grey), green: round(meanG - grey), blue: round(meanB - grey) },
      highlightClipping,
      shadowClipping,
      clippedChannels: { red: round(clippedRed / count), green: round(clippedGreen / count), blue: round(clippedBlue / count) },
      zones,
      colorDistribution,
    },
  };
}
