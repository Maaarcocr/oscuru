// Generated from ios/Packages/OscuruKit/Sources/OscuruCore/PhotoAPI.swift by `UPDATE_API_DOCS=1 swift test`. Do not edit by hand.

/**
 * Oscuru edit-script API.
 *
 * A script is ordinary JavaScript that runs on the phone, in a JavaScript context kept for as
 * long as this photo is open: a REPL. Declarations made with `var`, function declarations and
 * anything you put on `globalThis` are still there in your next call; `let` and `const` last
 * for one call. The value of the script's last expression comes back to you.
 *
 * The only things a script can reach are the global `photo`, `console`, and standard
 * JavaScript (Math, JSON, arrays, objects, Map, Set, …). There is no network, file system,
 * timers or modules.
 *
 * Each call is a transaction on the photo's settings. Changes you make are in effect at once
 * inside the script (statistics and `photo.show` see them) and become the photo's settings, as
 * one undo step, when the script ends. If it throws, every change it made is discarded.
 *
 * Scripts never touch pixels. They set development parameters; the phone's RAW engine renders them.
 */
declare const photo: PhotoEditor;

interface PhotoEditor {
  /** The photo open in the editor. */
  readonly current: PhotoDocument;

  /**
   * Adds a picture to what you get back from this call, so you can look at it.
   *   "current"  the photo with the settings as they are at this point in the script (default)
   *   "before"   the photo as it was when the person gave this instruction
   *   "original" the photo as opened, with no edits (same crop)
   * `region` zooms in on part of the frame, given as fractions from its top-left corner, to
   * judge detail, noise, skin or edges. `maxEdge` is the long edge in pixels (default 1024,
   * up to 2048).
   *
   * You do not need this for the usual case: whenever a script changes the photo, the reply
   * already includes it before your edits and as it is now.
   */
  show(which?: "current" | "before" | "original", options?: { region?: Region; maxEdge?: number }): void;

  /** The person's saved filters: looks they can apply to any photo. */
  readonly filters: {
    /** Names of the saved filters. */
    list(): string[];
    /** Applies a saved filter to this photo: its look replaces the current tone and colour settings. Crop and detail stay. */
    apply(name: string): void;
    /** Saves the photo's current look as a filter. Saving under an existing name replaces it. */
    save(name: string): void;
    delete(name: string): void;
  };
}

interface PhotoDocument {
  /** A copy of the settings as they are now, including changes made earlier in this script. */
  getState(): EditingState & { revision: number };
  /** Facts about the file and how it was shot. */
  getMetadata(): ImageMetadata;
  /** Histogram of the photo rendered with the settings as they are now. */
  getHistogram(): Histogram;
  /** Statistics of the photo rendered with the settings as they are now. */
  getStatistics(): ImageStatistics;

  /**
   * Sets global adjustments to absolute values. Settings left out keep their current value, so to
   * nudge a setting read it first: `adjust({ exposureEV: getState().global.exposureEV + 0.3 })`.
   */
  adjust(settings: Partial<GlobalAdjustments>): void;

  readonly curves: {
    /**
     * Replaces one tone curve. Points are [input, output] pairs from 0 (black) to 1 (white) on
     * display-referred (gamma-encoded) values; 2 to 16 points with distinct inputs, in any order.
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

  /** Discards the changes this script has made so far. */
  revert(): void;

  /** Optional. Changes are kept automatically when the script ends without an error. */
  commit(): void;
}

type CurveChannel = "rgb" | "red" | "green" | "blue";
type ColorRange = "red" | "orange" | "yellow" | "green" | "aqua" | "blue" | "purple" | "magenta";
type GradingRange = "shadows" | "midtones" | "highlights";
type ResetSection = "all" | "light" | "color" | "curves" | "hsl" | "grading" | "detail" | "crop";
/** [input, output], both 0 to 1. */
type CurvePoint = [number, number];
/** Part of the frame, as fractions from its top-left corner. */
interface Region { x: number; y: number; width: number; height: number; }

interface GlobalAdjustments {
  /** Exposure compensation in photographic stops, applied to linear scene data (in the RAW decoder for RAW files). Range -5 to 5 stops. Default 0. */
  exposureEV: number;
  /** Global contrast around mid-grey. Positive is an S-curve, negative flattens. Range -100 to 100. Default 0. */
  contrast: number;
  /** Negative recovers bright areas (local, keeps their contrast); positive brightens them. Range -100 to 100. Default 0. */
  highlights: number;
  /** Positive opens dark areas (local, keeps their contrast); negative deepens them. Range -100 to 100. Default 0. */
  shadows: number;
  /** Moves the white point: positive brightens the top of the range and can clip, negative pulls it down. Range -100 to 100. Default 0. */
  whites: number;
  /** Moves the black point: negative deepens and can clip, positive lifts (a matte look). Range -100 to 100. Default 0. */
  blacks: number;
  /** White balance in Kelvin, as in Camera Raw: a higher value makes the photo warmer. Range 2000 to 25000 K. Starts at the as-shot value (getMetadata().asShot). */
  temperature: number;
  /** White balance tint: negative is greener, positive is more magenta. Range -150 to 150. Starts at the as-shot value (getMetadata().asShot). */
  tint: number;
  /** Fine local contrast (small details). Negative smooths. Range -100 to 100. Default 0. */
  texture: number;
  /** Mid-size local contrast. Negative gives a soft glow. Range -100 to 100. Default 0. */
  clarity: number;
  /** Approximate global dehaze: positive removes a veil (deeper blacks, more colour), negative adds one. Range -100 to 100. Default 0. */
  dehaze: number;
  /** Saturation that favours muted colours and protects skin tones. Range -100 to 100. Default 0. */
  vibrance: number;
  /** Uniform saturation. -100 is black and white, +100 doubles colourfulness. Range -100 to 100. Default 0. */
  saturation: number;
  /** Negative darkens the corners of the cropped frame, positive lightens them. Range -100 to 100. Default 0. */
  vignette: number;
}

interface HSLAdjustments {
  /** Shifts the hue of this colour range; ±100 is about ±30° around the colour wheel. Range -100 to 100. Default 0. */
  hue: number;
  /** Saturation of this colour range. -100 removes its colour. Range -100 to 100. Default 0. */
  saturation: number;
  /** Brightness of this colour range. Range -100 to 100. Default 0. */
  luminance: number;
}

interface ColorGrading {
  /** Hue of the tint (0 red, 60 yellow, 120 green, 180 cyan, 240 blue, 300 magenta). Range 0 to 360 °. Default 0. */
  hue: number;
  /** Strength of the tint. 0 is off; 0.05–0.2 is a typical grade. Range 0 to 1. Default 0. */
  saturation: number;
  /** Darkens or brightens this tonal range. Range -1 to 1. Default 0. */
  luminance: number;
}

interface GradingMix {
  /** How much the three tonal ranges overlap. 0 is separated, 1 is broad. Range 0 to 1. Default 0.5. */
  blending: number;
  /** Shifts the split between ranges: positive gives highlights more of the image, negative shadows. Range -1 to 1. Default 0. */
  balance: number;
}

interface DetailSettings {
  /** Sharpening amount. Range 0 to 100. Starts at 0 for JPEG/HEIC and at the decoder's own default for RAW. */
  sharpening: number;
  /** Luminance noise reduction. Range 0 to 100. Starts at 0 for JPEG/HEIC and at the decoder's own default for RAW. */
  noiseReduction: number;
  /** Colour noise reduction (RAW files only). Range 0 to 100. Starts at 0 for JPEG/HEIC and at the decoder's own default for RAW. */
  colorNoiseReduction: number;
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
  /** Width of the crop, 0.05 to 1. x + width must not exceed 1. Default 1. */
  width: number;
  /** Height of the crop, 0.05 to 1. y + height must not exceed 1. Default 1. */
  height: number;
  /** Straighten angle. Positive turns the photo clockwise. The frame is trimmed so no empty corners show. Range -45 to 45°. Default 0. */
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

/** Measured on a small rendering of the photo: display-referred sRGB values. */
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

/** Measured on a small rendering of the photo. All values are 0 to 1 unless noted. */
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
 * Errors. Invalid settings throw a RangeError whose message names the setting and its valid range,
 * e.g. "adjust.exposureEV must be between -5 and 5, got 9". Unknown setting names throw too.
 * An uncaught error discards everything the script changed.
 *
 * Rendering order. Exposure, white balance, noise reduction and sharpening act on linear scene
 * data (inside the RAW decoder for RAW files). Then: local highlight/shadow recovery, clarity and
 * texture, the tone stage (dehaze, blacks/whites, contrast, curves), the colour stage (HSL,
 * vibrance, saturation, grading), geometry, vignette.
 */
