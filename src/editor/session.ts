/**
 * One photo open in the editor: its settings, revision, history and latest rendering.
 *
 * The sliders, undo/redo and the agent's scripts all change the photo through this class, so there
 * is one editing path. It knows nothing about React or the native renderer: both are plugged in.
 */

import type { PhotoInfo } from '@/engine/photo';
import { defaultState, statesEqual, type EditingState, type StateChange } from '@/engine/state';
import type { ImageAnalysis } from '@/engine/stats';
import { executeEditScript, type ExecuteOptions, type ExecuteRequest, type ScriptOutcome } from '@/script/execute';

export type RenderPurpose = 'preview' | 'drag' | 'agent' | 'export' | 'original' | 'thumbnail';

export interface RenderRequest {
  purpose: RenderPurpose;
  /** Show the whole frame, ignoring the crop rectangle (the crop tool). */
  fullFrame?: boolean;
  /** Long edge in pixels, for the purposes that take one. */
  maxEdge?: number;
  format?: 'jpeg' | 'heic';
}

export interface RenderedFrame {
  uri: string;
  width: number;
  height: number;
  /** Measurements of this frame, when the purpose asks for them. */
  analysis: ImageAnalysis | null;
}

export interface Renderer {
  render(state: EditingState, request: RenderRequest): Promise<RenderedFrame>;
}

export type EditSource = 'open' | 'manual' | 'assistant' | 'restore';

export interface HistoryEntry {
  id: number;
  state: EditingState;
  /** A short description, e.g. "Exposure" or the assistant's script. */
  label: string;
  source: EditSource;
  /** The instruction this edit belongs to, for edits made by the assistant. */
  runId?: string;
  script?: string;
  changes: StateChange[];
}

export interface EditorSnapshot {
  state: EditingState;
  revision: number;
  canUndo: boolean;
  canRedo: boolean;
  /** The latest rendering of `state`, or of a slightly older state while a new one is on its way. */
  frame: RenderedFrame | null;
  analysis: ImageAnalysis | null;
  rendering: boolean;
  renderError: string | null;
  fullFrame: boolean;
  history: HistoryEntry[];
  /** Index in `history` of the entry that is current. */
  position: number;
}

export interface ScriptRun {
  outcome: ScriptOutcome;
  revision: number;
  analysis: ImageAnalysis | null;
}

export interface SessionOptions {
  id: string;
  info: PhotoInfo;
  renderer: Renderer;
  /** Saved settings to resume from. */
  state?: EditingState;
  revision?: number;
  /** Called after every committed change, to save it. */
  onCommit?: (state: EditingState, revision: number) => void;
}

const MAX_HISTORY = 100;

export class EditorSession {
  readonly id: string;
  readonly info: PhotoInfo;
  private readonly renderer: Renderer;
  private readonly onCommit?: (state: EditingState, revision: number) => void;

  private state: EditingState;
  private revision: number;
  private history: HistoryEntry[];
  private position = 0;
  private nextEntryId = 1;
  /** True between the first change of a gesture and its commit. */
  private gestureOpen = false;

  private frame: RenderedFrame | null = null;
  private analysis: ImageAnalysis | null = null;
  /** The state `analysis` was measured on. */
  private analysedState: EditingState | null = null;
  private renderError: string | null = null;
  private fullFrame = false;
  private rendering = false;
  private renderQueued = false;
  private dragging = false;
  private idleWaiters: (() => void)[] = [];
  private closed = false;

  private listeners = new Set<() => void>();
  private snapshot: EditorSnapshot | null = null;

  constructor(options: SessionOptions) {
    this.id = options.id;
    this.info = options.info;
    this.renderer = options.renderer;
    this.onCommit = options.onCommit;
    this.state = options.state ?? defaultState(options.info.defaults);
    this.revision = options.revision ?? 1;
    this.history = [{ id: 0, state: this.state, label: 'open', source: 'open', changes: [] }];
    this.requestRender();
  }

  // --- Reading -----------------------------------------------------------

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getSnapshot = (): EditorSnapshot => {
    if (!this.snapshot) {
      this.snapshot = {
        state: this.state,
        revision: this.revision,
        canUndo: this.position > 0,
        canRedo: this.position < this.history.length - 1,
        frame: this.frame,
        analysis: this.analysis,
        rendering: this.rendering,
        renderError: this.renderError,
        fullFrame: this.fullFrame,
        history: this.history,
        position: this.position,
      };
    }
    return this.snapshot;
  };

  private notify(): void {
    this.snapshot = null;
    for (const listener of this.listeners) listener();
  }

  // --- Manual editing ----------------------------------------------------

  /**
   * Changes the settings without ending the gesture: for a slider that is still being dragged.
   * Call `commit` when the finger lifts. The revision moves on at the first change of a gesture, so
   * a script written against the earlier revision is refused instead of overwriting the person.
   */
  update(change: (state: EditingState) => EditingState): void {
    const next = change(this.state);
    if (next === this.state) return;
    if (!this.gestureOpen) {
      this.gestureOpen = true;
      this.revision++;
    }
    this.state = next;
    this.dragging = true;
    this.requestRender();
    this.notify();
  }

  /** Ends a gesture: the current settings become one undo step. */
  commit(label: string): void {
    this.dragging = false;
    if (!this.gestureOpen) return;
    this.gestureOpen = false;
    const previous = this.history[this.position].state;
    if (statesEqual(previous, this.state)) {
      this.state = previous;
    } else {
      // Anyone who looked at the photo mid-gesture saw settings that were still moving.
      this.revision++;
      this.push({ state: this.state, label, source: 'manual', changes: [] });
      this.onCommit?.(this.state, this.revision);
    }
    this.requestRender();
    this.notify();
  }

  /** A complete change in one step: for buttons and anything that is not a drag. */
  change(change: (state: EditingState) => EditingState, label: string): void {
    this.update(change);
    this.commit(label);
  }

  private push(entry: Omit<HistoryEntry, 'id'>): void {
    this.history = [...this.history.slice(0, this.position + 1), { ...entry, id: this.nextEntryId++ }];
    if (this.history.length > MAX_HISTORY) this.history = this.history.slice(this.history.length - MAX_HISTORY);
    this.position = this.history.length - 1;
  }

  private moveTo(position: number): void {
    if (position < 0 || position >= this.history.length || position === this.position) return;
    this.closeGesture();
    this.position = position;
    this.state = this.history[position].state;
    this.revision++;
    this.onCommit?.(this.state, this.revision);
    this.requestRender();
    this.notify();
  }

  private closeGesture(): void {
    if (this.gestureOpen) this.commit('edit');
  }

  undo(): void {
    this.closeGesture();
    this.moveTo(this.position - 1);
  }

  redo(): void {
    this.moveTo(this.position + 1);
  }

  /**
   * Takes the photo back to how it was before one of the assistant's instructions, as a new undo
   * step (so the revert itself can be undone). Returns false when there is nothing to revert.
   */
  revertRun(runId: string): boolean {
    this.closeGesture();
    const first = this.history.findIndex((entry) => entry.runId === runId);
    if (first <= 0) return false;
    const before = this.history[first - 1].state;
    if (statesEqual(before, this.state)) return false;
    this.state = before;
    this.revision++;
    this.push({ state: before, label: 'revert', source: 'restore', changes: [] });
    this.onCommit?.(this.state, this.revision);
    this.requestRender();
    this.notify();
    return true;
  }

  /** Whether reverting this instruction would change the photo: its edits were applied and are still in effect. */
  canRevertRun(runId: string): boolean {
    const first = this.history.findIndex((entry, index) => index <= this.position && entry.runId === runId);
    return first > 0 && !statesEqual(this.history[first - 1].state, this.state);
  }

  setFullFrame(fullFrame: boolean): void {
    if (this.fullFrame === fullFrame) return;
    this.fullFrame = fullFrame;
    this.requestRender();
    this.notify();
  }

  // --- Scripts -----------------------------------------------------------

  /**
   * Runs an edit script as one transaction. On success the committed settings become current, as
   * one undo step, and the photo is rendered again before this resolves, so the returned analysis
   * describes the result.
   */
  async runScript(request: ExecuteRequest, run: { runId: string }, options: ExecuteOptions = {}): Promise<ScriptRun> {
    // A control that is still being dragged counts as a finished manual edit: the script is then
    // judged against the revision that edit produced.
    this.closeGesture();
    // Scripts read statistics, so they must describe the photo as it is now.
    const analysis = await this.measure();
    const environment = { sessionId: this.id, revision: this.revision, state: this.state, info: this.info, analysis };
    const outcome = executeEditScript(environment, request, options);
    if (outcome.status === 'ok' && outcome.changed) {
      this.state = outcome.state;
      this.revision++;
      this.push({
        state: outcome.state,
        label: 'assistant',
        source: 'assistant',
        runId: run.runId,
        script: typeof request.code === 'string' ? request.code : undefined,
        changes: outcome.changes,
      });
      this.onCommit?.(this.state, this.revision);
      this.requestRender();
      this.notify();
    }
    return { outcome, revision: this.revision, analysis: await this.measure() };
  }

  /**
   * Measurements of the photo with its current settings, waiting for or making a rendering as
   * needed. Null only when rendering fails.
   */
  async measure(): Promise<ImageAnalysis | null> {
    await this.settled();
    const state = this.state;
    if (this.analysedState === state) return this.analysis;
    try {
      // The on-screen preview did not measure these settings (the crop tool shows the whole frame).
      const frame = await this.renderer.render(state, { purpose: 'agent' });
      if (frame.analysis) {
        this.analysis = frame.analysis;
        this.analysedState = state;
        this.notify();
        return frame.analysis;
      }
    } catch {
      // Reported through the on-screen preview's own error.
    }
    return null;
  }

  // --- Rendering ---------------------------------------------------------

  /** Resolves once the preview on screen shows the current settings. */
  settled(): Promise<void> {
    if (!this.rendering && !this.renderQueued) return Promise.resolve();
    return new Promise((resolve) => this.idleWaiters.push(resolve));
  }

  /** Renders the current settings for a purpose other than the on-screen preview. */
  renderOnce(request: RenderRequest): Promise<RenderedFrame> {
    return this.renderer.render(this.state, request);
  }

  /** Renders the photo as opened, for the before/after comparison. */
  renderOriginal(): Promise<RenderedFrame> {
    // Keep the geometry so the comparison lines up with the edited photo.
    const original = { ...defaultState(this.info.defaults), crop: this.state.crop };
    return this.renderer.render(original, { purpose: 'original', fullFrame: this.fullFrame });
  }

  private requestRender(): void {
    if (this.closed) return;
    if (this.rendering) {
      this.renderQueued = true;
      return;
    }
    void this.renderLoop();
  }

  private async renderLoop(): Promise<void> {
    this.rendering = true;
    this.notify();
    do {
      this.renderQueued = false;
      const state = this.state;
      const fullFrame = this.fullFrame;
      try {
        const frame = await this.renderer.render(state, { purpose: this.dragging ? 'drag' : 'preview', fullFrame });
        if (this.closed) break;
        this.frame = frame;
        this.renderError = null;
        if (frame.analysis && !fullFrame) {
          this.analysis = frame.analysis;
          this.analysedState = state;
        }
      } catch (error) {
        this.renderError = error instanceof Error ? error.message : String(error);
      }
      // A drag renders small and fast; once it ends, render the same settings once more at full preview size.
      if (!this.renderQueued && (state !== this.state || fullFrame !== this.fullFrame)) this.renderQueued = true;
      this.notify();
    } while (this.renderQueued && !this.closed);
    this.rendering = false;
    const waiters = this.idleWaiters;
    this.idleWaiters = [];
    for (const resolve of waiters) resolve();
    this.notify();
  }

  close(): void {
    this.closed = true;
    this.listeners.clear();
    const waiters = this.idleWaiters;
    this.idleWaiters = [];
    for (const resolve of waiters) resolve();
  }
}
