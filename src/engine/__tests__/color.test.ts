import { applyPointOps, basicTone, buildColorCube, buildToneTables, CUBE_SIZE, curveEvaluator, luma, TONE_TABLE_SIZE } from '../color';
import { buildRenderInput } from '../recipe';
import { adjustGlobal, adjustHSL, COLOR_RANGES, defaultState, GLOBAL_SPECS, setCrop, setCurve, setDetail, setGrading, setGradingMix, type EditingState } from '../state';
import { analyzePixels } from '../stats';

type RGB = [number, number, number];
const saturationOf = ([r, g, b]: RGB) => Math.max(r, g, b) - Math.min(r, g, b);
const base = defaultState();
const global = (settings: Record<string, number>): EditingState => adjustGlobal(base, settings);

describe('curves', () => {
  it('pass through their control points without overshooting', () => {
    const points: [number, number][] = [
      [0, 0.03],
      [0.25, 0.21],
      [0.5, 0.5],
      [0.75, 0.8],
      [1, 0.98],
    ];
    const curve = curveEvaluator(points);
    for (const [x, y] of points) expect(curve(x)).toBeCloseTo(y, 6);
    let previous = -1;
    for (let i = 0; i <= 200; i++) {
      const y = curve(i / 200);
      expect(y).toBeGreaterThanOrEqual(previous - 1e-9);
      previous = y;
    }
  });

  it('stay flat outside the first and last point and between equal points', () => {
    const curve = curveEvaluator([
      [0.2, 0.1],
      [0.5, 0.6],
      [0.7, 0.6],
      [0.9, 1],
    ]);
    expect(curve(0)).toBe(0.1);
    expect(curve(1)).toBe(1);
    expect(curve(0.6)).toBeCloseTo(0.6, 6);
  });

  it('may go down as well as up', () => {
    const invert = curveEvaluator([
      [0, 1],
      [1, 0],
    ]);
    expect(invert(0.25)).toBeCloseTo(0.75, 6);
  });
});

describe('tone stage', () => {
  it('is skipped entirely for an untouched photo and for settings handled elsewhere', () => {
    expect(buildToneTables(base)).toBeNull();
    expect(buildToneTables(global({ exposureEV: 1, temperature: 5000, highlights: -50, shadows: 40, saturation: 20, clarity: 10 }))).toBeNull();
    expect(applyPointOps(base, [0.3, 0.6, 0.9])).toEqual([0.3, 0.6, 0.9]);
  });

  it.each(Object.keys(GLOBAL_SPECS).filter((key) => ['contrast', 'whites', 'blacks', 'dehaze', 'highlights', 'shadows'].includes(key)))(
    '%s never reverses tones at either extreme',
    (key) => {
      for (const value of [-100, 100]) {
        const tone = basicTone(global({ [key]: value }));
        let previous = -1;
        for (let i = 0; i <= 500; i++) {
          const y = tone(i / 500);
          expect(y).toBeGreaterThanOrEqual(0);
          expect(y).toBeLessThanOrEqual(1);
          expect(y).toBeGreaterThanOrEqual(previous - 1e-9);
          previous = y;
        }
      }
    },
  );

  it('contrast pivots on mid-grey', () => {
    const more = basicTone(global({ contrast: 50 }));
    expect(more(0.5)).toBeCloseTo(0.5, 6);
    expect(more(0.25)).toBeLessThan(0.25);
    expect(more(0.75)).toBeGreaterThan(0.75);
    expect(more(0)).toBe(0);
    expect(more(1)).toBe(1);
    const less = basicTone(global({ contrast: -50 }));
    expect(less(0.25)).toBeGreaterThan(0.25);
    expect(less(0.75)).toBeLessThan(0.75);
  });

  it('blacks and whites move their own end of the range', () => {
    const crushed = basicTone(global({ blacks: -60 }));
    expect(crushed(0.1)).toBeLessThan(0.05);
    expect(crushed(0.9)).toBeCloseTo(0.9, 2);
    const lifted = basicTone(global({ blacks: 60 }));
    expect(lifted(0)).toBeCloseTo(0.12, 6);
    const bright = basicTone(global({ whites: 60 }));
    expect(bright(0.9)).toBeGreaterThan(0.95);
    expect(bright(0.1)).toBeCloseTo(0.1, 2);
    expect(basicTone(global({ whites: -60 }))(1)).toBeCloseTo(0.88, 6);
  });

  it('only the non-recovering directions of highlights and shadows are point operations', () => {
    expect(basicTone(global({ highlights: 60 }))(0.7)).toBeGreaterThan(0.7);
    expect(basicTone(global({ highlights: -60 }))(0.7)).toBe(0.7);
    expect(basicTone(global({ shadows: -60 }))(0.3)).toBeLessThan(0.3);
    expect(basicTone(global({ shadows: 60 }))(0.3)).toBe(0.3);
  });

  it('builds interleaved tables: basic tone, then the master curve, then each channel', () => {
    let state = global({ contrast: 30 });
    state = setCurve(state, 'rgb', [
      [0, 0.1],
      [1, 0.9],
    ]);
    state = setCurve(state, 'blue', [
      [0, 0],
      [1, 0.5],
    ]);
    const table = buildToneTables(state)!;
    expect(table).toHaveLength(TONE_TABLE_SIZE * 3);
    const last = (TONE_TABLE_SIZE - 1) * 3;
    expect(table[0]).toBeCloseTo(0.1, 5);
    expect(table[last]).toBeCloseTo(0.9, 5);
    expect(table[last + 1]).toBeCloseTo(0.9, 5);
    expect(table[last + 2]).toBeCloseTo(0.45, 5);
    const [r, g, b] = applyPointOps(state, [1, 1, 1]);
    expect([r, g, b].map((v) => Math.round(v * 100))).toEqual([90, 90, 45]);
  });
});

describe('colour stage', () => {
  it('is skipped for an untouched photo and builds a red-fastest RGBA cube otherwise', () => {
    expect(buildColorCube(base)).toBeNull();
    expect(buildColorCube(global({ contrast: 50 }))).toBeNull();
    const cube = buildColorCube(global({ saturation: -100 }))!;
    expect(cube).toHaveLength(CUBE_SIZE ** 3 * 4);
    // Second entry is the next red step: (1/32, 0, 0), desaturated to its luma.
    const y = luma(1 / 32, 0, 0);
    expect(cube[4]).toBeCloseTo(y, 5);
    expect(cube[5]).toBeCloseTo(y, 5);
    expect(cube[6]).toBeCloseTo(y, 5);
    expect(cube[7]).toBe(1);
  });

  it('keeps every value inside 0–1 under extreme settings', () => {
    let state = global({ saturation: 100, vibrance: 100, dehaze: 100 });
    for (const color of COLOR_RANGES) state = adjustHSL(state, color, { hue: 100, saturation: 100, luminance: 100 });
    state = setGrading(state, 'shadows', { hue: 220, saturation: 1, luminance: -1 });
    state = setGrading(state, 'highlights', { hue: 40, saturation: 1, luminance: 1 });
    const cube = buildColorCube(state, 9)!;
    for (const value of cube) {
      expect(Number.isFinite(value)).toBe(true);
      expect(value).toBeGreaterThanOrEqual(0);
      expect(value).toBeLessThanOrEqual(1);
    }
  });

  it('saturation −100 is black and white and keeps brightness', () => {
    const input: RGB = [0.8, 0.3, 0.2];
    const out = applyPointOps(global({ saturation: -100 }), input);
    expect(out[0]).toBeCloseTo(out[1], 6);
    expect(out[1]).toBeCloseTo(out[2], 6);
    expect(out[0]).toBeCloseTo(luma(...input), 6);
  });

  it('saturation never touches greys', () => {
    expect(applyPointOps(global({ saturation: 100, vibrance: 100 }), [0.4, 0.4, 0.4])).toEqual([0.4, 0.4, 0.4]);
  });

  it('vibrance lifts muted colours more than vivid ones and goes easy on skin', () => {
    const state = global({ vibrance: 60 });
    const gain = (input: RGB) => saturationOf(applyPointOps(state, input)) / saturationOf(input);
    const muted: RGB = [0.45, 0.5, 0.6];
    const vivid: RGB = [0.1, 0.3, 0.9];
    expect(gain(muted)).toBeGreaterThan(gain(vivid));
    expect(gain(vivid)).toBeGreaterThanOrEqual(1);
    const skin: RGB = [0.8, 0.6, 0.5];
    const sky: RGB = [0.5, 0.6, 0.8];
    expect(gain(sky)).toBeGreaterThan(gain(skin));
  });

  it('HSL changes its own colour range and leaves the others alone', () => {
    const state = adjustHSL(base, 'blue', { saturation: -100 });
    const blue = applyPointOps(state, [0.15, 0.15, 0.9]);
    expect(saturationOf(blue)).toBeLessThan(0.02);
    const red: RGB = [0.9, 0.15, 0.1];
    expect(applyPointOps(state, red)).toEqual(red);
    const grey: RGB = [0.5, 0.5, 0.5];
    expect(applyPointOps(state, grey)).toEqual(grey);
  });

  it('HSL fades between neighbouring ranges', () => {
    const state = adjustHSL(base, 'blue', { saturation: -100 });
    // Hue 210 is half way between aqua (180) and blue (240).
    const between: RGB = [0.1, 0.5, 0.9];
    const out = saturationOf(applyPointOps(state, between)) / saturationOf(between);
    expect(out).toBeGreaterThan(0.3);
    expect(out).toBeLessThan(0.7);
  });

  it('HSL hue turns colours the expected way and keeps their brightness', () => {
    const red: RGB = [0.8, 0.2, 0.2];
    const towardsOrange = applyPointOps(adjustHSL(base, 'red', { hue: 100 }), red);
    expect(towardsOrange[1]).toBeGreaterThan(towardsOrange[2] + 0.1);
    expect(luma(...towardsOrange)).toBeCloseTo(luma(...red), 3);
    const towardsMagenta = applyPointOps(adjustHSL(base, 'red', { hue: -100 }), red);
    expect(towardsMagenta[2]).toBeGreaterThan(towardsMagenta[1] + 0.1);
  });

  it('HSL luminance darkens and brightens a colour', () => {
    const blue: RGB = [0.2, 0.3, 0.8];
    expect(luma(...applyPointOps(adjustHSL(base, 'blue', { luminance: -50 }), blue))).toBeLessThan(luma(...blue) - 0.05);
    expect(luma(...applyPointOps(adjustHSL(base, 'blue', { luminance: 50 }), blue))).toBeGreaterThan(luma(...blue) + 0.03);
  });

  it('grading tints each tonal range with its own hue', () => {
    let state = setGrading(base, 'shadows', { hue: 240, saturation: 0.3 });
    state = setGrading(state, 'highlights', { hue: 40, saturation: 0.3 });
    const dark = applyPointOps(state, [0.1, 0.1, 0.1]);
    expect(dark[2]).toBeGreaterThan(dark[0]);
    const bright = applyPointOps(state, [0.9, 0.9, 0.9]);
    expect(bright[0]).toBeGreaterThan(bright[2]);
    // A tint adds colour, not brightness.
    expect(luma(...bright)).toBeCloseTo(0.9, 2);
  });

  it('grading balance moves the split between shadows and highlights', () => {
    const tinted = setGrading(base, 'shadows', { hue: 240, saturation: 0.5 });
    const mid: RGB = [0.5, 0.5, 0.5];
    const blueness = (state: EditingState) => {
      const out = applyPointOps(state, mid);
      return out[2] - out[0];
    };
    expect(blueness(setGradingMix(tinted, { balance: -0.8 }))).toBeGreaterThan(blueness(tinted));
    expect(blueness(setGradingMix(tinted, { balance: 0.8 }))).toBeLessThan(blueness(tinted));
    expect(blueness(setGradingMix(tinted, { blending: 1 }))).toBeGreaterThan(blueness(setGradingMix(tinted, { blending: 0 })));
  });

  it('grading luminance alone lifts or lowers its range', () => {
    const state = setGrading(base, 'shadows', { luminance: 0.5 });
    expect(applyPointOps(state, [0.1, 0.1, 0.1])[0]).toBeGreaterThan(0.15);
    expect(applyPointOps(state, [0.95, 0.95, 0.95])[0]).toBeCloseTo(0.95, 2);
  });

  it('the cube agrees with the exact calculation at its grid points', () => {
    let state = global({ saturation: 20, vibrance: 30 });
    state = adjustHSL(state, 'green', { hue: 40, saturation: -30, luminance: 10 });
    state = setGrading(state, 'midtones', { hue: 100, saturation: 0.2 });
    const size = 5;
    const cube = buildColorCube(state, size)!;
    for (const [r, g, b] of [
      [1, 2, 3],
      [4, 0, 2],
      [2, 2, 2],
    ]) {
      const offset = ((b * size + g) * size + r) * 4;
      const exact = applyPointOps(state, [r / 4, g / 4, b / 4]);
      expect(cube[offset]).toBeCloseTo(exact[0], 5);
      expect(cube[offset + 1]).toBeCloseTo(exact[1], 5);
      expect(cube[offset + 2]).toBeCloseTo(exact[2], 5);
    }
  });
});

describe('render recipe', () => {
  it('sends nothing for an untouched photo', () => {
    const defaults = { temperature: 5200, tint: 10, sharpening: 40, noiseReduction: 50, colorNoiseReduction: 50 };
    const { recipe, toneTable, cube } = buildRenderInput(defaultState(defaults), defaults);
    expect(toneTable).toHaveLength(0);
    expect(cube).toHaveLength(0);
    expect(recipe).toMatchObject({
      exposureEV: 0,
      temperature: null,
      tint: null,
      shadowAmount: 0,
      highlightAmount: 1,
      localContrast: [],
      sharpening: null,
      noiseReduction: null,
      colorNoiseReduction: null,
      vignette: 0,
      cropX: 0,
      cropY: 0,
      cropWidth: 1,
      cropHeight: 1,
    });
  });

  it('maps settings to filter amounts', () => {
    const defaults = { temperature: 5200, tint: 10 };
    let state = defaultState(defaults);
    state = adjustGlobal(state, { exposureEV: 0.5, temperature: 6000, highlights: -100, shadows: 50, clarity: 50, texture: -50, vignette: -40, contrast: 10, saturation: 10 });
    state = setDetail(state, { sharpening: 30, noiseReduction: 20 });
    state = setCrop(state, { x: 0.1, y: 0.2, width: 0.5, height: 0.6, angle: 3, rotation: 270, flipVertical: true });
    const { recipe, toneTable, cube } = buildRenderInput(state, defaults);
    expect(recipe.exposureEV).toBe(0.5);
    expect(recipe.temperature).toBe(6000);
    expect(recipe.tint).toBe(10);
    expect(recipe.highlightAmount).toBeCloseTo(0.3, 6);
    expect(recipe.shadowAmount).toBeCloseTo(0.4, 6);
    expect(recipe.localContrast).toEqual([
      { radius: 0.02, intensity: 0.35 },
      { radius: 0.003, intensity: -0.3 },
    ]);
    expect(recipe.sharpening).toBe(0.3);
    expect(recipe.noiseReduction).toBe(0.2);
    expect(recipe.colorNoiseReduction).toBeNull();
    expect(recipe.vignette).toBe(0.4);
    expect(recipe).toMatchObject({ cropX: 0.1, cropY: 0.2, cropWidth: 0.5, cropHeight: 0.6, angle: 3, rotation: 270, flipVertical: true, flipHorizontal: false });
    expect(toneTable).toHaveLength(recipe.toneTableSize * 3 * 4);
    expect(cube).toHaveLength(recipe.cubeSize ** 3 * 4 * 4);
    // The bytes are the floats themselves.
    const floats = new Float32Array(toneTable.buffer, toneTable.byteOffset, toneTable.byteLength / 4);
    expect(floats[0]).toBe(0);
    expect(floats[floats.length - 1]).toBe(1);
  });
});

describe('statistics', () => {
  const bitmap = (width: number, height: number, paint: (x: number, y: number) => [number, number, number]) => {
    const pixels = new Uint8Array(width * height * 4);
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        pixels.set([...paint(x, y), 255], (y * width + x) * 4);
      }
    }
    return analyzePixels(pixels, width, height);
  };

  it('measures a flat grey', () => {
    const { histogram, statistics } = bitmap(8, 8, () => [128, 128, 128]);
    expect(histogram.luminance[128]).toBe(1);
    expect(histogram.luminance.reduce((a, b) => a + b, 0)).toBeCloseTo(1, 5);
    expect(statistics.meanLuminance).toBeCloseTo(0.502, 3);
    expect(statistics.medianLuminance).toBeCloseTo(0.502, 3);
    expect(statistics.contrast).toBe(0);
    expect(statistics.averageSaturation).toBe(0);
    expect(statistics.highlightClipping).toBe(0);
    expect(statistics.colorDistribution.neutral).toBe(1);
    expect(statistics.zones).toEqual([
      [0.502, 0.502, 0.502],
      [0.502, 0.502, 0.502],
      [0.502, 0.502, 0.502],
    ]);
  });

  it('reports clipping, zones, casts and colour ranges', () => {
    // Top third white (clipped sky), bottom black, middle a saturated blue.
    const { histogram, statistics } = bitmap(9, 9, (_, y) => (y < 3 ? [255, 255, 255] : y < 6 ? [20, 40, 220] : [0, 0, 0]));
    expect(histogram.highlightClipping).toBeCloseTo(1 / 3, 3);
    expect(histogram.shadowClipping).toBeCloseTo(1 / 3, 3);
    expect(statistics.zones[0][0]).toBe(1);
    expect(statistics.zones[2][2]).toBe(0);
    expect(statistics.colorDistribution.blue).toBeCloseTo(1 / 3, 3);
    expect(statistics.colorCast.blue).toBeGreaterThan(statistics.colorCast.red);
    expect(statistics.percentiles.p1).toBe(0);
    expect(statistics.percentiles.p99).toBe(1);
    expect(statistics.dynamicRange).toBe(1);
    expect(statistics.clippedChannels.red).toBeCloseTo(1 / 3, 3);
  });

  it('refuses a bitmap that is too short', () => {
    expect(() => analyzePixels(new Uint8Array(8), 4, 4)).toThrow('shorter');
  });
});
