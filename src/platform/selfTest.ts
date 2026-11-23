/**
 * A check of the whole chain on a real iOS runtime, for CI: the sandbox in Hermes, the bridge to
 * the native engine, rendering, statistics and export. It runs only when the app is launched with
 * `-oscuruSelfTest YES` (the simulator job does that) and writes `selftest.json` to the documents
 * directory. Launched normally, the app never touches this.
 */

import { File, Paths } from 'expo-file-system';
import { Settings } from 'react-native';

import { EditorSession } from '@/editor/session';
import { adjustGlobal } from '@/engine/state';
import { OscuruEngine } from '@modules/oscuru-engine';
import { createNativeRenderer } from './renderer';

/** An uncompressed 24-bit BMP: a horizontal grey ramp with a blue lower half. */
function testImage(width: number, height: number): Uint8Array {
  const rowSize = Math.ceil((width * 3) / 4) * 4;
  const bytes = new Uint8Array(54 + rowSize * height);
  const view = new DataView(bytes.buffer);
  bytes[0] = 0x42;
  bytes[1] = 0x4d;
  view.setUint32(2, bytes.length, true);
  view.setUint32(10, 54, true);
  view.setUint32(14, 40, true);
  view.setInt32(18, width, true);
  view.setInt32(22, height, true);
  view.setUint16(26, 1, true);
  view.setUint16(28, 24, true);
  view.setUint32(34, rowSize * height, true);
  for (let y = 0; y < height; y++) {
    // BMP rows run bottom to top.
    const lower = y < height / 2;
    for (let x = 0; x < width; x++) {
      const level = Math.round((x / (width - 1)) * 200) + 20;
      const offset = 54 + y * rowSize + x * 3;
      bytes[offset] = lower ? 220 : level;
      bytes[offset + 1] = lower ? 60 : level;
      bytes[offset + 2] = lower ? 60 : level;
    }
  }
  return bytes;
}

export async function runSelfTestIfAsked(): Promise<void> {
  if (!Settings.get('oscuruSelfTest')) return;
  const report: { ok: boolean; steps: Record<string, unknown>; error?: string } = { ok: false, steps: {} };
  const engineId = 'selftest';
  try {
    const source = new File(Paths.cache, 'selftest.bmp');
    source.write(testImage(240, 160));
    const info = await OscuruEngine.open(engineId, source.uri);
    report.steps.open = { width: info.width, height: info.height, isRaw: info.isRaw };
    if (info.width !== 240 || info.height !== 160) throw new Error('the engine reported the wrong size');

    const session = new EditorSession({ id: 'selftest', info, renderer: createNativeRenderer(engineId, info) });
    const before = await session.measure();
    if (!before) throw new Error(`the first rendering failed: ${session.getSnapshot().renderError}`);
    report.steps.before = { mean: before.statistics.meanLuminance, blue: before.statistics.colorDistribution.blue };

    // The assistant's path: a script in the sandbox, committed, rendered, measured.
    const run = await session.runScript(
      {
        sessionId: 'selftest',
        baseRevision: session.getSnapshot().revision,
        code: `
          const image = photo.current;
          const stats = image.getStatistics();
          image.adjust({ exposureEV: stats.meanLuminance < 0.9 ? 1 : 0, contrast: 10 });
          image.curves.set("rgb", [[0, 0.02], [0.5, 0.52], [1, 0.98]]);
          image.hsl.adjust("blue", { saturation: -100 });
          image.grading.set("shadows", { hue: 220, saturation: 0.1 });
          image.commit();
          return [1, 2, 3].map((n) => n * 2).join(",");
        `,
      },
      { runId: 'selftest' },
    );
    report.steps.script = { status: run.outcome.status, changed: run.outcome.changed, returned: run.outcome.returnValue, error: run.outcome.error, steps: run.outcome.steps };
    if (run.outcome.status !== 'ok' || !run.outcome.changed || run.outcome.returnValue !== '2,4,6') throw new Error('the script did not run as expected');
    if (!run.analysis) throw new Error('the edited photo could not be measured');
    report.steps.after = { mean: run.analysis.statistics.meanLuminance, blue: run.analysis.statistics.colorDistribution.blue };
    if (run.analysis.statistics.meanLuminance <= before.statistics.meanLuminance + 0.05) throw new Error('one stop of exposure did not brighten the photo');
    if (before.statistics.colorDistribution.blue < 0.3 || run.analysis.statistics.colorDistribution.blue > 0.05) throw new Error('desaturating blue through the colour cube had no effect');

    // The sandbox must hold in this JavaScript engine too.
    const escape = await session.runScript({ sessionId: 'selftest', baseRevision: run.revision, code: 'photo.current.commit.constructor("return this")()' }, { runId: 'selftest' });
    const loop = await session.runScript({ sessionId: 'selftest', baseRevision: run.revision, code: 'while (true) {}' }, { runId: 'selftest' }, { limits: { maxSteps: 20000 } });
    report.steps.sandbox = { escape: escape.outcome.error?.kind, loop: loop.outcome.error?.kind };
    if (escape.outcome.status !== 'error' || loop.outcome.error?.kind !== 'limit') throw new Error('the sandbox let something through');

    // Manual editing, crop geometry and a full-resolution export.
    session.change((state) => ({ ...adjustGlobal(state, { vignette: -40, clarity: 20 }), crop: { ...state.crop, rotation: 90, x: 0.1, width: 0.8, angle: 3 } }), 'selftest');
    await session.settled();
    const frame = session.getSnapshot().frame;
    report.steps.preview = { width: frame?.width, height: frame?.height, error: session.getSnapshot().renderError };
    if (!frame || frame.width >= frame.height) throw new Error('a quarter turn did not make the photo upright');
    const exported = await session.renderOnce({ purpose: 'export', format: 'heic' });
    const exportedFile = new File(exported.uri);
    report.steps.export = { width: exported.width, height: exported.height, bytes: exportedFile.size };
    if (!exportedFile.exists || exportedFile.size < 500) throw new Error('the export is missing or empty');
    session.undo();
    if (session.getSnapshot().state.crop.rotation !== 0) throw new Error('undo did not restore the crop');
    session.close();
    report.ok = true;
  } catch (error) {
    report.error = error instanceof Error ? error.message : String(error);
  } finally {
    await OscuruEngine.close(engineId).catch(() => undefined);
    new File(Paths.document, 'selftest.json').write(JSON.stringify(report, null, 2));
  }
}
