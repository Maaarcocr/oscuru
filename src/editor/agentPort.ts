/**
 * The phone's side of `execute_edit_script`: runs the script in the session, then reports the
 * result and a fresh preview back to the agent.
 */

import type { AgentContext, AgentPort, ToolExecution, ToolResultPayload } from '@/agent/agent';
import type { EditorSession, ScriptRun } from './session';

/** Reads a rendered file as base64. Supplied by the app, so this file stays free of native code. */
export type ReadBase64 = (uri: string) => Promise<string>;

export function buildToolPayload(run: ScriptRun, session: EditorSession): ToolResultPayload {
  const { outcome } = run;
  const payload: ToolResultPayload = {
    status: outcome.status,
    revision: run.revision,
    applied: outcome.changed,
    changes: outcome.changes,
    logs: outcome.logs,
    warnings: outcome.warnings,
    statistics: run.analysis?.statistics ?? null,
    diagnostics: { steps: outcome.steps, durationMs: outcome.durationMs },
  };
  if (outcome.returnValue !== undefined) payload.returnValue = outcome.returnValue;
  if (outcome.error) payload.error = outcome.error;
  if (outcome.status === 'stale_revision') payload.state = session.getSnapshot().state;
  return payload;
}

export function createAgentPort(session: EditorSession, runId: string, readBase64: ReadBase64): AgentPort {
  const preview = async (maxEdge: number): Promise<string | null> => {
    try {
      const frame = await session.renderOnce({ purpose: 'agent', maxEdge });
      return `data:image/jpeg;base64,${await readBase64(frame.uri)}`;
    } catch {
      return null;
    }
  };
  return {
    async context(): Promise<AgentContext> {
      const analysis = await session.measure();
      const snapshot = session.getSnapshot();
      const { defaults: _defaults, ...metadata } = session.info;
      return { sessionId: session.id, revision: snapshot.revision, state: snapshot.state, metadata, statistics: analysis?.statistics ?? null };
    },
    preview,
    async execute(request, signal): Promise<ToolExecution> {
      const run = await session.runScript(request, { runId }, { signal });
      const payload = buildToolPayload(run, session);
      // A new picture is only worth its cost when the photo differs from the last one the agent saw.
      const changed = payload.applied || payload.status === 'stale_revision';
      return { payload, preview: changed ? await preview(request.previewEdge) : null };
    },
  };
}
