/**
 * Runs one edit script as a transaction against a snapshot of the document.
 *
 * This is the whole of what `execute_edit_script` does before rendering: check the session and
 * revision, run the code in the sandbox, and either hand back the committed state with the list of
 * changes or report why nothing changed. It never touches the document itself.
 */

import { diffStates, parseState, type EditingState, type StateChange } from '@/engine/state';
import { runScript, ScriptError, type RunLimits } from './interpreter';
import { createPhotoApi, describeValue, type ScriptContext } from './photoApi';

export interface ExecuteRequest {
  sessionId: unknown;
  baseRevision: unknown;
  code: unknown;
}

export interface ScriptEnvironment extends ScriptContext {
  sessionId: string;
}

export type ScriptStatus = 'ok' | 'error' | 'stale_revision' | 'wrong_session' | 'invalid_request';

export interface ScriptFailure {
  /** Where it went wrong: syntax, unsupported, security, limit, aborted, runtime, thrown, or request. */
  kind: string;
  message: string;
  line?: number;
  column?: number;
}

export interface ScriptOutcome {
  status: ScriptStatus;
  /** True when the script committed and the committed settings differ from before. */
  changed: boolean;
  /** The state to make current. Only meaningful when `changed`. */
  state: EditingState;
  changes: StateChange[];
  logs: string[];
  returnValue?: string;
  warnings: string[];
  steps: number;
  durationMs: number;
  error?: ScriptFailure;
}

export interface ExecuteOptions {
  limits?: Partial<RunLimits>;
  signal?: { aborted: boolean };
}

const RETURN_VALUE_LIMIT = 2000;

export function executeEditScript(environment: ScriptEnvironment, request: ExecuteRequest, options: ExecuteOptions = {}): ScriptOutcome {
  const outcome: ScriptOutcome = {
    status: 'ok',
    changed: false,
    state: environment.state,
    changes: [],
    logs: [],
    warnings: [],
    steps: 0,
    durationMs: 0,
  };
  const fail = (status: ScriptStatus, error: ScriptFailure): ScriptOutcome => ({ ...outcome, status, error });

  if (typeof request.code !== 'string' || request.code.trim() === '') {
    return fail('invalid_request', { kind: 'request', message: 'code must be a non-empty string of JavaScript' });
  }
  if (typeof request.baseRevision !== 'number' || !Number.isInteger(request.baseRevision)) {
    return fail('invalid_request', { kind: 'request', message: 'baseRevision must be the integer revision the script was written against' });
  }
  if (request.sessionId !== environment.sessionId) {
    return fail('wrong_session', {
      kind: 'request',
      message: `sessionId ${describeValue(request.sessionId, 80)} is not the photo open in the editor (${environment.sessionId})`,
    });
  }
  if (request.baseRevision !== environment.revision) {
    return fail('stale_revision', {
      kind: 'request',
      message: `The photo is at revision ${environment.revision}, not ${request.baseRevision}: it changed since you last saw it (the person may have moved a control). Nothing was run. Look at the current state and preview, then send a script based on revision ${environment.revision}.`,
    });
  }

  const api = createPhotoApi(environment);
  try {
    const result = runScript(request.code, { globals: api.globals, limits: options.limits, signal: options.signal });
    outcome.steps = result.steps;
    outcome.durationMs = result.durationMs;
    if (result.value !== undefined) outcome.returnValue = describeValue(result.value, RETURN_VALUE_LIMIT);
  } catch (error) {
    outcome.logs = api.logs();
    if (error instanceof ScriptError) {
      return fail('error', { kind: error.kind, message: error.message, line: error.line, column: error.column });
    }
    return fail('error', { kind: 'runtime', message: error instanceof Error ? error.message : String(error) });
  }

  outcome.logs = api.logs();
  const committed = api.committed();
  if (api.hasUncommittedChanges()) {
    outcome.warnings.push(
      committed
        ? 'Changes made after the last commit() were discarded.'
        : 'The script changed settings but never called photo.current.commit(), so nothing was applied.',
    );
  }
  if (committed) {
    // The draft was built by validating setters, but check it once more as a whole before it becomes the document.
    const state = parseState(committed);
    const changes = diffStates(environment.state, state);
    if (changes.length > 0) {
      outcome.changed = true;
      outcome.state = state;
      outcome.changes = changes;
    } else {
      outcome.warnings.push('commit() was called but no setting differs from before.');
    }
  }
  return outcome;
}
