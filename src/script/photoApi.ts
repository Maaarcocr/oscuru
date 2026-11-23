/**
 * The `photo` object that edit scripts see. Every method works on a private draft of the editing
 * state; nothing reaches the real document unless the script calls `commit()` and then finishes
 * without an error.
 *
 * The contract scripts are written against is `apiDeclarations.ts`. Keep the two in step:
 * `apiDocs.test.ts` fails when a documented member is missing here or the other way round.
 */

import type { PhotoInfo } from '@/engine/photo';
import {
  adjustGlobal,
  adjustHSL,
  cloneState,
  COLOR_RANGES,
  CURVE_CHANNELS,
  GRADING_RANGES,
  resetSection,
  setCrop,
  setCurve,
  setDetail,
  setGrading,
  setGradingMix,
  StateError,
  statesEqual,
  type ColorRange,
  type CurveChannel,
  type EditingState,
  type GradingRange,
} from '@/engine/state';
import type { ImageAnalysis } from '@/engine/stats';

export interface ScriptContext {
  revision: number;
  state: EditingState;
  info: PhotoInfo;
  /** Measurements of the photo as rendered at `revision`. Null before the first render. */
  analysis: ImageAnalysis | null;
}

export interface PhotoApi {
  /** Bindings to hand to the interpreter as globals. */
  globals: { photo: unknown; console: unknown };
  /** The last state passed to `commit()`, or null when the script never committed. */
  committed(): EditingState | null;
  /** True when the draft differs from what was last committed (or from the start). */
  hasUncommittedChanges(): boolean;
  logs(): string[];
}

const MAX_LOG_LINES = 40;
const MAX_LOG_LINE_LENGTH = 400;

const copy = <T>(value: T): T => JSON.parse(JSON.stringify(value)) as T;

function oneOf<T extends string>(what: string, value: unknown, allowed: readonly T[]): T {
  if (typeof value !== 'string' || !(allowed as readonly string[]).includes(value)) {
    throw new StateError(`${what} must be one of ${allowed.map((v) => `"${v}"`).join(', ')}, got ${JSON.stringify(value) ?? String(value)}`);
  }
  return value as T;
}

/** Turns anything a script logs or returns into short, safe text. */
export function describeValue(value: unknown, maxLength: number = MAX_LOG_LINE_LENGTH): string {
  let text: string;
  if (typeof value === 'string') {
    text = value;
  } else if (typeof value === 'function') {
    text = '[function]';
  } else if (value instanceof Error) {
    text = `${value.name}: ${value.message}`;
  } else {
    try {
      text = JSON.stringify(value, (_, inner) => (typeof inner === 'function' ? '[function]' : inner)) ?? String(value);
    } catch {
      text = String(value);
    }
  }
  return text.length > maxLength ? `${text.slice(0, maxLength)}… (${text.length - maxLength} more characters)` : text;
}

export function createPhotoApi(context: ScriptContext): PhotoApi {
  let draft = context.state;
  let lastCommitted: EditingState | null = null;
  const logs: string[] = [];
  const defaults = context.info.defaults;

  const analysis = (): ImageAnalysis => {
    if (!context.analysis) throw new Error('The photo has not been rendered yet, so there is nothing to measure. Try again in a moment.');
    return context.analysis;
  };

  const log = (...values: unknown[]): void => {
    if (logs.length === MAX_LOG_LINES) logs.push('… further log lines were dropped');
    if (logs.length > MAX_LOG_LINES) return;
    logs.push(values.map((value) => describeValue(value)).join(' '));
  };

  const document = {
    getState: () => ({ revision: context.revision, ...cloneState(draft) }),
    getMetadata: () => {
      const { defaults: _defaults, ...metadata } = context.info;
      return copy(metadata);
    },
    getHistogram: () => copy(analysis().histogram),
    getStatistics: () => copy(analysis().statistics),
    adjust: (settings: unknown): void => {
      draft = adjustGlobal(draft, settings);
    },
    curves: Object.freeze({
      set: (channel: unknown, points: unknown): void => {
        draft = setCurve(draft, channel, points);
      },
      get: (channel: unknown) => copy(draft.curves[oneOf<CurveChannel>('curve channel', channel, CURVE_CHANNELS)]),
      reset: (channel?: unknown): void => {
        const identity = [
          [0, 0],
          [1, 1],
        ];
        if (channel === undefined) draft = resetSection(draft, 'curves', defaults);
        else draft = setCurve(draft, channel, identity);
      },
    }),
    hsl: Object.freeze({
      adjust: (color: unknown, adjustments: unknown): void => {
        draft = adjustHSL(draft, color, adjustments);
      },
      get: (color: unknown) => copy(draft.hsl[oneOf<ColorRange>('hsl colour', color, COLOR_RANGES)]),
      reset: (color?: unknown): void => {
        if (color === undefined) draft = resetSection(draft, 'hsl', defaults);
        else draft = adjustHSL(draft, color, { hue: 0, saturation: 0, luminance: 0 });
      },
    }),
    grading: Object.freeze({
      set: (range: unknown, settings: unknown): void => {
        draft = setGrading(draft, range, settings);
      },
      get: (range: unknown) => copy(draft.grading[oneOf<GradingRange>('grading range', range, GRADING_RANGES)]),
      configure: (settings: unknown): void => {
        draft = setGradingMix(draft, settings);
      },
      reset: (): void => {
        draft = resetSection(draft, 'grading', defaults);
      },
    }),
    detail: Object.freeze({
      set: (settings: unknown): void => {
        draft = setDetail(draft, settings);
      },
      get: () => copy(draft.detail),
    }),
    crop: (settings: unknown): void => {
      draft = setCrop(draft, settings);
    },
    reset: (section: unknown = 'all'): void => {
      draft = resetSection(draft, section, defaults);
    },
    commit: (): void => {
      lastCommitted = draft;
    },
  };

  return {
    globals: {
      photo: Object.freeze({ current: Object.freeze(document) }),
      console: Object.freeze({ log, info: log, warn: log, error: log, debug: log }),
    },
    committed: () => lastCommitted,
    hasUncommittedChanges: () => !statesEqual(draft, lastCommitted ?? context.state),
    logs: () => logs,
  };
}
