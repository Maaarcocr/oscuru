import {
  adjustGlobal,
  adjustHSL,
  defaultState,
  diffStates,
  normalizeCurve,
  parseState,
  resetSection,
  setCrop,
  setCurve,
  setDetail,
  setGrading,
  setGradingMix,
  statesEqual,
  straightenScale,
} from '../state';

describe('editing state', () => {
  it('starts from the photo, not from a generic white balance', () => {
    const state = defaultState({ temperature: 5234.6, tint: 11.2, noiseReduction: 42.4 });
    expect(state.global.temperature).toBe(5235);
    expect(state.global.tint).toBe(11);
    expect(state.detail.noiseReduction).toBe(42);
    expect(state.global.exposureEV).toBe(0);
    expect(state.curves.rgb).toEqual([
      [0, 0],
      [1, 1],
    ]);
  });

  it('sets only the settings that are given and leaves the input untouched', () => {
    const before = defaultState();
    const after = adjustGlobal(before, { exposureEV: 0.35, highlights: -40 });
    expect(after.global.exposureEV).toBe(0.35);
    expect(after.global.highlights).toBe(-40);
    expect(after.global.shadows).toBe(0);
    expect(before.global.exposureEV).toBe(0);
  });

  it('rejects out-of-range, non-numeric and unknown settings with a message that says what is valid', () => {
    const state = defaultState();
    expect(() => adjustGlobal(state, { exposureEV: 9 })).toThrow('adjust.exposureEV must be between -5 and 5, got 9');
    expect(() => adjustGlobal(state, { contrast: '10' })).toThrow('must be a finite number');
    expect(() => adjustGlobal(state, { contrast: NaN })).toThrow('must be a finite number');
    expect(() => adjustGlobal(state, { exposure: 1 })).toThrow(/no setting "exposure".*exposureEV/);
    expect(() => adjustGlobal(state, 5)).toThrow('must be an object');
    expect(() => adjustHSL(state, 'teal', { hue: 1 })).toThrow(/"aqua"/);
    expect(() => setGrading(state, 'shadows', { saturation: 12 })).toThrow('between 0 and 1');
    expect(() => setDetail(state, { sharpening: -1 })).toThrow('between 0 and 100');
  });

  it('reports errors as RangeError so scripts see a familiar name', () => {
    try {
      adjustGlobal(defaultState(), { tint: 999 });
      throw new Error('should have thrown');
    } catch (error) {
      expect((error as Error).name).toBe('RangeError');
    }
  });

  it('sorts curve points and rejects invalid curves', () => {
    expect(
      normalizeCurve('c', [
        [1, 0.9],
        [0, 0.1],
        [0.5, 0.5],
      ]),
    ).toEqual([
      [0, 0.1],
      [0.5, 0.5],
      [1, 0.9],
    ]);
    expect(() => normalizeCurve('c', [[0, 0]])).toThrow('between 2 and 16 points');
    expect(() =>
      normalizeCurve('c', [
        [0, 0],
        [0.5, 1.2],
      ]),
    ).toThrow('between 0 and 1');
    expect(() =>
      normalizeCurve('c', [
        [0.5, 0],
        [0.5, 1],
      ]),
    ).toThrow('same input');
    expect(() => normalizeCurve('c', [[0, 0], [1]])).toThrow('[input, output] pair');
    expect(() => normalizeCurve('c', Array.from({ length: 17 }, (_, i) => [i / 16, i / 16]))).toThrow('between 2 and 16 points');
    expect(() => setCurve(defaultState(), 'luma', [])).toThrow('"rgb"');
  });

  it('merges HSL, grading and crop settings', () => {
    let state = defaultState();
    state = adjustHSL(state, 'blue', { saturation: -15 });
    state = adjustHSL(state, 'blue', { luminance: -10 });
    expect(state.hsl.blue).toEqual({ hue: 0, saturation: -15, luminance: -10 });
    state = setGrading(state, 'shadows', { hue: 215, saturation: 0.12 });
    state = setGradingMix(state, { balance: -0.2 });
    expect(state.grading.shadows).toEqual({ hue: 215, saturation: 0.12, luminance: 0 });
    expect(state.grading.balance).toBe(-0.2);
    expect(state.grading.blending).toBe(0.5);
    state = setCrop(state, { x: 0.1, width: 0.8, rotation: 90, flipHorizontal: true });
    expect(state.crop).toMatchObject({ x: 0.1, y: 0, width: 0.8, height: 1, rotation: 90, flipHorizontal: true });
  });

  it('keeps the crop rectangle inside the frame', () => {
    const state = defaultState();
    expect(() => setCrop(state, { x: 0.5, width: 0.8 })).toThrow('leaves the frame');
    expect(() => setCrop(state, { width: 0.01 })).toThrow('between 0.05 and 1');
    expect(() => setCrop(state, { rotation: 45 })).toThrow('0, 90, 180 or 270');
    expect(() => setCrop(state, { flipVertical: 'yes' })).toThrow('true or false');
    expect(() => setCrop(state, { angle: 50 })).toThrow('between -45 and 45');
  });

  it('resets one section back to the photo as opened', () => {
    const base = { temperature: 5200, tint: 8 };
    let state = defaultState(base);
    state = adjustGlobal(state, { exposureEV: 1, temperature: 7000, clarity: 20 });
    state = setCurve(state, 'red', [
      [0, 0.1],
      [1, 1],
    ]);
    const light = resetSection(state, 'light', base);
    expect(light.global.exposureEV).toBe(0);
    expect(light.global.temperature).toBe(7000);
    const color = resetSection(state, 'color', base);
    expect(color.global.temperature).toBe(5200);
    expect(color.global.exposureEV).toBe(1);
    expect(resetSection(state, 'detail', base).global.clarity).toBe(0);
    expect(resetSection(state, 'curves', base).curves.red).toEqual([
      [0, 0],
      [1, 1],
    ]);
    expect(statesEqual(resetSection(state, 'all', base), defaultState(base))).toBe(true);
    expect(() => resetSection(state, 'everything')).toThrow('"all"');
  });

  it('round-trips through JSON and refuses damaged documents', () => {
    let state = defaultState({ temperature: 4800, tint: -3 });
    state = adjustGlobal(state, { contrast: 12, vibrance: 15 });
    state = setCurve(state, 'rgb', [
      [0, 0.03],
      [0.5, 0.5],
      [1, 0.98],
    ]);
    state = adjustHSL(state, 'orange', { saturation: 5, luminance: 8 });
    state = setGrading(state, 'highlights', { hue: 42, saturation: 0.08 });
    state = setCrop(state, { angle: 2.5, y: 0.1, height: 0.8 });
    expect(parseState(JSON.parse(JSON.stringify(state)))).toEqual(state);
    expect(() => parseState({ global: { exposureEV: 99 } })).toThrow('between -5 and 5');
    expect(() => parseState({ hsl: { teal: {} } })).toThrow('no setting "teal"');
    expect(() => parseState(null)).toThrow('must be an object');
    expect(parseState({})).toEqual(defaultState());
  });

  it('lists changes one setting at a time', () => {
    const before = defaultState();
    let after = adjustGlobal(before, { exposureEV: 0.5 });
    after = setCurve(after, 'rgb', [
      [0, 0.05],
      [1, 1],
    ]);
    after = adjustHSL(after, 'blue', { saturation: -15 });
    expect(diffStates(before, after)).toEqual([
      { path: 'global.exposureEV', from: 0, to: 0.5 },
      {
        path: 'curves.rgb',
        from: [
          [0, 0],
          [1, 1],
        ],
        to: [
          [0, 0.05],
          [1, 1],
        ],
      },
      { path: 'hsl.blue.saturation', from: 0, to: -15 },
    ]);
    expect(diffStates(before, before)).toEqual([]);
  });

  it('knows how much frame straightening costs', () => {
    expect(straightenScale(0, 1.5)).toBe(1);
    expect(straightenScale(45, 1)).toBeCloseTo(1 / Math.SQRT2, 5);
    expect(straightenScale(10, 1.5)).toBeCloseTo(straightenScale(-10, 1 / 1.5), 10);
    expect(straightenScale(10, 1.5)).toBeLessThan(straightenScale(5, 1.5));
  });
});
