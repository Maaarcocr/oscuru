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
   *   "mask"     the photo as it is now with the area of the local adjustment named in
   *              `options.mask` painted red, and how much of the frame it covers
   *   "depth"    how far each part of the frame is, as greys from black (nearest) to white
   *              (farthest): the scale of a mask's `depth` range, to choose its from and to
   *   "frame"    one frame of the shot alone, as it was taken (`options.frame`, counted from 1),
   *              with the settings as they are: only for a photo whose frames were kept
   *              (see `photo.current.frames`)
   * `region` zooms in on part of the frame, given as fractions from its top-left corner, to
   * judge detail, noise, skin or edges. `maxEdge` is the long edge in pixels (default 1024,
   * up to 2048).
   *
   * You do not need this for the usual case: whenever a script changes the photo, the reply
   * already includes it before your edits and as it is now.
   */
  show(which?: "current" | "before" | "original" | "mask" | "depth" | "frame", options?: { region?: Region; maxEdge?: number; mask?: string; frame?: number }): void;

  /**
   * The person's saved styles: looks they can put on any photo. Some were learned from pictures
   * in the app; applying one of those adapts it to this photo and changes only tone and colour.
   */
  readonly styles: {
    /** Names of the saved styles. */
    list(): string[];
    /**
     * What a saved style is made of, without putting it on the photo: to tell the person what it
     * does, to judge whether it suits this photo, or to make a variation (change the settings
     * on the photo, then `save` under a new name).
     */
    get(name: string): SavedStyle;
    /** Applies a saved style to this photo: its look replaces the current tone and colour settings. Crop and detail stay. */
    apply(name: string): void;
    /** Saves the photo's current look as a style. Saving under an existing name replaces it. */
    save(name: string): void;
    delete(name: string): void;
  };

  /**
   * Makes new photos from parts of this one, for a carousel, a panorama in pieces, or several
   * prints in one scan: each part becomes its own photo in the library, with this photo's settings
   * as they are at that point in the script, cropped to the part (local adjustments move with it).
   * This photo does not change. Give `{ columns, rows }` for equal parts read across then down
   * (2 to 20 parts), or the regions themselves, as fractions of the frame as shown.
   * The photos are made when the script ends without an error, and the reply lists them.
   */
  split(parts: { columns?: number; rows?: number } | Region[]): void;
}

interface PhotoDocument {
  /** A copy of the settings as they are now, including changes made earlier in this script. */
  getState(): EditingState;
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

  /** Film grain, laid over the finished frame. Values left out keep their current value. */
  readonly grain: {
    set(settings: Partial<GrainSettings>): void;
    get(): GrainSettings;
  };

  /** The warm glow film shows around bright highlights. Values left out keep their current value. */
  readonly halation: {
    set(settings: Partial<HalationSettings>): void;
    get(): HalationSettings;
  };

  /**
   * Local adjustments: changes to part of the photo. Each has a name you choose, a mask that says
   * where it applies, and what it changes there, relative to the rest of the photo. They apply in
   * order, after the global tone and colour, to the frame as cropped. Check a mask with
   * `photo.show("mask", { mask: name })` before relying on it.
   */
  readonly local: {
    /**
     * Creates the local adjustment `name`, or changes it if it exists. A new one needs a mask.
     * A mask given replaces the old one; adjust values left out keep their value (0 for a new
     * one). At most 8 per photo.
     */
    set(name: string, settings: { mask?: Mask; adjust?: Partial<LocalSettings> }): void;
    get(name: string): LocalAdjustment;
    list(): LocalAdjustment[];
    remove(name: string): void;
    /** Removes them all. */
    reset(): void;
  };

  /** Crops, straightens, turns or flips. Values left out keep their current value. */
  crop(settings: Partial<CropSettings>): void;

  /**
   * A collage's arrangement: which of its pieces (getMetadata().pieces) sits where. Only a collage
   * has one; the person makes a collage by selecting photos in the library and tapping Combine.
   * Every other setting applies to the whole collage, e.g. one grade so its pieces belong together.
   */
  readonly layout: {
    get(): CollageLayout;
    /** Values given replace theirs; `cells`, when given, replaces all the cells. */
    set(settings: Partial<CollageLayout>): void;
  };

  /**
   * The frames of the shot. With Frames on, Oscuru's camera takes several RAW frames of one
   * scene, one after another, and keeps each beside the photo. How they become the picture is
   * a setting like any other, and yours to decide: which frame it is built on, which frames
   * go into it, and what becomes of whatever moved between them. Nothing is invented: every
   * photosite of the picture comes from the frames. A photo without kept frames has none of
   * this (`list()` is empty, `merge` throws).
   *
   * The frames are merged as RAW, before any development, so every other setting applies to
   * the merged picture as to any RAW. Merging takes a few seconds; a merge already made is kept.
   */
  readonly frames: {
    /** Each frame, in the order taken. Empty when the photo has no kept frames. */
    list(): FrameInfo[];
    /** How the frames are merged now. */
    get(): FrameMerge;
    /**
     * Merges the frames another way, and says what lining them up found. Settings left out
     * keep their value; `areas`, when given, replaces all the areas. Look at the result (the
     * reply's pictures, or `photo.show` with a region) before telling the person it worked.
     */
    merge(settings: Partial<FrameMerge>): FrameMergeReport;
    /** Back to the way the camera merged them. */
    reset(): void;
  };

  /** Puts a section back to how the photo was opened. Default "all". */
  reset(section?: ResetSection): void;

  /** Discards the changes this script has made so far. */
  revert(): void;
}

type CurveChannel = "rgb" | "red" | "green" | "blue";
type ColorRange = "red" | "orange" | "yellow" | "green" | "aqua" | "blue" | "purple" | "magenta";
type GradingRange = "shadows" | "midtones" | "highlights";
type ResetSection = "all" | "light" | "color" | "curves" | "hsl" | "grading" | "detail" | "effects" | "local" | "crop" | "layout" | "frames";
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
  /** Sharpening amount. Range 0 to 100. Starts at 0: nothing is added until you add it. */
  sharpening: number;
  /** Luminance noise reduction. Range 0 to 100. Starts at 0: nothing is added until you add it. */
  noiseReduction: number;
  /** Colour noise reduction (RAW files only). Range 0 to 100. Starts at 0: nothing is added until you add it. */
  colorNoiseReduction: number;
}

interface GrainSettings {
  /** Strength of film grain. 0 is off; 10 to 30 is subtle, 40 and above is strong. Range 0 to 100. Default 0. */
  amount: number;
  /** Grain size relative to the frame: 0 is very fine, like slow film; 100 is coarse, like pushed fast film. Range 0 to 100. Default 25. */
  size: number;
  /** How uneven the grain is: 0 is even and smooth, 100 is clumpy. Range 0 to 100. Default 50. */
  roughness: number;
}

interface HalationSettings {
  /** Strength of halation, the warm red glow film shows around bright highlights. 0 is off; 10 to 40 is typical. Range 0 to 100. Default 0. */
  amount: number;
  /** How far the glow spreads, relative to the frame. Range 0 to 100. Default 30. */
  radius: number;
  /** How bright an area must be to glow: higher keeps it to the brightest highlights. Range 0 to 100. Default 70. */
  threshold: number;
}

/** Relative to the rest of the photo; 0 is no change. */
interface LocalSettings {
  /** Brightness of the area, in stops. Range -4 to 4 stops. Default 0. */
  exposureEV: number;
  /** Contrast inside the area. Range -100 to 100. Default 0. */
  contrast: number;
  /** Negative darkens the area's bright tones, positive brightens them. Range -100 to 100. Default 0. */
  highlights: number;
  /** Positive opens the area's dark tones, negative deepens them. Range -100 to 100. Default 0. */
  shadows: number;
  /** Positive is warmer than the rest of the photo, negative cooler. Range -100 to 100. Default 0. */
  temperature: number;
  /** Positive is more magenta than the rest of the photo, negative greener. Range -100 to 100. Default 0. */
  tint: number;
  /** Saturation inside the area. -100 removes its colour. Range -100 to 100. Default 0. */
  saturation: number;
  /** Mid-size local contrast inside the area. Negative softens. Range -100 to 100. Default 0. */
  clarity: number;
  /** Positive removes a veil inside the area, negative adds one. Range -100 to 100. Default 0. */
  dehaze: number;
}

interface LocalAdjustment {
  name: string;
  mask: Mask;
  adjust: LocalSettings;
}

/**
 * Where a local adjustment applies. Positions are fractions of the frame as you see it (after the
 * crop), from its top-left corner: x to the right, y down. Crop first, then place masks: a later
 * crop does not move them with the picture.
 *
 * Choose areas in this order, cheapest first: (1) tap the thing with an ObjectArea (or use
 * SubjectArea or PeopleArea), which the phone segments precisely on its own; (2) shapes and tone,
 * colour or depth ranges, combined with `subtract` and `intersect` to remove what spills; (3) only
 * for what those cannot do, or to fix their edges, draw by hand with OutlineArea or BrushArea.
 *
 * The mask is built in this order: the areas joined (where they overlap it is as strong as the
 * strongest, never stronger), `intersect` (kept only inside each of those too), `subtract` (cut out),
 * `invert`, the `luminance`, `color` and `depth` ranges, `grow`, `refine`.
 */
interface Mask {
  /** One area, or several joined together. */
  area: MaskArea | MaskArea[];
  /** Areas cut out of the mask, e.g. a tree in front of the building you selected. */
  subtract?: MaskArea | MaskArea[];
  /** Areas the mask must also be in: keeps only the overlap. */
  intersect?: MaskArea | MaskArea[];
  /** Use everything outside the mask instead. Default false. */
  invert?: boolean;
  /**
   * Keep only these tones: display luminance from 0 (black) to 1 (white), with soft edges `feather`
   * wide (0 to 0.5, default 0.1).
   */
  luminance?: { from: number; to: number; feather?: number };
  /**
   * Keep only colours near this hue (0 red, 30 orange, 60 yellow, 120 green, 180 cyan, 240 blue,
   * 300 magenta), fading out beyond ±range/2 degrees (range 10 to 180, default 60). Greys are left out.
   */
  color?: { hue: number; range?: number };
  /**
   * Keep only what lies this far away: from 0 (the nearest part of the photo) to 1 (the farthest,
   * usually the sky), with soft edges `feather` wide (0 to 0.5, default 0.1). The phone estimates
   * depth from the photo alone, so the scale is relative and its edges are soft: look at
   * `photo.show("depth")` to choose from and to, and add `refine` for a crisp edge. For whatever
   * follows distance: haze, mist and atmosphere, a far background, a near foreground. For a change
   * that grows steadily from nothing at the nearest point to full at the farthest, as haze does:
   * { from: 0.5, to: 1, feather: 0.5 }. Water and glass that mirror the sky can read as far: cut
   * them out with `subtract`.
   */
  depth?: { from: number; to: number; feather?: number };
  /**
   * What `luminance` and `color` are measured on: "current" (default), the photo as it is before this
   * adjustment; or "original", the photo as developed before tone and colour. Use "original" when a
   * style or grade has made different things look alike.
   */
  measure?: "current" | "original";
  /** Grows (above 0) or shrinks (below 0) the mask's edge by this fraction of the frame's long edge, -0.05 to 0.05. Default 0. */
  grow?: number;
  /**
   * Snaps the mask's edge to the edges in the photo, 0 (off, default) to 1 (strongly). 0.3 to 0.6
   * turns a rough or soft mask into one that follows outlines such as roofs, branches or hair.
   */
  refine?: number;
}

type MaskArea = ObjectArea | SubjectArea | PeopleArea | RadialArea | LinearArea | FrameArea | OutlineArea | BrushArea;

/**
 * The object at these points, segmented by an on-device model: tap one or a few points on the thing
 * you mean ([x, y], 0 to 1), and points on what must not be part of it in `exclude` (16 points in all).
 * One point in the middle of a distinct object is usually enough; add a point on a part it missed,
 * or an exclude point on what it took that it should not. Check the result with photo.show("mask").
 */
interface ObjectArea { type: "object"; points: [number, number][]; exclude?: [number, number][]; }
/** The main subject or subjects, found by the phone's on-device image analysis. Empty when it finds none. */
interface SubjectArea { type: "subject"; }
/** Every person in the photo, found by the phone's on-device image analysis. Empty when there are none. */
interface PeopleArea { type: "people"; }
/**
 * An ellipse. x, y: its centre (-0.5 to 1.5). width, height: its full size as fractions of the
 * frame's width and height (0.02 to 3). angle: degrees clockwise (-180 to 180, default 0).
 * feather: how soft the edge is, from 0 (hard) to 1 (fading from the centre); default 0.5.
 */
interface RadialArea { type: "radial"; x: number; y: number; width: number; height: number; angle?: number; feather?: number; }
/** A straight gradient: full strength at `from`, fading to nothing at `to`; [x, y] points (-0.5 to 1.5). A sky: from [0.5, 0] to [0.5, 0.45]. */
interface LinearArea { type: "linear"; from: [number, number]; to: [number, number]; }
/** The whole frame: use it with `luminance`, `color` or `depth` to pick tones, colours or distances anywhere. */
interface FrameArea { type: "frame"; }
/**
 * A shape drawn by hand: its corners in order ([x, y], -0.5 to 1.5; 3 to 400 of them), filled.
 * feather: how soft its edge is, as a fraction of the frame's long edge (0 to 0.1, default 0.003).
 */
interface OutlineArea { type: "outline"; points: [number, number][]; feather?: number; }
/**
 * Brush strokes painted by hand: each stroke is the [x, y] points the brush passes through (one point
 * paints a dot; 1 to 40 strokes). size: the brush's diameter as a fraction of the frame's long edge
 * (0.002 to 0.5, default 0.03). feather: its soft edge, same units (0 to 0.1, default size / 4). Paint
 * fixes with it: join a stroke to add what a mask missed, or subtract one to remove what it took.
 */
interface BrushArea { type: "brush"; strokes: [number, number][][]; size?: number; feather?: number; }

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
  grain: GrainSettings;
  halation: HalationSettings;
  local: LocalAdjustment[];
  crop: CropSettings;
  /** Only on a collage. */
  layout?: CollageLayout;
  /** Only on a photo whose frames were kept. */
  frames?: FrameMerge;
}

/**
 * A saved style, as it was made:
 *   "edit"    saved from a photo edited in Oscuru. `look` is the whole look: the global
 *             settings (exposure and contrast included; white balance as a shift from each
 *             photo's own as-shot value), curves, hsl, grading, grain and halation. Applying
 *             it sets exactly these.
 *   "pair"    learned in the app from an original and the person's edit of it. `fit` is three
 *             channel curves and a saturation; `error` is how far the original with them was
 *             from the edit, in 8-bit levels (under 3 is very close). Applying it sets these
 *             and keeps the photo's own exposure and white balance.
 *   "picture" learned from one picture of any scene. `fingerprint` is where that picture's
 *             red, green and blue fall at each of the `quantiles` (0 to 1, encoded), and how
 *             colourful it is. Applying it fits fresh curves to make each photo's spread of
 *             tones and colours match these, so what it does depends on the photo.
 */
interface SavedStyle {
  name: string;
  kind: "edit" | "pair" | "picture";
  look?: {
    global: Partial<GlobalAdjustments>;
    temperatureShift: number;
    tintShift: number;
    curves: Record<CurveChannel, CurvePoint[]>;
    hsl: Record<ColorRange, HSLAdjustments>;
    grading: Record<GradingRange, ColorGrading> & GradingMix;
    grain: GrainSettings;
    halation: HalationSettings;
  };
  fit?: { curves: { red: CurvePoint[]; green: CurvePoint[]; blue: CurvePoint[] }; saturation: number; error?: number };
  fingerprint?: { quantiles: number[]; red: number[]; green: number[]; blue: number[]; colourfulness: number };
}

/**
 * One way of merging a shot's frames: which frames, how they are lined up (`align`), how each
 * place is made from them (`combine`), and onto what grid (`scale`). Together these make
 * every kind of merge: less noise ("robust"), a long exposure ("mean"), passers-by removed
 * ("median"), light trails ("brightest"), each place from the frame where it is sharpest
 * ("sharpest"), a panning shot ("camera" on the subject with "mean"), more detail than the
 * sensor holds (scale 2).
 */
interface FrameWay {
  /**
   * The frame the picture is built on, counted from 1: its framing, its brightness and, with
   * "robust", its moment. To choose a moment (the frame where someone looks at the camera, or
   * before something walked in), look at the frames with `photo.show("frame")` and make that
   * one the base.
   */
  base: number;
  /** The frames that go into the picture, e.g. [1, 2, 4], or "all". The base must be among them. Leave out a frame that is blurred or spoiled. */
  use: number[] | "all";
  /**
   * How each place of the picture is made from the frames lined up there:
   *   "robust"    the base, with noise averaged away where the other frames agree with it;
   *               where something moved, the base alone. Its moment, frozen. The camera's own.
   *   "mean"      everything averaged: what moved blurs along its way, as in one long exposure
   *               (silky water, streaked clouds, a crowd dissolved into a haze).
   *   "median"    what most frames agree on: people or cars that passed through are gone. Each
   *               place must be empty in more than half of the frames used.
   *   "brightest" what stayed put, with every bright thing that moved drawn along its way (car
   *               lights, fireworks, stars).
   *   "sharpest"  each place from the frames where it is sharpest: frames focused at different
   *               distances make one picture sharp throughout, and of frames a shaking hand
   *               blurred unevenly, each part comes from the steadiest.
   * "mean", "median" and "brightest" only do much when something moved between the frames:
   * frames taken some time apart (see `after` in `list()`); back to back, little moves.
   * Setting it also sets `align` to what suits it, unless `align` is given too.
   */
  combine: "robust" | "mean" | "median" | "brightest" | "sharpest";
  /**
   * How the frames are lined up with the base:
   *   "tiles"  each small part on its own, so everything that can be matched is: the hand's
   *            movement, and what moved a little in the scene. With "robust" and "sharpest".
   *   "camera" each frame as a whole, by how the camera moved: what moved in the scene keeps
   *            its own movement (to blur, remove or draw). With "mean", "median" and "brightest".
   *   "none"   as taken: a camera on a tripod, or to keep the camera's own movement.
   */
  align: "tiles" | "camera" | "none";
  /**
   * With align "camera", follow one part of the frame instead of the whole: it stays where it
   * is in the base, and everything else moves around it. With "mean", a panning shot (the car
   * or runner sharp, the background streaked along its way); with the stars, the sky held
   * still and the ground blurred. Fractions of the frame as `photo.show("frame")` shows it
   * (before any crop or turn), from its top-left. Null follows the whole frame.
   */
  alignOn: { x: number; y: number; width: number; height: number } | null;
  /**
   * 1: the sensor's own size. 2: twice as wide and high, with real detail no single frame has.
   * A hand never holds still, so each frame samples the scene at slightly different places;
   * every pixel of the finer grid is made from the samples of every frame that fell near it,
   * all three colours measured. It needs four or more frames taken back to back in a hand
   * (frames from a tripod sample the same places), takes tens of seconds to merge, and gives
   * a four-times larger photo. Fine textures (leaves, gravel, roof tiles, fabric, text) gain
   * the most. Use it when the person wants detail or a large print, not by default.
   */
  scale: 1 | 2;
  /**
   * For "robust", "median" and "brightest": how readily a difference counts as something
   * that moved, 0 to 1 (default 0.5). Lower averages more: less noise, at the risk of faint
   * ghosts. Higher keeps more apart: no ghosts, more noise around what moved.
   */
  caution: number;
}

/** How a shot's frames are merged: the picture as a whole, and parts of it merged another way. */
interface FrameMerge extends FrameWay {
  /**
   * Parts of the picture merged their own way, each through a mask (as for a local adjustment),
   * later ones over earlier ones: the water blurred while the people stay frozen, or one face
   * from another frame (`base` and `use` of that frame alone). An area starts from the
   * picture's own way and changes what it names; it is brought to the picture's size (its
   * own `scale` is the picture's). At most 3.
   */
  areas: Array<Partial<FrameWay> & { mask: Mask }>;
}

/** One frame of a shot. */
interface FrameInfo {
  /** Its number, counted from 1 in the order taken. */
  frame: number;
  /** The exposure it was taken at: time in seconds, and ISO. */
  time: number;
  iso: number;
  /**
   * The light it took, in stops against the first frame. All 0 for a plain shot. In a bracket
   * some are darker (they hold the highlights the others blew) and some brighter (they hold
   * cleaner shadows): merged, each counts for as much as the light it took, and the picture has
   * the base frame's brightness.
   */
  stops: number;
  /** When it was taken, in seconds after the first. */
  after: number;
  /** How much fine detail it holds, 0 to 1, against the sharpest frame: low means blurred by movement. */
  sharpness: number;
  /** The share of it that is blown, 0 to 1. */
  blown: number;
  /** How far the camera had moved from the base of the camera's own merge, in pixels. */
  shift: number;
  /** The share of it that differs from that base by more than noise, 0 to 1: what moved, or blur. */
  differs: number;
  /** Whether it goes into the picture as merged now, and whether it is its base. */
  used: boolean;
  base: boolean;
}

/** What merging found. */
interface FrameMergeReport {
  /** How many frames went into the picture. */
  merged: number;
  /** For each frame used other than the base: how far the camera had moved from the base, in pixels, and the share of it that differs from the base by more than noise. */
  frames: Array<{ frame: number; shift: number; differs: number }>;
  /**
   * How many stops above white the merged picture holds, when the frames used include ones
   * darker than the base (a bracket): highlights the base blew are there to bring back, with
   * a lower exposure or highlights, or a local adjustment over them.
   */
  highlightStops: number;
}

/**
 * How a collage's pieces sit on its canvas. Cells are drawn in order, so a later one covers an
 * earlier one where they overlap (a small picture set into a large one); a piece can appear in
 * more than one cell, or in none.
 */
interface CollageLayout {
  /** The canvas's width over its height, 0.25 to 4: 1 square, 0.8 for 4:5, 1.5 for 3:2. */
  aspect: number;
  /** Space between the pieces and around them, as a fraction of the long edge, 0 to 0.1. 0.01 is a fine line. */
  gap: number;
  /** The colour in the gaps, "#RRGGBB". */
  background: string;
  /** 1 to 24 cells. */
  cells: CollageCell[];
}

/** One piece, cropped to fill a rectangle of the canvas. */
interface CollageCell {
  /** Which piece: its index in getMetadata().pieces. */
  piece: number;
  /** The rectangle, as fractions of the canvas from its top-left corner, before the gap is taken out. */
  x: number;
  y: number;
  width: number;
  height: number;
  /** The point of the piece ([x, y], 0 to 1 from its top-left) kept in view when it is cropped to fill. Default [0.5, 0.5]. */
  focus?: [number, number];
  /** 1 (default) fills the cell; up to 5 crops in further. */
  zoom?: number;
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
  /**
   * Only when the photo was taken zoomed between two lenses: the crop that framing gave, which its
   * settings start with. The whole frame is still in the file: widen the crop to zoom out.
   */
  framedInCamera?: { x: number; y: number; width: number; height: number };
  /**
   * Only when the camera averaged several RAW frames into this file: how many. Its noise is lower
   * than its ISO suggests, by the square root of this (16 frames: a quarter), so it needs less
   * noise reduction than a single frame at that ISO, often none.
   */
  frames?: number;
  /** Whether those frames were kept beside the photo, so that they can be merged another way (`photo.current.frames`). */
  framesKept?: boolean;
  /** Only on a collage: the photos it is made of, in order, at the size they were added. */
  pieces?: { piece: number; name: string; width: number; height: number }[];
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
 * data (inside the RAW decoder for RAW files). RAW files then get Oscuru's base curve: the light
 * as measured up to 0.75 of white, then a smooth roll-off so highlights compress instead of
 * clipping. No other tone curve, contrast or local tone mapping is applied for you, so an
 * unedited RAW looks flat and true to the scene. Then: local highlight/shadow recovery, clarity and
 * texture, the tone stage (dehaze, blacks/whites, contrast, curves), the colour stage (HSL,
 * vibrance, saturation, grading), halation, geometry, local adjustments, vignette, grain.
 */
