/**
 * The assistant for one open photo: takes an instruction, runs the agent, and keeps the transcript
 * the editor shows. One instruction is one "run"; its scripts can be reverted together.
 */

import { runAgentTurn, type AgentEvent } from '@/agent/agent';
import type { BudgetScope } from '@/agent/cost';
import { createOpenRouterClient, OpenRouterError, type ChatMessage } from '@/agent/openrouter';
import type { StateChange } from '@/engine/state';
import type { StringKey } from '@/i18n';
import { accountStore, activeModel, budgetFor, recordUsage, refreshKeyInfo, spentOnRun } from '@/platform/account';
import { createStore, type Store } from '@/platform/store';
import { createAgentPort, type ReadBase64 } from './agentPort';
import type { EditorSession } from './session';

export type ScriptState = 'running' | 'applied' | 'unchanged' | 'failed' | 'stale';

export type TranscriptItem =
  | { kind: 'user'; id: string; runId: string; text: string }
  | { kind: 'assistant'; id: string; runId: string; text: string }
  | { kind: 'script'; id: string; runId: string; code: string; state: ScriptState; changes: StateChange[]; error?: string; logs: string[] }
  | { kind: 'notice'; id: string; runId: string; tone: 'info' | 'error'; message: StringKey; values?: Record<string, string>; detail?: string };

export interface AssistantState {
  items: TranscriptItem[];
  /** The run in progress, if any. */
  activeRun: string | null;
  status: 'idle' | 'thinking' | 'running';
  /** What each run cost, in US dollars. */
  costs: Record<string, number>;
}

const BUDGET_MESSAGES: Record<BudgetScope, StringKey> = {
  perRequest: 'assistant.limitRequest',
  perDay: 'assistant.limitDay',
  perMonth: 'assistant.limitMonth',
};

const ERROR_MESSAGES: Record<OpenRouterError['kind'], StringKey> = {
  unauthorized: 'assistant.errorKey',
  payment: 'assistant.errorCredits',
  rate_limit: 'assistant.errorRate',
  network: 'assistant.errorNetwork',
  server: 'assistant.errorServer',
  bad_request: 'assistant.errorRequest',
  invalid_response: 'assistant.errorServer',
};

let nextId = 1;
const newId = (prefix: string): string => `${prefix}-${Date.now().toString(36)}-${nextId++}`;

export class Assistant {
  readonly store: Store<AssistantState> = createStore<AssistantState>({ items: [], activeRun: null, status: 'idle', costs: {} });
  /** What the model has been told so far. Lives as long as the photo is open. */
  private conversation: ChatMessage[] = [];
  private abort: AbortController | null = null;

  constructor(
    private readonly session: EditorSession,
    private readonly readBase64: ReadBase64,
  ) {}

  private add(item: TranscriptItem): void {
    this.store.set((current) => ({ ...current, items: [...current.items, item] }));
  }

  private handle(runId: string, event: AgentEvent): void {
    switch (event.type) {
      case 'status':
        this.store.set((current) => ({ ...current, status: event.status }));
        break;
      case 'text':
        this.add({ kind: 'assistant', id: newId('a'), runId, text: event.text });
        break;
      case 'script_started':
        this.add({ kind: 'script', id: event.callId, runId, code: event.code, state: 'running', changes: [], logs: [] });
        break;
      case 'script_finished': {
        const { payload } = event;
        const state: ScriptState =
          payload.status === 'stale_revision' ? 'stale' : payload.status !== 'ok' ? 'failed' : payload.applied ? 'applied' : 'unchanged';
        this.store.set((current) => ({
          ...current,
          items: current.items.map((item) =>
            item.kind === 'script' && item.id === event.callId
              ? { ...item, state, changes: payload.changes, logs: payload.logs, error: payload.error?.message }
              : item,
          ),
        }));
        break;
      }
    }
  }

  /** Sends an instruction to the assistant. Resolves when the run has ended, however it ended. */
  async send(instruction: string): Promise<void> {
    const text = instruction.trim();
    const account = accountStore.get();
    if (!text || this.abort || !account.apiKey) return;
    const runId = newId('run');
    const abort = new AbortController();
    this.abort = abort;
    this.add({ kind: 'user', id: newId('u'), runId, text });
    this.store.set((current) => ({ ...current, activeRun: runId, status: 'thinking' }));
    const note = (tone: 'info' | 'error', message: StringKey, values?: Record<string, string>, detail?: string) =>
      this.add({ kind: 'notice', id: newId('n'), runId, tone, message, values, detail });

    try {
      const first = budgetFor(runId);
      if (!first.ok) {
        note('error', BUDGET_MESSAGES[first.scope], { limit: first.limit.toFixed(2) });
        return;
      }
      const result = await runAgentTurn({
        client: createOpenRouterClient(account.apiKey),
        model: activeModel(account),
        port: createAgentPort(this.session, runId, this.readBase64),
        conversation: this.conversation,
        instruction: text,
        budget: () => budgetFor(runId),
        onUsage: (usage, model) => {
          recordUsage(usage, model, runId, this.session.id);
          this.store.set((current) => ({ ...current, costs: { ...current.costs, [runId]: spentOnRun(runId) } }));
        },
        onEvent: (event) => this.handle(runId, event),
        signal: abort.signal,
      });
      if (result.stop === 'cancelled') note('info', 'assistant.stopped');
      else if (result.stop === 'budget' && result.budget && !result.budget.ok) note('error', BUDGET_MESSAGES[result.budget.scope], { limit: result.budget.limit.toFixed(2) });
      else if (result.stop === 'step_limit' && !result.text) note('info', 'assistant.stepLimit');
    } catch (error) {
      if (error instanceof OpenRouterError) note('error', ERROR_MESSAGES[error.kind], undefined, error.message);
      else note('error', 'assistant.errorUnknown', undefined, error instanceof Error ? error.message : String(error));
    } finally {
      // A script that was still marked as running when the run ended never finished.
      this.store.set((current) => ({
        ...current,
        activeRun: null,
        status: 'idle',
        items: current.items.map((item) => (item.kind === 'script' && item.state === 'running' ? { ...item, state: 'failed' as const } : item)),
      }));
      this.abort = null;
      void refreshKeyInfo();
    }
  }

  cancel(): void {
    this.abort?.abort();
  }

  /** Undoes everything the assistant did for one instruction. */
  revert(runId: string): boolean {
    return this.session.revertRun(runId);
  }

  close(): void {
    this.cancel();
  }
}
