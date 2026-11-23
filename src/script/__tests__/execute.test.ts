import type { PhotoInfo } from '@/engine/photo';
import { defaultState } from '@/engine/state';
import { analyzePixels } from '@/engine/stats';
import { PHOTO_API_DECLARATIONS } from '../apiDeclarations';
import { executeEditScript, type ScriptEnvironment } from '../execute';
import { createPhotoApi } from '../photoApi';

const info: PhotoInfo = {
  fileName: 'IMG_0001.DNG',
  typeIdentifier: 'com.adobe.raw-image',
  isRaw: true,
  width: 4032,
  height: 3024,
  asShot: { temperature: 5200, tint: 8 },
  defaults: { temperature: 5200, tint: 8, sharpening: 40, noiseReduction: 50, colorNoiseReduction: 50 },
  make: 'Apple',
  model: 'iPhone 17 Pro',
  iso: 64,
};

// A bright frame: the top third is blown out.
const pixels = new Uint8Array(12 * 12 * 4);
for (let i = 0; i < 144; i++) pixels.set(i < 48 ? [255, 255, 255, 255] : [90, 110, 140, 255], i * 4);
const analysis = analyzePixels(pixels, 12, 12);

const environment = (overrides: Partial<ScriptEnvironment> = {}): ScriptEnvironment => ({
  sessionId: 'photo-1',
  revision: 7,
  state: defaultState(info.defaults),
  info,
  analysis,
  ...overrides,
});
const run = (code: string, env: ScriptEnvironment = environment(), request: Record<string, unknown> = {}) =>
  executeEditScript(env, { sessionId: 'photo-1', baseRevision: 7, code, ...request });

describe('execute_edit_script', () => {
  it('applies a committed script and lists what changed', () => {
    const outcome = run(`
      const image = photo.current;
      image.adjust({ exposureEV: 0.35, highlights: -40 });
      image.curves.set("rgb", [[0, 0.03], [0.5, 0.5], [1, 0.98]]);
      image.hsl.adjust("blue", { saturation: -15, luminance: -10 });
      image.grading.set("shadows", { hue: 215, saturation: 0.12 });
      image.commit();
    `);
    expect(outcome.status).toBe('ok');
    expect(outcome.changed).toBe(true);
    expect(outcome.state.global.exposureEV).toBe(0.35);
    expect(outcome.state.hsl.blue).toEqual({ hue: 0, saturation: -15, luminance: -10 });
    expect(outcome.changes.map((change) => change.path)).toEqual([
      'global.exposureEV',
      'global.highlights',
      'curves.rgb',
      'hsl.blue.saturation',
      'hsl.blue.luminance',
      'grading.shadows.hue',
      'grading.shadows.saturation',
    ]);
    expect(outcome.warnings).toEqual([]);
    expect(outcome.steps).toBeGreaterThan(0);
  });

  it('runs the conditional example from the specification', () => {
    const outcome = run(`
      const image = photo.current;
      const histogram = image.getHistogram();
      const stats = image.getStatistics();
      if (histogram.highlightClipping > 0.03) {
        image.adjust({ highlights: -45, exposureEV: -0.15 });
      }
      if (stats.averageSaturation < 0.25) {
        image.adjust({ vibrance: 15 });
      }
      image.commit();
      return { clipping: histogram.highlightClipping };
    `);
    expect(outcome.status).toBe('ok');
    expect(outcome.state.global).toMatchObject({ highlights: -45, exposureEV: -0.15, vibrance: 15 });
    expect(outcome.returnValue).toBe('{"clipping":0.3333}');
  });

  it('makes relative changes from the current state, starting from the as-shot white balance', () => {
    const outcome = run(`
      const { global } = photo.current.getState();
      photo.current.adjust({ temperature: global.temperature + 400, exposureEV: global.exposureEV + 0.25 });
      photo.current.commit();
    `);
    expect(outcome.state.global.temperature).toBe(5600);
    expect(outcome.state.global.exposureEV).toBe(0.25);
  });

  it('changes nothing without commit(), and says so', () => {
    const outcome = run('photo.current.adjust({ contrast: 30 });');
    expect(outcome.status).toBe('ok');
    expect(outcome.changed).toBe(false);
    expect(outcome.state.global.contrast).toBe(0);
    expect(outcome.warnings[0]).toMatch(/never called photo\.current\.commit\(\)/);
  });

  it('keeps only what was committed', () => {
    const outcome = run('photo.current.adjust({ contrast: 30 }); photo.current.commit(); photo.current.adjust({ contrast: 90 });');
    expect(outcome.state.global.contrast).toBe(30);
    expect(outcome.warnings[0]).toMatch(/after the last commit\(\) were discarded/);
  });

  it('lets an inspecting script report back without changing anything', () => {
    const outcome = run('console.log("iso", photo.current.getMetadata().iso); return photo.current.getStatistics().zones[0][0];');
    expect(outcome.changed).toBe(false);
    expect(outcome.logs).toEqual(['iso 64']);
    expect(outcome.returnValue).toBe('1');
    expect(outcome.warnings).toEqual([]);
  });

  it('rolls everything back when the script throws, even after commit()', () => {
    const outcome = run('photo.current.adjust({ contrast: 30 }); photo.current.commit(); console.log("about to fail"); photo.current.adjust({ exposureEV: 99 });');
    expect(outcome.status).toBe('error');
    expect(outcome.changed).toBe(false);
    expect(outcome.state.global.contrast).toBe(0);
    expect(outcome.error?.message).toContain('adjust.exposureEV must be between -5 and 5, got 99');
    expect(outcome.error?.line).toBe(1);
    expect(outcome.logs).toEqual(['about to fail']);
  });

  it('lets a script catch a validation error and carry on', () => {
    const outcome = run(`
      try { photo.current.adjust({ saturation: 500 }); } catch (error) { console.log(error.name, error.message); }
      photo.current.adjust({ saturation: 20 });
      photo.current.commit();
    `);
    expect(outcome.status).toBe('ok');
    expect(outcome.state.global.saturation).toBe(20);
    expect(outcome.logs[0]).toContain('RangeError adjust.saturation must be between -100 and 100');
  });

  it('reports syntax errors, runaway loops and escapes without changing anything', () => {
    expect(run('photo.current.adjust({').error?.kind).toBe('syntax');
    const loop = executeEditScript(environment(), { sessionId: 'photo-1', baseRevision: 7, code: 'photo.current.adjust({contrast: 5}); photo.current.commit(); while (true) {}' }, { limits: { maxSteps: 5000 } });
    expect(loop.status).toBe('error');
    expect(loop.error?.kind).toBe('limit');
    expect(loop.changed).toBe(false);
    expect(run('photo.current.commit.constructor("return globalThis")()').status).toBe('error');
    expect(run('fetch("https://example.com")').error?.message).toMatch(/fetch is not defined/);
    expect(run('class A {}').error?.kind).toBe('unsupported');
  });

  it('stops when cancelled', () => {
    const outcome = executeEditScript(environment(), { sessionId: 'photo-1', baseRevision: 7, code: 'for (let i = 0; i < 1e9; i++) {}' }, { signal: { aborted: true } });
    expect(outcome.error?.kind).toBe('aborted');
  });

  it('refuses a stale revision, a different session and malformed requests before running anything', () => {
    const stale = run('photo.current.adjust({contrast: 5}); photo.current.commit();', environment({ revision: 9 }));
    expect(stale.status).toBe('stale_revision');
    expect(stale.changed).toBe(false);
    expect(stale.error?.message).toContain('revision 9, not 7');
    expect(run('1', environment(), { sessionId: 'other' }).status).toBe('wrong_session');
    expect(run('   ').status).toBe('invalid_request');
    expect(run('1', environment(), { baseRevision: '7' }).status).toBe('invalid_request');
    expect(run('1', environment(), { code: 42 }).status).toBe('invalid_request');
  });

  it('cannot change the API objects or the data it was given', () => {
    expect(run('photo.current.adjust = () => {};').status).toBe('error');
    expect(run('photo.current = null;').status).toBe('error');
    const env = environment();
    const outcome = run('const state = photo.current.getState(); state.global.exposureEV = 3; const h = photo.current.getHistogram(); h.luminance[0] = 99; photo.current.commit();', env);
    expect(outcome.changed).toBe(false);
    expect(env.state.global.exposureEV).toBe(0);
    expect(env.analysis?.histogram.luminance[0]).not.toBe(99);
  });

  it('explains that statistics need a rendering', () => {
    const outcome = run('photo.current.getHistogram()', environment({ analysis: null }));
    expect(outcome.status).toBe('error');
    expect(outcome.error?.message).toContain('has not been rendered yet');
  });

  it('supports the rest of the API: getters, resets, detail, crop and grading mix', () => {
    const outcome = run(`
      const image = photo.current;
      image.adjust({ contrast: 20, temperature: 7000 });
      image.curves.set("red", [[0, 0.1], [1, 1]]);
      image.hsl.adjust("green", { hue: 10 });
      image.grading.set("highlights", { hue: 40, saturation: 0.1 });
      image.grading.configure({ balance: 0.3 });
      image.detail.set({ sharpening: 60 });
      image.crop({ x: 0.1, width: 0.8, angle: 1.5, rotation: 90 });
      const before = [image.curves.get("red")[0][1], image.hsl.get("green").hue, image.grading.get("highlights").hue, image.detail.get().sharpening];
      image.curves.reset("red");
      image.hsl.reset();
      image.reset("color");
      image.commit();
      return before;
    `);
    expect(outcome.status).toBe('ok');
    expect(outcome.returnValue).toBe('[0.1,10,40,60]');
    expect(outcome.state.curves.red).toEqual([[0, 0], [1, 1]]);
    expect(outcome.state.hsl.green.hue).toBe(0);
    expect(outcome.state.global.temperature).toBe(5200);
    expect(outcome.state.global.contrast).toBe(20);
    expect(outcome.state.grading.balance).toBe(0.3);
    expect(outcome.state.detail.sharpening).toBe(60);
    expect(outcome.state.crop).toMatchObject({ x: 0.1, width: 0.8, angle: 1.5, rotation: 90 });
  });

  it('notes a commit that changes nothing', () => {
    const outcome = run('photo.current.adjust({ contrast: 0 }); photo.current.commit();');
    expect(outcome.changed).toBe(false);
    expect(outcome.warnings).toEqual(['commit() was called but no setting differs from before.']);
  });
});

describe('API declarations', () => {
  /** Member names declared inside `interface PhotoDocument`, including the nested groups. */
  function declaredMembers(): string[] {
    const start = PHOTO_API_DECLARATIONS.indexOf('interface PhotoDocument {');
    const end = PHOTO_API_DECLARATIONS.indexOf('\ntype CurveChannel');
    const body = PHOTO_API_DECLARATIONS.slice(start, end).replace(/\/\*\*[\s\S]*?\*\//g, '');
    const names: string[] = [];
    let group = '';
    for (const line of body.split('\n')) {
      const opened = /^\s{2}readonly (\w+): \{/.exec(line);
      const member = /^\s+(\w+)\(/.exec(line);
      if (opened) group = `${opened[1]}.`;
      else if (/^\s{2}\};/.test(line)) group = '';
      else if (member) names.push(group + member[1]);
    }
    return names.sort();
  }

  it('document exactly the members the runtime provides', () => {
    const api = createPhotoApi(environment()).globals.photo as { current: Record<string, unknown> };
    const provided: string[] = [];
    for (const [name, value] of Object.entries(api.current)) {
      if (typeof value === 'function') provided.push(name);
      else for (const inner of Object.keys(value as object)) provided.push(`${name}.${inner}`);
    }
    expect(declaredMembers()).toEqual(provided.sort());
  });

  it('state the same ranges the editor enforces', () => {
    expect(PHOTO_API_DECLARATIONS).toContain('Range -5 to 5 stops. Default 0.');
    expect(PHOTO_API_DECLARATIONS).toContain('Range 2000 to 25000 K. Starts at the as-shot value (getMetadata().asShot).');
    expect(PHOTO_API_DECLARATIONS).toContain('type ColorRange = "red" | "orange" | "yellow" | "green" | "aqua" | "blue" | "purple" | "magenta";');
    expect(PHOTO_API_DECLARATIONS).toContain('2 to 16 points');
  });
});
