import Foundation

/// The scripting API as TypeScript declarations: the contract the remote agent writes scripts
/// against, and the text it is given as documentation. Ranges and defaults are filled in from the
/// same tables the editor validates with. `docs/photo-api.d.ts` is this text written to a file;
/// a test keeps it current.
public enum PhotoAPI {
    static func union(_ values: [String]) -> String { values.map { "\"\($0)\"" }.joined(separator: " | ") }

    static func fields(_ specs: [ParamSpec], start: (ParamSpec) -> String? = { _ in nil }) -> String {
        specs.map { spec in
            let unit = spec.unit.isEmpty ? "" : " \(spec.unit)"
            let begins = start(spec) ?? "Default \(formatNumber(spec.defaultValue))."
            return "  /** \(spec.description) Range \(formatNumber(spec.min)) to \(formatNumber(spec.max))\(unit). \(begins) */\n  \(spec.name): number;"
        }.joined(separator: "\n")
    }

    public static let declarations: String = """
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
           * `region` zooms in on part of the frame, given as fractions from its top-left corner, to
           * judge detail, noise, skin or edges. `maxEdge` is the long edge in pixels (default \(Prompt.defaultImageEdge),
           * up to \(Prompt.maxImageEdge)).
           *
           * You do not need this for the usual case: whenever a script changes the photo, the reply
           * already includes it before your edits and as it is now.
           */
          show(which?: "current" | "before" | "original" | "mask", options?: { region?: Region; maxEdge?: number; mask?: string }): void;

          /**
           * The person's saved styles (filters): looks they can apply to any photo. Some were learned from
           * pictures in the app; applying one of those adapts it to this photo and changes only tone and colour.
           */
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
             * display-referred (gamma-encoded) values; 2 to \(Specs.maxCurvePoints) points with distinct inputs, in any order.
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
             * one). At most \(Specs.maxLocalAdjustments) per photo.
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

          /** Puts a section back to how the photo was opened. Default "all". */
          reset(section?: ResetSection): void;

          /** Discards the changes this script has made so far. */
          revert(): void;

          /** Optional. Changes are kept automatically when the script ends without an error. */
          commit(): void;
        }

        type CurveChannel = \(union(Specs.curveChannels));
        type ColorRange = \(union(Specs.colorRanges));
        type GradingRange = \(union(Specs.gradingRanges));
        type ResetSection = \(union(Specs.resetSections));
        /** [input, output], both 0 to 1. */
        type CurvePoint = [number, number];
        /** Part of the frame, as fractions from its top-left corner. */
        interface Region { x: number; y: number; width: number; height: number; }

        interface GlobalAdjustments {
        \(fields(Specs.global) { $0.name == "temperature" || $0.name == "tint" ? "Starts at the as-shot value (getMetadata().asShot)." : nil })
        }

        interface HSLAdjustments {
        \(fields(Specs.hsl))
        }

        interface ColorGrading {
        \(fields(Specs.grading))
        }

        interface GradingMix {
        \(fields(Specs.gradingMix))
        }

        interface DetailSettings {
        \(fields(Specs.detail) { _ in "Starts at 0: nothing is added until you add it." })
        }

        interface GrainSettings {
        \(fields(Specs.grain))
        }

        interface HalationSettings {
        \(fields(Specs.halation))
        }

        /** Relative to the rest of the photo; 0 is no change. */
        interface LocalSettings {
        \(fields(Specs.localAdjustments))
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
         */
        interface Mask {
          area: RadialArea | LinearArea | SubjectArea | PeopleArea | FrameArea;
          /** Use everything outside the area instead. Default false. */
          invert?: boolean;
          /**
           * Keep only these tones, measured on the photo before this adjustment: display luminance from
           * 0 (black) to 1 (white), with soft edges `feather` wide (0 to 0.5, default 0.1).
           */
          luminance?: { from: number; to: number; feather?: number };
          /**
           * Keep only colours near this hue (0 red, 30 orange, 60 yellow, 120 green, 180 cyan, 240 blue,
           * 300 magenta), fading out beyond ±range/2 degrees (range 10 to 180, default 60). Greys are left out.
           */
          color?: { hue: number; range?: number };
        }

        /**
         * An ellipse. x, y: its centre (-0.5 to 1.5). width, height: its full size as fractions of the
         * frame's width and height (0.02 to 3). angle: degrees clockwise (-180 to 180, default 0).
         * feather: how soft the edge is, from 0 (hard) to 1 (fading from the centre); default 0.5.
         */
        interface RadialArea { type: "radial"; x: number; y: number; width: number; height: number; angle?: number; feather?: number; }
        /** A straight gradient: full strength at `from`, fading to nothing at `to`; [x, y] points (-0.5 to 1.5). A sky: from [0.5, 0] to [0.5, 0.45]. */
        interface LinearArea { type: "linear"; from: [number, number]; to: [number, number]; }
        /** The main subject or subjects, found by the phone's on-device image analysis. Empty when it finds none. */
        interface SubjectArea { type: "subject"; }
        /** Every person in the photo, found by the phone's on-device image analysis. Empty when there are none. */
        interface PeopleArea { type: "people"; }
        /** The whole frame: use it with `luminance` or `color` to pick tones or colours anywhere. */
        interface FrameArea { type: "frame"; }

        /**
         * Order of operations: flips, then rotation, then straightening (which trims the frame so no empty
         * corners show), then the crop rectangle, given as fractions of that trimmed frame from its top-left corner.
         */
        interface CropSettings {
          /** Left edge of the crop, 0 to 1. Default 0. */
          x: number;
          /** Top edge of the crop, 0 to 1. Default 0. */
          y: number;
          /** Width of the crop, \(formatNumber(Specs.minCropSize)) to 1. x + width must not exceed 1. Default 1. */
          width: number;
          /** Height of the crop, \(formatNumber(Specs.minCropSize)) to 1. y + height must not exceed 1. Default 1. */
          height: number;
          /** \(Specs.cropAngle.description) Range \(formatNumber(Specs.cropAngle.min)) to \(formatNumber(Specs.cropAngle.max))°. Default 0. */
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
         * data (inside the RAW decoder for RAW files). RAW files then get Oscuru's base curve: the light
         * as measured up to 0.75 of white, then a smooth roll-off so highlights compress instead of
         * clipping. No other tone curve, contrast or local tone mapping is applied for you, so an
         * unedited RAW looks flat and true to the scene. Then: local highlight/shadow recovery, clarity and
         * texture, the tone stage (dehaze, blacks/whites, contrast, curves), the colour stage (HSL,
         * vibrance, saturation, grading), halation, geometry, local adjustments, vignette, grain.
         */

        """
}
