/**
 * The scripting API as TypeScript declarations: the contract the remote agent writes scripts
 * against, and the text it is given as documentation. Ranges and defaults are filled in from the
 * same tables the editor validates with, so the two cannot drift.
 *
 * `docs/photo-api.d.ts` is this text written to a file (`npm run sync-api-docs`); a test keeps it current.
 */

import {
  COLOR_RANGES,
  CROP_ANGLE_SPEC,
  CURVE_CHANNELS,
  DETAIL_SPECS,
  GLOBAL_SPECS,
  GRADING_MIX_SPECS,
  GRADING_RANGES,
  GRADING_SPECS,
  HSL_SPECS,
  MAX_CURVE_POINTS,
  MIN_CROP_SIZE,
  RESET_SECTIONS,
  type ParamSpec,
} from '@/engine/state';
import { DEFAULT_LIMITS } from './interpreter';

const union = (values: readonly string[]): string => values.map((value) => `"${value}"`).join(' | ');

function fields(specs: Record<string, ParamSpec>, startNote?: (key: string) => string | undefined): string {
  return Object.entries(specs)
    .map(([key, spec]) => {
      const unit = spec.unit ? ` ${spec.unit}` : '';
      const start = startNote?.(key) ?? `Default ${spec.default}.`;
      return `  /** ${spec.description} Range ${spec.min} to ${spec.max}${unit}. ${start} */\n  ${key}: number;`;
    })
    .join('\n');
}

export const PHOTO_API_DECLARATIONS = `/**
 * Oscuru edit-script API.
 *
 * A script is ordinary JavaScript run on the phone in a sandbox. The only things it can reach are
 * the global \`photo\`, \`console\`, and the standard Math, JSON, Number, String, Boolean, Array,
 * Object, Map, Set and Error helpers. There is no network, file system, timers, async/await,
 * classes, regular expressions or modules.
 *
 * A script edits a private draft of the photo's settings. Nothing changes for the person until the
 * script calls \`photo.current.commit()\` and then ends without an error; if it throws, everything it
 * did is discarded. One script is one undo step.
 *
 * Scripts never touch pixels. They set development parameters; the phone's RAW engine renders them.
 */
declare const photo: PhotoEditor;

interface PhotoEditor {
  /** The photo open in the editor. */
  readonly current: PhotoDocument;
}

interface PhotoDocument {
  /** A copy of the draft settings, including changes made earlier in this script. */
  getState(): EditingState & { revision: number };
  /** Facts about the file and how it was shot. */
  getMetadata(): ImageMetadata;
  /**
   * Histogram of the photo as rendered at the revision this script started from.
   * It does NOT reflect changes made in this script: the tool result brings fresh numbers and a preview.
   */
  getHistogram(): Histogram;
  /** Statistics of the photo as rendered at the revision this script started from (see getHistogram). */
  getStatistics(): ImageStatistics;

  /**
   * Sets global adjustments to absolute values. Settings left out keep their current value, so to
   * nudge a setting read it first: \`adjust({ exposureEV: getState().global.exposureEV + 0.3 })\`.
   */
  adjust(settings: Partial<GlobalAdjustments>): void;

  readonly curves: {
    /**
     * Replaces one tone curve. Points are [input, output] pairs from 0 (black) to 1 (white) on
     * display-referred (gamma-encoded) values; 2 to ${MAX_CURVE_POINTS} points with distinct inputs, in any order.
     * The curve is a smooth spline through the points that never overshoots; it is flat before the
     * first point and after the last. "rgb" is the master curve; the channel curves apply after it.
     */
    set(channel: CurveChannel, points: CurvePoint[]): void;
    get(channel: CurveChannel): CurvePoint[];
    /** Back to a straight line: one channel, or all four when called without an argument. */
    reset(channel?: CurveChannel): void;
  };

  readonly hsl: {
    /** Adjusts one colour range. Values left out keep their current value. */
    adjust(color: ColorRange, adjustments: Partial<HSLAdjustments>): void;
    get(color: ColorRange): HSLAdjustments;
    /** Back to zero: one colour, or all of them when called without an argument. */
    reset(color?: ColorRange): void;
  };

  readonly grading: {
    /** Tints one tonal range. Values left out keep their current value. */
    set(range: GradingRange, settings: Partial<ColorGrading>): void;
    get(range: GradingRange): ColorGrading;
    /** How the three ranges share the tonal scale. */
    configure(settings: Partial<GradingMix>): void;
    reset(): void;
  };

  readonly detail: {
    set(settings: Partial<DetailSettings>): void;
    get(): DetailSettings;
  };

  /** Crops, straightens, turns or flips. Values left out keep their current value. */
  crop(settings: Partial<CropSettings>): void;

  /** Puts a section back to how the photo was opened. Default "all". */
  reset(section?: ResetSection): void;

  /**
   * Marks the draft as the result of this script. May be called more than once; the last call wins.
   * Without it the script changes nothing (useful for scripts that only inspect).
   */
  commit(): void;
}

type CurveChannel = ${union(CURVE_CHANNELS)};
type ColorRange = ${union(COLOR_RANGES)};
type GradingRange = ${union(GRADING_RANGES)};
type ResetSection = ${union(RESET_SECTIONS)};
/** [input, output], both 0 to 1. */
type CurvePoint = [number, number];

interface GlobalAdjustments {
${fields(GLOBAL_SPECS, (key) => (key === 'temperature' || key === 'tint' ? 'Starts at the as-shot value (getMetadata().asShot).' : undefined))}
}

interface HSLAdjustments {
${fields(HSL_SPECS)}
}

interface ColorGrading {
${fields(GRADING_SPECS)}
}

interface GradingMix {
${fields(GRADING_MIX_SPECS)}
}

interface DetailSettings {
${fields(DETAIL_SPECS, () => 'Starts at 0 for JPEG/HEIC and at the decoder default for RAW.')}
}

/**
 * Order of operations: flips, then rotation, then straightening (which trims the frame so no empty
 * corners show), then the crop rectangle, given as fractions of that trimmed frame from its top-left corner.
 */
interface CropSettings {
  /** Left edge of the crop, 0 to 1. Default 0. */
  x: number;
  /** Top edge of the crop, 0 to 1. Default 0. */
  y: number;
  /** Width of the crop, ${MIN_CROP_SIZE} to 1. x + width must not exceed 1. Default 1. */
  width: number;
  /** Height of the crop, ${MIN_CROP_SIZE} to 1. y + height must not exceed 1. Default 1. */
  height: number;
  /** ${CROP_ANGLE_SPEC.description} Range ${CROP_ANGLE_SPEC.min} to ${CROP_ANGLE_SPEC.max}°. Default 0. */
  angle: number;
  /** Quarter turns clockwise. */
  rotation: 0 | 90 | 180 | 270;
  flipHorizontal: boolean;
  flipVertical: boolean;
}

interface EditingState {
  global: GlobalAdjustments;
  curves: Record<CurveChannel, CurvePoint[]>;
  hsl: Record<ColorRange, HSLAdjustments>;
  grading: Record<GradingRange, ColorGrading> & GradingMix;
  detail: DetailSettings;
  crop: CropSettings;
}

interface ImageMetadata {
  fileName: string;
  /** Uniform type identifier, e.g. "com.adobe.raw-image" or "public.jpeg". */
  typeIdentifier: string;
  /** RAW files have real highlight and white-balance latitude; JPEG/HEIC have little. */
  isRaw: boolean;
  /** Full-resolution size in pixels, upright, before cropping. */
  width: number;
  height: number;
  /** White balance recorded by the camera (6500 K, tint 0 for non-RAW files). */
  asShot: { temperature: number; tint: number };
  make?: string;
  model?: string;
  lens?: string;
  iso?: number;
  /** Shutter time in seconds. */
  exposureTime?: number;
  aperture?: number;
  focalLength?: number;
  focalLength35mm?: number;
  dateTaken?: string;
}

/** Measured on the rendered preview: display-referred sRGB values. */
interface Histogram {
  bins: 256;
  /** Fraction of pixels per bin, from black (index 0) to white (index 255). Each array sums to 1. */
  luminance: number[];
  red: number[];
  green: number[];
  blue: number[];
  /** Fraction of pixels with at least one channel at the top of the range. */
  highlightClipping: number;
  /** Fraction of pixels with every channel at the bottom of the range. */
  shadowClipping: number;
}

/** Measured on the rendered preview. All values are 0 to 1 unless noted. */
interface ImageStatistics {
  /** Size of the bitmap that was measured (small). */
  width: number;
  height: number;
  meanLuminance: number;
  medianLuminance: number;
  /** Luminance below which that percentage of pixels fall. */
  percentiles: { p1: number; p5: number; p25: number; p50: number; p75: number; p95: number; p99: number };
  /** Standard deviation of luminance. */
  contrast: number;
  /** p99 − p1. */
  dynamicRange: number;
  averageSaturation: number;
  meanRGB: [number, number, number];
  /** Channel mean minus the mean of all three: positive red and negative blue is a warm cast. */
  colorCast: { red: number; green: number; blue: number };
  highlightClipping: number;
  shadowClipping: number;
  clippedChannels: { red: number; green: number; blue: number };
  /** Mean luminance of a 3×3 grid: zones[row][column], row 0 is the top. */
  zones: number[][];
  /** Share of pixels that are clearly of each colour, plus the near-neutral share. */
  colorDistribution: Record<ColorRange | "neutral", number>;
}

/**
 * Limits. A script that exceeds one is stopped and changes nothing:
 * source up to ${DEFAULT_LIMITS.maxSourceLength} characters, ${DEFAULT_LIMITS.maxSteps.toLocaleString('en-US')} evaluation steps, ${DEFAULT_LIMITS.timeoutMs / 1000} seconds,
 * call depth ${DEFAULT_LIMITS.maxCallDepth}, arrays and strings up to ${DEFAULT_LIMITS.maxCollectionSize.toLocaleString('en-US')} elements.
 *
 * Errors. Invalid settings throw a RangeError whose message names the setting and its valid range,
 * e.g. "adjust.exposureEV must be between -5 and 5, got 9". Unknown setting names throw too.
 *
 * Rendering order. Exposure, white balance, noise reduction and sharpening act on linear scene
 * data (inside the RAW decoder for RAW files). Then: local highlight/shadow recovery, clarity and
 * texture, the tone stage (dehaze, blacks/whites, contrast, curves), the colour stage (HSL,
 * vibrance, saturation, grading), geometry, vignette.
 */
`;
