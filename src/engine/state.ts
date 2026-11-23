/**
 * The non-destructive editing state: plain, serializable data that fully describes how a photo
 * is developed. The manual controls, the scripting API and the renderer all work on this one shape.
 *
 * Every function here returns a new state and throws `StateError` for anything out of range, so a
 * state that exists is always a valid one.
 */

export const COLOR_RANGES = ['red', 'orange', 'yellow', 'green', 'aqua', 'blue', 'purple', 'magenta'] as const;
export type ColorRange = (typeof COLOR_RANGES)[number];

export const CURVE_CHANNELS = ['rgb', 'red', 'green', 'blue'] as const;
export type CurveChannel = (typeof CURVE_CHANNELS)[number];

export const GRADING_RANGES = ['shadows', 'midtones', 'highlights'] as const;
export type GradingRange = (typeof GRADING_RANGES)[number];

export type CurvePoint = [number, number];

export interface GlobalAdjustments {
  exposureEV: number;
  contrast: number;
  highlights: number;
  shadows: number;
  whites: number;
  blacks: number;
  temperature: number;
  tint: number;
  texture: number;
  clarity: number;
  dehaze: number;
  vibrance: number;
  saturation: number;
  vignette: number;
}

export interface HSLAdjustments {
  hue: number;
  saturation: number;
  luminance: number;
}

export interface ColorGrading {
  hue: number;
  saturation: number;
  luminance: number;
}

export interface GradingState {
  shadows: ColorGrading;
  midtones: ColorGrading;
  highlights: ColorGrading;
  blending: number;
  balance: number;
}

export interface DetailSettings {
  sharpening: number;
  noiseReduction: number;
  colorNoiseReduction: number;
}

export interface CropSettings {
  /** Crop rectangle, as fractions of the frame after flips, rotation and straightening. */
  x: number;
  y: number;
  width: number;
  height: number;
  /** Straighten angle in degrees. */
  angle: number;
  /** Quarter turns, clockwise, in degrees. */
  rotation: 0 | 90 | 180 | 270;
  flipHorizontal: boolean;
  flipVertical: boolean;
}

export interface EditingState {
  global: GlobalAdjustments;
  curves: Record<CurveChannel, CurvePoint[]>;
  hsl: Record<ColorRange, HSLAdjustments>;
  grading: GradingState;
  detail: DetailSettings;
  crop: CropSettings;
}

export interface ParamSpec {
  min: number;
  max: number;
  default: number;
  step: number;
  unit: string;
  description: string;
}

const tone = (description: string): ParamSpec => ({ min: -100, max: 100, default: 0, step: 1, unit: '', description });

export const GLOBAL_SPECS: Record<keyof GlobalAdjustments, ParamSpec> = {
  exposureEV: {
    min: -5,
    max: 5,
    default: 0,
    step: 0.05,
    unit: 'stops',
    description: 'Exposure compensation in photographic stops, applied to linear scene data (in the RAW decoder for RAW files).',
  },
  contrast: tone('Global contrast around mid-grey. Positive is an S-curve, negative flattens.'),
  highlights: tone('Negative recovers bright areas (local, keeps their contrast); positive brightens them.'),
  shadows: tone('Positive opens dark areas (local, keeps their contrast); negative deepens them.'),
  whites: tone('Moves the white point: positive brightens the top of the range and can clip, negative pulls it down.'),
  blacks: tone('Moves the black point: negative deepens and can clip, positive lifts (a matte look).'),
  temperature: {
    min: 2000,
    max: 25000,
    default: 6500,
    step: 50,
    unit: 'K',
    description:
      'White balance in Kelvin, as in Camera Raw: a higher value makes the photo warmer.',
  },
  tint: {
    min: -150,
    max: 150,
    default: 0,
    step: 1,
    unit: '',
    description: 'White balance tint: negative is greener, positive is more magenta.',
  },
  texture: tone('Fine local contrast (small details). Negative smooths.'),
  clarity: tone('Mid-size local contrast. Negative gives a soft glow.'),
  dehaze: tone('Approximate global dehaze: positive removes a veil (deeper blacks, more colour), negative adds one.'),
  vibrance: tone('Saturation that favours muted colours and protects skin tones.'),
  saturation: tone('Uniform saturation. -100 is black and white, +100 doubles colourfulness.'),
  vignette: tone('Negative darkens the corners of the cropped frame, positive lightens them.'),
};

export const HSL_SPECS: Record<keyof HSLAdjustments, ParamSpec> = {
  hue: tone('Shifts the hue of this colour range; ±100 is about ±30° around the colour wheel.'),
  saturation: tone('Saturation of this colour range. -100 removes its colour.'),
  luminance: tone('Brightness of this colour range.'),
};

export const GRADING_SPECS: Record<keyof ColorGrading, ParamSpec> = {
  hue: { min: 0, max: 360, default: 0, step: 1, unit: '°', description: 'Hue of the tint (0 red, 60 yellow, 120 green, 180 cyan, 240 blue, 300 magenta).' },
  saturation: { min: 0, max: 1, default: 0, step: 0.01, unit: '', description: 'Strength of the tint. 0 is off; 0.05–0.2 is a typical grade.' },
  luminance: { min: -1, max: 1, default: 0, step: 0.01, unit: '', description: 'Darkens or brightens this tonal range.' },
};

export const GRADING_MIX_SPECS: Record<'blending' | 'balance', ParamSpec> = {
  blending: { min: 0, max: 1, default: 0.5, step: 0.01, unit: '', description: 'How much the three tonal ranges overlap. 0 is separated, 1 is broad.' },
  balance: { min: -1, max: 1, default: 0, step: 0.01, unit: '', description: 'Shifts the split between ranges: positive gives highlights more of the image, negative shadows.' },
};

export const DETAIL_SPECS: Record<keyof DetailSettings, ParamSpec> = {
  sharpening: { min: 0, max: 100, default: 0, step: 1, unit: '', description: 'Sharpening amount. RAW files start at the decoder\'s own default.' },
  noiseReduction: { min: 0, max: 100, default: 0, step: 1, unit: '', description: 'Luminance noise reduction. RAW files start at the decoder\'s own default.' },
  colorNoiseReduction: { min: 0, max: 100, default: 0, step: 1, unit: '', description: 'Colour noise reduction (RAW files only; they start at the decoder\'s own default).' },
};

export const CROP_ANGLE_SPEC: ParamSpec = {
  min: -45,
  max: 45,
  default: 0,
  step: 0.1,
  unit: '°',
  description: 'Straighten angle. Positive turns the photo clockwise. The frame is trimmed so no empty corners show.',
};

export const MAX_CURVE_POINTS = 16;
export const MIN_CROP_SIZE = 0.05;
const MIN_CURVE_GAP = 0.004;

export class StateError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'RangeError';
  }
}

const identityCurve = (): CurvePoint[] => [
  [0, 0],
  [1, 1],
];

export const DEFAULT_CROP: CropSettings = {
  x: 0,
  y: 0,
  width: 1,
  height: 1,
  angle: 0,
  rotation: 0,
  flipHorizontal: false,
  flipVertical: false,
};

/**
 * Where a photo starts, when that is not the generic default: the as-shot white balance and the
 * RAW decoder's own sharpening and noise reduction.
 */
export interface PhotoDefaults {
  temperature: number;
  tint: number;
  sharpening: number;
  noiseReduction: number;
  colorNoiseReduction: number;
}

/** The state of an untouched photo. */
export function defaultState(base?: Partial<PhotoDefaults>): EditingState {
  const global = {} as GlobalAdjustments;
  for (const key of Object.keys(GLOBAL_SPECS) as (keyof GlobalAdjustments)[]) global[key] = GLOBAL_SPECS[key].default;
  const start = (value: number | undefined, spec: ParamSpec): number =>
    value === undefined || !Number.isFinite(value) ? spec.default : clamp(Math.round(value), spec.min, spec.max);
  global.temperature = start(base?.temperature, GLOBAL_SPECS.temperature);
  global.tint = start(base?.tint, GLOBAL_SPECS.tint);
  const hsl = {} as Record<ColorRange, HSLAdjustments>;
  for (const color of COLOR_RANGES) hsl[color] = { hue: 0, saturation: 0, luminance: 0 };
  const grade = (): ColorGrading => ({ hue: 0, saturation: 0, luminance: 0 });
  return {
    global,
    curves: { rgb: identityCurve(), red: identityCurve(), green: identityCurve(), blue: identityCurve() },
    hsl,
    grading: { shadows: grade(), midtones: grade(), highlights: grade(), blending: 0.5, balance: 0 },
    detail: {
      sharpening: start(base?.sharpening, DETAIL_SPECS.sharpening),
      noiseReduction: start(base?.noiseReduction, DETAIL_SPECS.noiseReduction),
      colorNoiseReduction: start(base?.colorNoiseReduction, DETAIL_SPECS.colorNoiseReduction),
    },
    crop: { ...DEFAULT_CROP },
  };
}

export function cloneState(state: EditingState): EditingState {
  return JSON.parse(JSON.stringify(state)) as EditingState;
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function checkNumber(path: string, value: unknown, spec: { min: number; max: number }): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new StateError(`${path} must be a finite number, got ${describe(value)}`);
  }
  if (value < spec.min || value > spec.max) {
    throw new StateError(`${path} must be between ${spec.min} and ${spec.max}, got ${value}`);
  }
  return value;
}

function describe(value: unknown): string {
  if (typeof value === 'string') return JSON.stringify(value);
  if (typeof value === 'number' || typeof value === 'boolean' || value == null) return String(value);
  return Array.isArray(value) ? 'an array' : typeof value;
}

function checkKeys<K extends string>(path: string, value: unknown, allowed: readonly K[]): Partial<Record<K, unknown>> {
  if (!isPlainObject(value)) throw new StateError(`${path} must be an object, got ${describe(value)}`);
  for (const key of Object.keys(value)) {
    if (!(allowed as readonly string[]).includes(key)) {
      throw new StateError(`${path} has no setting "${key}". Valid settings: ${allowed.join(', ')}`);
    }
  }
  return value as Partial<Record<K, unknown>>;
}

function checkNumbers<K extends string>(path: string, value: unknown, specs: Record<K, ParamSpec>): Partial<Record<K, number>> {
  const keys = Object.keys(specs) as K[];
  const input = checkKeys(path, value, keys);
  const result: Partial<Record<K, number>> = {};
  for (const key of keys) {
    if (input[key] !== undefined) result[key] = checkNumber(`${path}.${key}`, input[key], specs[key]);
  }
  return result;
}

function oneOf<T extends string>(path: string, value: unknown, allowed: readonly T[]): T {
  if (typeof value !== 'string' || !(allowed as readonly string[]).includes(value)) {
    throw new StateError(`${path} must be one of ${allowed.map((v) => `"${v}"`).join(', ')}, got ${describe(value)}`);
  }
  return value as T;
}

/** Sets global adjustments to the given absolute values. Settings that are left out keep their value. */
export function adjustGlobal(state: EditingState, settings: unknown): EditingState {
  return { ...state, global: { ...state.global, ...checkNumbers('adjust', settings, GLOBAL_SPECS) } };
}

/** Checks and normalizes curve control points: sorted by input, inside 0–1, with distinct inputs. */
export function normalizeCurve(path: string, points: unknown): CurvePoint[] {
  if (!Array.isArray(points)) throw new StateError(`${path} must be an array of [input, output] points`);
  if (points.length < 2 || points.length > MAX_CURVE_POINTS) {
    throw new StateError(`${path} needs between 2 and ${MAX_CURVE_POINTS} points, got ${points.length}`);
  }
  const result: CurvePoint[] = points.map((point, index) => {
    if (!Array.isArray(point) || point.length !== 2) {
      throw new StateError(`${path}[${index}] must be an [input, output] pair`);
    }
    return [
      checkNumber(`${path}[${index}][0]`, point[0], { min: 0, max: 1 }),
      checkNumber(`${path}[${index}][1]`, point[1], { min: 0, max: 1 }),
    ];
  });
  result.sort((a, b) => a[0] - b[0]);
  for (let i = 1; i < result.length; i++) {
    if (result[i][0] - result[i - 1][0] < MIN_CURVE_GAP) {
      throw new StateError(`${path} has two points with (almost) the same input ${result[i][0]}; inputs must differ by at least ${MIN_CURVE_GAP}`);
    }
  }
  return result;
}

export function setCurve(state: EditingState, channel: unknown, points: unknown): EditingState {
  const name = oneOf('curve channel', channel, CURVE_CHANNELS);
  return { ...state, curves: { ...state.curves, [name]: normalizeCurve(`curves.${name}`, points) } };
}

export function adjustHSL(state: EditingState, color: unknown, adjustments: unknown): EditingState {
  const name = oneOf('hsl colour', color, COLOR_RANGES);
  const values = checkNumbers(`hsl.${name}`, adjustments, HSL_SPECS);
  return { ...state, hsl: { ...state.hsl, [name]: { ...state.hsl[name], ...values } } };
}

export function setGrading(state: EditingState, range: unknown, settings: unknown): EditingState {
  const name = oneOf('grading range', range, GRADING_RANGES);
  const values = checkNumbers(`grading.${name}`, settings, GRADING_SPECS);
  return { ...state, grading: { ...state.grading, [name]: { ...state.grading[name], ...values } } };
}

export function setGradingMix(state: EditingState, settings: unknown): EditingState {
  return { ...state, grading: { ...state.grading, ...checkNumbers('grading', settings, GRADING_MIX_SPECS) } };
}

export function setDetail(state: EditingState, settings: unknown): EditingState {
  return { ...state, detail: { ...state.detail, ...checkNumbers('detail', settings, DETAIL_SPECS) } };
}

const CROP_KEYS = ['x', 'y', 'width', 'height', 'angle', 'rotation', 'flipHorizontal', 'flipVertical'] as const;

export function setCrop(state: EditingState, settings: unknown): EditingState {
  const input = checkKeys('crop', settings, CROP_KEYS);
  const crop: CropSettings = { ...state.crop };
  const unit = { min: 0, max: 1 };
  if (input.x !== undefined) crop.x = checkNumber('crop.x', input.x, unit);
  if (input.y !== undefined) crop.y = checkNumber('crop.y', input.y, unit);
  if (input.width !== undefined) crop.width = checkNumber('crop.width', input.width, { min: MIN_CROP_SIZE, max: 1 });
  if (input.height !== undefined) crop.height = checkNumber('crop.height', input.height, { min: MIN_CROP_SIZE, max: 1 });
  if (input.angle !== undefined) crop.angle = checkNumber('crop.angle', input.angle, CROP_ANGLE_SPEC);
  if (input.rotation !== undefined) {
    if (input.rotation !== 0 && input.rotation !== 90 && input.rotation !== 180 && input.rotation !== 270) {
      throw new StateError(`crop.rotation must be 0, 90, 180 or 270, got ${describe(input.rotation)}`);
    }
    crop.rotation = input.rotation;
  }
  for (const key of ['flipHorizontal', 'flipVertical'] as const) {
    const value = input[key];
    if (value !== undefined) {
      if (typeof value !== 'boolean') throw new StateError(`crop.${key} must be true or false, got ${describe(value)}`);
      crop[key] = value;
    }
  }
  const epsilon = 1e-6;
  if (crop.x + crop.width > 1 + epsilon || crop.y + crop.height > 1 + epsilon) {
    throw new StateError(
      `crop rectangle leaves the frame: x + width and y + height must be at most 1 (got x ${crop.x}, width ${crop.width}, y ${crop.y}, height ${crop.height})`,
    );
  }
  return { ...state, crop };
}

export const RESET_SECTIONS = ['all', 'light', 'color', 'curves', 'hsl', 'grading', 'detail', 'crop'] as const;
export type ResetSection = (typeof RESET_SECTIONS)[number];

const LIGHT_KEYS: (keyof GlobalAdjustments)[] = ['exposureEV', 'contrast', 'highlights', 'shadows', 'whites', 'blacks'];
const COLOR_KEYS: (keyof GlobalAdjustments)[] = ['temperature', 'tint', 'vibrance', 'saturation'];
const EFFECT_KEYS: (keyof GlobalAdjustments)[] = ['texture', 'clarity', 'dehaze', 'vignette'];

/** Puts one section (or everything) back to how the photo was opened. */
export function resetSection(state: EditingState, section: unknown, base?: Partial<PhotoDefaults>): EditingState {
  const name = oneOf('reset section', section, RESET_SECTIONS);
  const fresh = defaultState(base);
  const pick = (keys: (keyof GlobalAdjustments)[]): GlobalAdjustments => {
    const global = { ...state.global };
    for (const key of keys) global[key] = fresh.global[key];
    return global;
  };
  switch (name) {
    case 'all':
      return fresh;
    case 'light':
      return { ...state, global: pick(LIGHT_KEYS) };
    case 'color':
      return { ...state, global: pick(COLOR_KEYS) };
    case 'curves':
      return { ...state, curves: fresh.curves };
    case 'hsl':
      return { ...state, hsl: fresh.hsl };
    case 'grading':
      return { ...state, grading: fresh.grading };
    case 'detail':
      return { ...state, detail: fresh.detail, global: pick(EFFECT_KEYS) };
    case 'crop':
      return { ...state, crop: fresh.crop };
  }
}

/** Rebuilds a state from untrusted data (a saved document), checking every value. */
export function parseState(value: unknown): EditingState {
  if (!isPlainObject(value)) throw new StateError('editing state must be an object');
  let state = defaultState();
  if (value.global !== undefined) state = adjustGlobal(state, value.global);
  if (value.curves !== undefined) {
    const curves = checkKeys('curves', value.curves, CURVE_CHANNELS);
    for (const channel of CURVE_CHANNELS) {
      if (curves[channel] !== undefined) state = setCurve(state, channel, curves[channel]);
    }
  }
  if (value.hsl !== undefined) {
    const hsl = checkKeys('hsl', value.hsl, COLOR_RANGES);
    for (const color of COLOR_RANGES) {
      if (hsl[color] !== undefined) state = adjustHSL(state, color, hsl[color]);
    }
  }
  if (value.grading !== undefined) {
    const grading = checkKeys('grading', value.grading, [...GRADING_RANGES, 'blending', 'balance'] as const);
    for (const range of GRADING_RANGES) {
      if (grading[range] !== undefined) state = setGrading(state, range, grading[range]);
    }
    const mix: Record<string, unknown> = {};
    if (grading.blending !== undefined) mix.blending = grading.blending;
    if (grading.balance !== undefined) mix.balance = grading.balance;
    state = setGradingMix(state, mix);
  }
  if (value.detail !== undefined) state = setDetail(state, value.detail);
  if (value.crop !== undefined) state = setCrop(state, value.crop);
  return state;
}

export interface StateChange {
  path: string;
  from: unknown;
  to: unknown;
}

/** Lists what differs between two states, one entry per setting (a whole curve counts as one). */
export function diffStates(before: EditingState, after: EditingState): StateChange[] {
  const changes: StateChange[] = [];
  const compare = (path: string, a: unknown, b: unknown) => {
    if (isPlainObject(a) && isPlainObject(b)) {
      for (const key of Object.keys(b)) compare(path ? `${path}.${key}` : key, a[key], b[key]);
    } else if (JSON.stringify(a) !== JSON.stringify(b)) {
      changes.push({ path, from: a, to: b });
    }
  };
  compare('', before, after);
  return changes;
}

export function statesEqual(a: EditingState, b: EditingState): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

export function isIdentityCurve(points: CurvePoint[]): boolean {
  return points.every(([x, y]) => Math.abs(x - y) < 1e-6);
}

/**
 * How much of the frame survives straightening by `angle` degrees: the largest rectangle with the
 * frame's own proportions that fits inside the turned frame, as a fraction of its width and height.
 */
export function straightenScale(angle: number, aspect: number): number {
  const radians = (Math.abs(angle) * Math.PI) / 180;
  const long = Math.max(aspect, 1 / aspect);
  return 1 / (Math.cos(radians) + long * Math.sin(radians));
}
