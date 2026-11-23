/**
 * The agent loop: one instruction from the person, any number of model requests and edit scripts.
 *
 * The model is remote; the photo never leaves the phone except as rendered previews. This loop is
 * the piece that would move to a server in a hosted setup: it only needs a model (`client`) and
 * the phone's side of the single tool (`port`), and knows nothing about rendering.
 */

import type { EditingState, StateChange } from '@/engine/state';
import type { ImageStatistics } from '@/engine/stats';
import type { ScriptFailure, ScriptStatus } from '@/script/execute';
import type { BudgetCheck } from './cost';
import { OpenRouterError, type ChatMessage, type ContentPart, type OpenRouterClient, type ToolCall, type Usage } from './openrouter';
import { DEFAULT_PREVIEW_EDGE, EDIT_TOOL, MAX_PREVIEW_EDGE, MIN_PREVIEW_EDGE, SYSTEM_PROMPT, TOOL_NAME } from './prompt';

/** What the tool reports back to the model, as JSON. The preview travels next to it as an image. */
export interface ToolResultPayload {
  status: ScriptStatus;
  /** The photo's revision after this call. */
  revision: number;
  /** True when the script's changes are now the photo's settings. */
  applied: boolean;
  changes: StateChange[];
  logs: string[];
  returnValue?: string;
  warnings: string[];
  error?: ScriptFailure;
  /** Statistics of the photo as it is now. */
  statistics: ImageStatistics | null;
  /** Current settings, included when the script was rejected as stale. */
  state?: EditingState;
  diagnostics: { steps: number; durationMs: number };
}

export interface ToolExecution {
  payload: ToolResultPayload;
  /** A `data:image/jpeg;base64,…` URL of the photo as it is now, or null when it could not be rendered. */
  preview: string | null;
}

export interface AgentContext {
  sessionId: string;
  revision: number;
  state: EditingState;
  metadata: Record<string, unknown>;
  statistics: ImageStatistics | null;
}

/** The phone's side of the conversation. */
export interface AgentPort {
  /** The photo as it is now, once any rendering in progress has finished. */
  context(): Promise<AgentContext>;
  preview(maxEdge: number): Promise<string | null>;
  execute(request: { sessionId: unknown; baseRevision: unknown; code: unknown; previewEdge: number }, signal: { aborted: boolean }): Promise<ToolExecution>;
}

export type AgentEvent =
  | { type: 'status'; status: 'thinking' | 'running' }
  | { type: 'text'; text: string }
  | { type: 'script_started'; callId: string; code: string }
  | { type: 'script_finished'; callId: string; payload: ToolResultPayload };

export type AgentStop = 'done' | 'budget' | 'step_limit' | 'cancelled';

export interface AgentTurnResult {
  stop: AgentStop;
  /** The assistant's closing note, when it wrote one. */
  text: string;
  scripts: number;
  budget?: BudgetCheck;
}

export interface AgentTurnOptions {
  client: OpenRouterClient;
  model: string;
  port: AgentPort;
  /** The running conversation. This turn's messages are appended; a failed or cancelled turn is removed again. */
  conversation: ChatMessage[];
  instruction: string;
  /** Asked before every model request. */
  budget: () => BudgetCheck;
  onUsage: (usage: Usage, model: string) => void;
  onEvent: (event: AgentEvent) => void;
  signal: AbortSignal;
  /** Most scripts one instruction may run. */
  maxScripts?: number;
  maxTokens?: number;
}

const KEPT_IMAGES = 2;
const REMOVED_IMAGE_NOTE = '[An earlier preview was here. It was removed to save space; the latest preview is further down.]';

function textOf(content: ChatMessage['content']): string {
  if (typeof content === 'string') return content;
  if (!content) return '';
  return content
    .filter((part): part is Extract<ContentPart, { type: 'text' }> => part.type === 'text')
    .map((part) => part.text)
    .join('');
}

/** Keeps only the most recent previews in the conversation: each one costs as much as a page of text. */
export function dropOldImages(messages: ChatMessage[], keep: number = KEPT_IMAGES): void {
  let seen = 0;
  for (let index = messages.length - 1; index >= 0; index--) {
    const message = messages[index];
    if (!Array.isArray(message.content) || !message.content.some((part) => part.type === 'image_url')) continue;
    seen++;
    if (seen > keep) {
      messages[index] = {
        ...message,
        content: message.content.map((part) => (part.type === 'image_url' ? { type: 'text', text: REMOVED_IMAGE_NOTE } : part)),
      };
    }
  }
}

function userMessage(instruction: string, context: AgentContext, preview: string | null): ChatMessage {
  const text = `${instruction.trim()}\n\n[Photo context]\n${JSON.stringify(context)}`;
  const content: ContentPart[] = [{ type: 'text', text }];
  if (preview) content.push({ type: 'image_url', image_url: { url: preview } });
  else content.push({ type: 'text', text: '[No preview could be rendered. Work from the statistics, and say so in your note.]' });
  return { role: 'user', content };
}

function parseArguments(call: ToolCall): { sessionId: unknown; baseRevision: unknown; code: unknown; previewEdge: number } | string {
  if (call.function.name !== TOOL_NAME) return `Unknown tool "${call.function.name}". The only tool is ${TOOL_NAME}.`;
  let parsed: unknown;
  try {
    parsed = JSON.parse(call.function.arguments || '{}');
  } catch {
    return 'The tool arguments were not valid JSON.';
  }
  if (typeof parsed !== 'object' || parsed === null) return 'The tool arguments must be an object.';
  const input = parsed as { sessionId?: unknown; baseRevision?: unknown; code?: unknown; preview?: { maxEdge?: unknown } };
  const requested = typeof input.preview?.maxEdge === 'number' && Number.isFinite(input.preview.maxEdge) ? input.preview.maxEdge : DEFAULT_PREVIEW_EDGE;
  return {
    sessionId: input.sessionId,
    baseRevision: input.baseRevision,
    code: input.code,
    previewEdge: Math.round(Math.min(MAX_PREVIEW_EDGE, Math.max(MIN_PREVIEW_EDGE, requested))),
  };
}

function isAbort(error: unknown, signal: AbortSignal): boolean {
  return signal.aborted || (error instanceof Error && error.name === 'AbortError');
}

/**
 * Carries out one instruction. Resolves when the model has finished, a limit stopped it, or the
 * person cancelled; rejects with `OpenRouterError` when the model could not be reached or refused.
 */
export async function runAgentTurn(options: AgentTurnOptions): Promise<AgentTurnResult> {
  const { client, model, port, conversation, signal, onEvent } = options;
  const maxScripts = options.maxScripts ?? 6;
  const turnStart = conversation.length;
  const scriptSignal = { aborted: false };
  const onAbort = () => {
    scriptSignal.aborted = true;
  };
  signal.addEventListener('abort', onAbort);

  let scripts = 0;
  let lastText = '';
  const cancelled = (): AgentTurnResult => {
    // Leave the conversation as it was: a half-finished exchange would confuse the next request.
    conversation.length = turnStart;
    return { stop: 'cancelled', text: lastText, scripts };
  };

  try {
    if (conversation.length === 0) conversation.push({ role: 'system', content: SYSTEM_PROMPT });
    const context = await port.context();
    const preview = await port.preview(DEFAULT_PREVIEW_EDGE);
    if (signal.aborted) return cancelled();
    conversation.push(userMessage(options.instruction, context, preview));

    for (;;) {
      const budget = options.budget();
      if (!budget.ok) return { stop: 'budget', text: lastText, scripts, budget };
      const outOfScripts = scripts >= maxScripts;

      dropOldImages(conversation);
      onEvent({ type: 'status', status: 'thinking' });
      const response = await client.chat(
        {
          model,
          messages: conversation,
          tools: [EDIT_TOOL],
          // Once the script allowance is used up, the model may only write its closing note.
          tool_choice: outOfScripts ? 'none' : 'auto',
          parallel_tool_calls: false,
          max_tokens: options.maxTokens ?? 6000,
          session_id: context.sessionId,
          ...(model.startsWith('anthropic/') ? { cache_control: { type: 'ephemeral' as const } } : {}),
        },
        signal,
      );
      if (response.usage) options.onUsage(response.usage, response.model);
      if (signal.aborted) return cancelled();

      const message = response.message;
      const calls = outOfScripts ? [] : (message.tool_calls ?? []);
      conversation.push({
        role: 'assistant',
        content: message.content ?? null,
        ...(calls.length > 0 ? { tool_calls: calls } : {}),
        ...(message.reasoning_details !== undefined ? { reasoning_details: message.reasoning_details } : {}),
      });
      const text = textOf(message.content).trim();
      if (text) {
        lastText = text;
        onEvent({ type: 'text', text });
      }
      if (calls.length === 0) {
        return { stop: outOfScripts ? 'step_limit' : 'done', text: lastText, scripts };
      }

      let latestPreview: string | null = null;
      let latestRevision = context.revision;
      for (const call of calls) {
        const parsed = parseArguments(call);
        if (typeof parsed === 'string') {
          conversation.push({ role: 'tool', tool_call_id: call.id, content: JSON.stringify({ status: 'invalid_request', applied: false, error: { kind: 'request', message: parsed } }) });
          continue;
        }
        scripts++;
        onEvent({ type: 'status', status: 'running' });
        onEvent({ type: 'script_started', callId: call.id, code: typeof parsed.code === 'string' ? parsed.code : '' });
        const execution = await port.execute(parsed, scriptSignal);
        onEvent({ type: 'script_finished', callId: call.id, payload: execution.payload });
        conversation.push({ role: 'tool', tool_call_id: call.id, content: JSON.stringify(execution.payload) });
        latestPreview = execution.preview;
        latestRevision = execution.payload.revision;
        if (signal.aborted) return cancelled();
      }
      if (latestPreview) {
        conversation.push({
          role: 'user',
          content: [
            { type: 'text', text: `[Preview of the photo at revision ${latestRevision}, rendered on the phone.]` },
            { type: 'image_url', image_url: { url: latestPreview } },
          ],
        });
      }
    }
  } catch (error) {
    if (isAbort(error, signal)) return cancelled();
    conversation.length = turnStart;
    if (error instanceof OpenRouterError) throw error;
    throw error instanceof Error ? error : new Error(String(error));
  } finally {
    signal.removeEventListener('abort', onAbort);
  }
}
