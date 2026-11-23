/**
 * The point operations of the pipeline, evaluated in display-referred (gamma-encoded) Display P3:
 *
 *   tone   per channel: dehaze veil → blacks / whites → contrast → highlights (+) / shadows (−)
 *          → master curve → channel curve
 *   colour HSL ranges → vibrance → saturation → colour grading
 *
 * The renderer does not run this code per pixel. It applies `buildToneTables` as a 1D table per
 * channel and `buildColorCube` as a 3D table, both in Display P3, so what the tests check here is
 * exactly what reaches the photo. Exposure, white balance, the recovering directions of highlights
 * and shadows, and everything that needs neighbouring pixels happen in the native renderer.
 */

import { COLOR_RANGES, isIdentityCurve, type ColorGrading, type CurvePoint, type EditingState } from './state';

export const TONE_TABLE_SIZE = 256;
export const CUBE_SIZE = 33;

/** Display P3 luma weights. */
const LUMA_R = 0.229;
const LUMA_G = 0.6917;
const LUMA_B = 0.0793;

export function luma(r: number, g: number, b: number): number {
  return LUMA_R * r + LUMA_G * g + LUMA_B * b;
}

const clamp01 = (value: number): number => (value < 0 ? 0 : value > 1 ? 1 : value);

function smoothstep(edge0: number, edge1: number, value: number): number {
  const t = clamp01((value - edge0) / (edge1 - edge0));
  return t * t * (3 - 2 * t);
}

/**
 * A smooth curve through the control points that never overshoots between them
 * (monotone cubic, Fritsch–Carlson). Flat before the first point and after the last.
 */
export function curveEvaluator(points: CurvePoint[]): (x: number) => number {
  const n = points.length;
  const xs = points.map((p) => p[0]);
  const ys = points.map((p) => p[1]);
  const slopes: number[] = [];
  for (let i = 0; i < n - 1; i++) slopes.push((ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]));
  const tangents: number[] = new Array(n).fill(0);
  tangents[0] = slopes[0];
  tangents[n - 1] = slopes[n - 2];
  for (let i = 1; i < n - 1; i++) {
    tangents[i] = slopes[i - 1] * slopes[i] <= 0 ? 0 : (slopes[i - 1] + slopes[i]) / 2;
  }
  for (let i = 0; i < n - 1; i++) {
    if (slopes[i] === 0) {
      tangents[i] = 0;
      tangents[i + 1] = 0;
      continue;
    }
    const a = tangents[i] / slopes[i];
    const b = tangents[i + 1] / slopes[i];
    const length = a * a + b * b;
    if (length > 9) {
      const scale = 3 / Math.sqrt(length);
      tangents[i] = scale * a * slopes[i];
      tangents[i + 1] = scale * b * slopes[i];
    }
  }
  return (x: number): number => {
    if (x <= xs[0]) return ys[0];
    if (x >= xs[n - 1]) return ys[n - 1];
    let i = 0;
    while (x > xs[i + 1]) i++;
    const h = xs[i + 1] - xs[i];
    const t = (x - xs[i]) / h;
    const t2 = t * t;
    const t3 = t2 * t;
    const value =
      (2 * t3 - 3 * t2 + 1) * ys[i] +
      (t3 - 2 * t2 + t) * h * tangents[i] +
      (-2 * t3 + 3 * t2) * ys[i + 1] +
      (t3 - t2) * h * tangents[i + 1];
    return clamp01(value);
  };
}

/** The basic tone controls as one function of a channel value, before any curves. */
export function basicTone(state: EditingState): (x: number) => number {
  const { blacks, whites, contrast, highlights, shadows, dehaze } = state.global;
  const veil = dehaze / 100;
  const black = (blacks / 100) * 0.2;
  const white = (whites / 100) * 0.2;
  const c = contrast / 100;
  // Only the directions that do not recover detail are point operations; the others are local.
  const brighten = highlights > 0 ? (highlights / 100) * 0.12 : 0;
  const deepen = shadows < 0 ? (shadows / 100) * 0.12 : 0;
  return (input: number): number => {
    let x = input;
    if (veil > 0) {
      const floor = 0.12 * veil;
      x = (x - floor) / (1 - floor);
    } else if (veil < 0) {
      x = x * (1 + 0.3 * veil) - 0.3 * veil * 0.85;
    }
    if (black !== 0) x += black * (1 - clamp01(x)) ** 3;
    if (white !== 0) x += white * clamp01(x) ** 3;
    x = clamp01(x);
    if (c > 0) {
      const t = 2 * x - 1;
      const shaped = 1 - (1 - Math.abs(t)) ** (1 + c);
      x = 0.5 + 0.5 * (t < 0 ? -shaped : shaped);
    } else if (c < 0) {
      x = 0.5 + (x - 0.5) * (1 + 0.5 * c);
    }
    if (brighten !== 0) x += brighten * 6.75 * x * x * (1 - x);
    if (deepen !== 0) x += deepen * 6.75 * x * (1 - x) * (1 - x);
    return clamp01(x);
  };
}

function toneIsIdentity(state: EditingState): boolean {
  const g = state.global;
  return (
    g.blacks === 0 &&
    g.whites === 0 &&
    g.contrast === 0 &&
    g.highlights <= 0 &&
    g.shadows >= 0 &&
    g.dehaze === 0 &&
    isIdentityCurve(state.curves.rgb) &&
    isIdentityCurve(state.curves.red) &&
    isIdentityCurve(state.curves.green) &&
    isIdentityCurve(state.curves.blue)
  );
}

/**
 * The whole tone stage as three 1D tables (red, green, blue interleaved), or null when it changes
 * nothing. Entry i is the output for input i / (size − 1).
 */
export function buildToneTables(state: EditingState, size: number = TONE_TABLE_SIZE): Float32Array | null {
  if (toneIsIdentity(state)) return null;
  const basic = basicTone(state);
  const master = curveEvaluator(state.curves.rgb);
  const channels = [curveEvaluator(state.curves.red), curveEvaluator(state.curves.green), curveEvaluator(state.curves.blue)];
  const table = new Float32Array(size * 3);
  for (let i = 0; i < size; i++) {
    const shared = master(basic(i / (size - 1)));
    for (let channel = 0; channel < 3; channel++) table[i * 3 + channel] = channels[channel](shared);
  }
  return table;
}

function sampleTable(table: Float32Array, size: number, channel: number, x: number): number {
  const position = clamp01(x) * (size - 1);
  const index = Math.min(size - 2, Math.floor(position));
  const t = position - index;
  return table[index * 3 + channel] * (1 - t) + table[(index + 1) * 3 + channel] * t;
}

/** Centres of the eight HSL ranges, in degrees around the colour wheel. */
export const RANGE_HUES = [0, 30, 60, 120, 180, 240, 270, 300];

function hueOf(r: number, g: number, b: number, max: number, chroma: number): number {
  let hue: number;
  if (max === r) hue = ((g - b) / chroma) % 6;
  else if (max === g) hue = (b - r) / chroma + 2;
  else hue = (r - g) / chroma + 4;
  hue *= 60;
  return hue < 0 ? hue + 360 : hue;
}

/** A unit-strength colour offset for a hue that adds no luma: the direction a tint pushes towards. */
function tintDirection(hue: number): [number, number, number] {
  const h = (((hue % 360) + 360) % 360) / 60;
  const x = 1 - Math.abs((h % 2) - 1);
  const sector = Math.floor(h);
  const rgb: [number, number, number] =
    sector === 0 ? [1, x, 0] : sector === 1 ? [x, 1, 0] : sector === 2 ? [0, 1, x] : sector === 3 ? [0, x, 1] : sector === 4 ? [x, 0, 1] : [1, 0, x];
  const y = luma(rgb[0], rgb[1], rgb[2]);
  return [rgb[0] - y, rgb[1] - y, rgb[2] - y];
}

/** Pulls a colour back inside 0–1 by reducing its colourfulness, keeping its luma. */
function fitGamut(rgb: [number, number, number]): void {
  const y = clamp01(luma(rgb[0], rgb[1], rgb[2]));
  let scale = 1;
  for (let i = 0; i < 3; i++) {
    const delta = rgb[i] - y;
    if (rgb[i] > 1 && delta > 0) scale = Math.min(scale, (1 - y) / delta);
    else if (rgb[i] < 0 && delta < 0) scale = Math.min(scale, y / -delta);
  }
  for (let i = 0; i < 3; i++) rgb[i] = clamp01(y + (rgb[i] - y) * scale);
}

interface ColorStage {
  apply(rgb: [number, number, number]): void;
}

const gradeIsOff = (grade: ColorGrading): boolean => grade.saturation === 0 && grade.luminance === 0;

function colorIsIdentity(state: EditingState): boolean {
  const g = state.global;
  return (
    g.vibrance === 0 &&
    g.saturation === 0 &&
    g.dehaze === 0 &&
    COLOR_RANGES.every((color) => {
      const hsl = state.hsl[color];
      return hsl.hue === 0 && hsl.saturation === 0 && hsl.luminance === 0;
    }) &&
    gradeIsOff(state.grading.shadows) &&
    gradeIsOff(state.grading.midtones) &&
    gradeIsOff(state.grading.highlights)
  );
}

function colorStage(state: EditingState): ColorStage {
  const hslHue = COLOR_RANGES.map((color) => state.hsl[color].hue / 100);
  const hslSaturation = COLOR_RANGES.map((color) => state.hsl[color].saturation / 100);
  const hslLuminance = COLOR_RANGES.map((color) => state.hsl[color].luminance / 100);
  const hslActive = COLOR_RANGES.some((_, i) => hslHue[i] !== 0 || hslSaturation[i] !== 0 || hslLuminance[i] !== 0);
  const vibrance = state.global.vibrance / 100;
  // Dehaze also restores (or washes out) some colour.
  const saturation = (1 + state.global.saturation / 100) * (1 + 0.2 * (state.global.dehaze / 100));
  const { grading } = state;
  const gradingActive = !gradeIsOff(grading.shadows) || !gradeIsOff(grading.midtones) || !gradeIsOff(grading.highlights);
  const tints = [grading.shadows, grading.midtones, grading.highlights].map((grade) => {
    const direction = tintDirection(grade.hue);
    const strength = grade.saturation * 0.5;
    const lift = grade.luminance * 0.3;
    return [direction[0] * strength + lift, direction[1] * strength + lift, direction[2] * strength + lift];
  });
  const balancePower = 2 ** -grading.balance;
  const rangePower = 2 + 3 * (1 - grading.blending);

  return {
    apply(rgb) {
      let [r, g, b] = rgb;
      let max = Math.max(r, g, b);
      let min = Math.min(r, g, b);
      let chroma = max - min;

      if (hslActive && chroma > 1e-5) {
        const hue = hueOf(r, g, b, max, chroma);
        // Near-greys and near-blacks have no reliable hue: fade the adjustment out there.
        const mask = smoothstep(0.04, 0.25, chroma / max) * smoothstep(0.02, 0.12, max);
        let index = 7;
        for (let i = 0; i < 7; i++) {
          if (hue < RANGE_HUES[i + 1]) {
            index = i;
            break;
          }
        }
        const next = (index + 1) % 8;
        const span = (index === 7 ? 360 : RANGE_HUES[next]) - RANGE_HUES[index];
        const t = (hue - RANGE_HUES[index]) / span;
        const w0 = (1 - t) * mask;
        const w1 = t * mask;
        const hueShift = (w0 * hslHue[index] + w1 * hslHue[next]) * 30;
        const saturationShift = w0 * hslSaturation[index] + w1 * hslSaturation[next];
        const luminanceShift = w0 * hslLuminance[index] + w1 * hslLuminance[next];
        const y = luma(r, g, b);
        if (hueShift !== 0) {
          // Turn the colour around the grey axis, then restore its luma.
          const angle = (hueShift * Math.PI) / 180;
          const cos = Math.cos(angle);
          const k = (1 - cos) / 3;
          const s = Math.sin(angle) / Math.sqrt(3);
          const nr = r * (cos + k) + g * (k - s) + b * (k + s);
          const ng = r * (k + s) + g * (cos + k) + b * (k - s);
          const nb = r * (k - s) + g * (k + s) + b * (cos + k);
          const fix = y - luma(nr, ng, nb);
          r = nr + fix;
          g = ng + fix;
          b = nb + fix;
        }
        if (saturationShift !== 0) {
          const factor = 1 + saturationShift;
          r = y + (r - y) * factor;
          g = y + (g - y) * factor;
          b = y + (b - y) * factor;
        }
        if (luminanceShift !== 0) {
          const factor = 1 + 0.6 * luminanceShift;
          r *= factor;
          g *= factor;
          b *= factor;
        }
        rgb[0] = r;
        rgb[1] = g;
        rgb[2] = b;
        fitGamut(rgb);
        [r, g, b] = rgb;
        max = Math.max(r, g, b);
        min = Math.min(r, g, b);
        chroma = max - min;
      }

      let factor = saturation;
      if (vibrance !== 0 && chroma > 1e-5) {
        const colourfulness = chroma / max;
        if (vibrance > 0) {
          const hue = hueOf(r, g, b, max, chroma);
          const skin = Math.max(0, 1 - Math.abs(hue - 25) / 25);
          factor *= 1 + vibrance * (1 - colourfulness) ** 1.5 * (1 - 0.5 * skin);
        } else {
          factor *= 1 + vibrance * (1 - 0.5 * colourfulness);
        }
      }
      if (factor !== 1) {
        const y = luma(r, g, b);
        rgb[0] = y + (r - y) * factor;
        rgb[1] = y + (g - y) * factor;
        rgb[2] = y + (b - y) * factor;
        fitGamut(rgb);
        [r, g, b] = rgb;
      }

      if (gradingActive) {
        const y = clamp01(luma(r, g, b)) ** balancePower;
        const shadows = (1 - y) ** rangePower;
        const highlights = y ** rangePower;
        const midtones = 1 - shadows - highlights;
        r += shadows * tints[0][0] + midtones * tints[1][0] + highlights * tints[2][0];
        g += shadows * tints[0][1] + midtones * tints[1][1] + highlights * tints[2][1];
        b += shadows * tints[0][2] + midtones * tints[1][2] + highlights * tints[2][2];
      }

      rgb[0] = clamp01(r);
      rgb[1] = clamp01(g);
      rgb[2] = clamp01(b);
    },
  };
}

/**
 * The colour stage as a 3D table of RGBA floats with red varying fastest (the layout Core Image
 * expects), or null when it changes nothing.
 */
export function buildColorCube(state: EditingState, size: number = CUBE_SIZE): Float32Array | null {
  if (colorIsIdentity(state)) return null;
  const stage = colorStage(state);
  const cube = new Float32Array(size * size * size * 4);
  const rgb: [number, number, number] = [0, 0, 0];
  const step = 1 / (size - 1);
  let offset = 0;
  for (let b = 0; b < size; b++) {
    for (let g = 0; g < size; g++) {
      for (let r = 0; r < size; r++) {
        rgb[0] = r * step;
        rgb[1] = g * step;
        rgb[2] = b * step;
        stage.apply(rgb);
        cube[offset++] = rgb[0];
        cube[offset++] = rgb[1];
        cube[offset++] = rgb[2];
        cube[offset++] = 1;
      }
    }
  }
  return cube;
}

/** Runs one Display P3 colour through the tone and colour stages exactly (no table lookups). */
export function applyPointOps(state: EditingState, input: [number, number, number]): [number, number, number] {
  const rgb: [number, number, number] = [clamp01(input[0]), clamp01(input[1]), clamp01(input[2])];
  const table = buildToneTables(state, 1024);
  if (table) {
    for (let channel = 0; channel < 3; channel++) rgb[channel] = sampleTable(table, 1024, channel, rgb[channel]);
  }
  if (!colorIsIdentity(state)) colorStage(state).apply(rgb);
  return rgb;
}
