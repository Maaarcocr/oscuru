import { runAgentTurn, dropOldImages, type AgentEvent } from '@/agent/agent';
import type { BudgetCheck } from '@/agent/cost';
import { OpenRouterError, type ChatMessage, type ChatRequest, type ChatResponse, type OpenRouterClient } from '@/agent/openrouter';
import { TOOL_NAME } from '@/agent/prompt';
import type { PhotoInfo } from '@/engine/photo';
import { adjustGlobal, defaultState, type EditingState } from '@/engine/state';
import { analyzePixels } from '@/engine/stats';
import { createAgentPort } from '../agentPort';
import { EditorSession, type RenderRequest, type Renderer } from '../session';

const info: PhotoInfo = {
  fileName: 'IMG_0001.DNG',
  typeIdentifier: 'com.adobe.raw-image',
  isRaw: true,
  width: 4000,
  height: 3000,
  asShot: { temperature: 5200, tint: 8 },
  defaults: { temperature: 5200, tint: 8, sharpening: 40, noiseReduction: 50, colorNoiseReduction: 50 },
};

/** A stand-in renderer: the "photo" is one flat grey whose brightness follows the exposure setting. */
function fakeRenderer() {
  const requests: { state: EditingState; request: RenderRequest }[] = [];
  let gate: Promise<void> | null = null;
  let counter = 0;
  const renderer: Renderer = {
    async render(state, request) {
      requests.push({ state, request });
      if (gate) await gate;
      const level = Math.max(0, Math.min(255, Math.round(120 * 2 ** state.global.exposureEV)));
      const pixels = new Uint8Array(4 * 4 * 4);
      for (let i = 0; i < 16; i++) pixels.set([level, level, level, 255], i * 4);
      const measured = request.purpose !== 'original' && request.purpose !== 'export' && request.purpose !== 'thumbnail';
      return { uri: `file:///renders/${request.purpose}-${++counter}.jpg`, width: 400, height: 300, analysis: measured ? analyzePixels(pixels, 4, 4) : null };
    },
  };
  return {
    renderer,
    requests,
    /** Makes renders wait until the returned function is called. */
    hold(): () => void {
      let release!: () => void;
      gate = new Promise((resolve) => {
        release = resolve;
      });
      return () => {
        gate = null;
        release();
      };
    },
  };
}

function open(saved: { onCommit?: (state: EditingState, revision: number) => void } = {}) {
  const fake = fakeRenderer();
  const session = new EditorSession({ id: 'photo-1', info, renderer: fake.renderer, onCommit: saved.onCommit });
  return { session, ...fake };
}

const exposure = (value: number) => (state: EditingState) => adjustGlobal(state, { exposureEV: value });
const script = (code: string, baseRevision: number) => ({ sessionId: 'photo-1', baseRevision, code });

describe('editor session', () => {
  it('opens at the photo defaults and renders once', async () => {
    const { session, requests } = open();
    expect(session.getSnapshot().state).toEqual(defaultState(info.defaults));
    expect(session.getSnapshot().revision).toBe(1);
    await session.settled();
    const snapshot = session.getSnapshot();
    expect(requests).toHaveLength(1);
    expect(snapshot.frame?.uri).toContain('preview');
    expect(snapshot.analysis?.statistics.meanLuminance).toBeCloseTo(120 / 255, 2);
    expect(snapshot.rendering).toBe(false);
    expect(snapshot.canUndo).toBe(false);
  });

  it('treats a drag as one undo step and saves it once', async () => {
    const commits: number[] = [];
    const { session } = open({ onCommit: (_, revision) => commits.push(revision) });
    session.update(exposure(0.2));
    session.update(exposure(0.5));
    session.update(exposure(0.8));
    expect(session.getSnapshot().canUndo).toBe(false);
    session.commit('Exposure');
    const after = session.getSnapshot();
    expect(after.state.global.exposureEV).toBe(0.8);
    expect(after.history).toHaveLength(2);
    expect(after.canUndo).toBe(true);
    expect(commits).toEqual([after.revision]);
    session.undo();
    expect(session.getSnapshot().state.global.exposureEV).toBe(0);
    expect(session.getSnapshot().canRedo).toBe(true);
    session.redo();
    expect(session.getSnapshot().state.global.exposureEV).toBe(0.8);
    await session.settled();
  });

  it('gives every committed change a new revision, and a drag that ends where it began none', () => {
    const { session } = open();
    const revisions = [session.getSnapshot().revision];
    session.change(exposure(1), 'Exposure');
    revisions.push(session.getSnapshot().revision);
    session.undo();
    revisions.push(session.getSnapshot().revision);
    session.redo();
    revisions.push(session.getSnapshot().revision);
    expect(new Set(revisions).size).toBe(4);
    expect([...revisions].sort((a, b) => a - b)).toEqual(revisions);
    const history = session.getSnapshot().history.length;
    session.update(exposure(0.3));
    session.update(exposure(1));
    session.commit('Exposure');
    expect(session.getSnapshot().history).toHaveLength(history);
  });

  it('drops the redo branch when a new edit is made', () => {
    const { session } = open();
    session.change(exposure(1), 'Exposure');
    session.change(exposure(2), 'Exposure');
    session.undo();
    session.change(exposure(-1), 'Exposure');
    expect(session.getSnapshot().canRedo).toBe(false);
    expect(session.getSnapshot().history.map((entry) => entry.state.global.exposureEV)).toEqual([0, 1, -1]);
  });

  it('renders the latest settings only: renders in between are skipped', async () => {
    const { session, requests, hold } = open();
    await session.settled();
    requests.length = 0;
    const release = hold();
    session.update(exposure(0.1));
    session.update(exposure(0.2));
    session.update(exposure(0.3));
    session.commit('Exposure');
    release();
    await session.settled();
    expect(requests.map((entry) => entry.state.global.exposureEV)).toEqual([0.1, 0.3]);
    expect(requests[0].request.purpose).toBe('drag');
    expect(requests[1].request.purpose).toBe('preview');
    expect(session.getSnapshot().analysis?.statistics.meanLuminance).toBeCloseTo((120 * 2 ** 0.3) / 255, 1);
  });

  it('shows a rendering failure and recovers on the next render', async () => {
    const fake = fakeRenderer();
    let fail = true;
    const session = new EditorSession({
      id: 'photo-1',
      info,
      renderer: { render: (state, request) => (fail ? Promise.reject(new Error('decoder fell over')) : fake.renderer.render(state, request)) },
    });
    await session.settled();
    expect(session.getSnapshot().renderError).toBe('decoder fell over');
    fail = false;
    session.change(exposure(0.5), 'Exposure');
    await session.settled();
    expect(session.getSnapshot().renderError).toBeNull();
    expect(session.getSnapshot().frame).not.toBeNull();
  });

  it('applies a script as one undo step, rendered and measured before it reports back', async () => {
    const { session } = open();
    const run = await session.runScript(script('photo.current.adjust({ exposureEV: 1, contrast: 10 }); photo.current.commit();', 1), { runId: 'run-1' });
    expect(run.outcome.status).toBe('ok');
    expect(run.revision).toBe(2);
    expect(run.analysis?.statistics.meanLuminance).toBeCloseTo(240 / 255, 2);
    const snapshot = session.getSnapshot();
    expect(snapshot.state.global).toMatchObject({ exposureEV: 1, contrast: 10 });
    expect(snapshot.history).toHaveLength(2);
    expect(snapshot.history[1]).toMatchObject({ source: 'assistant', runId: 'run-1' });
    expect(snapshot.history[1].script).toContain('exposureEV: 1');
    session.undo();
    expect(session.getSnapshot().state.global).toMatchObject({ exposureEV: 0, contrast: 0 });
  });

  it('gives scripts statistics of the photo as it is now', async () => {
    const { session } = open();
    session.change(exposure(1), 'Exposure');
    const run = await session.runScript(script('return photo.current.getStatistics().meanLuminance;', session.getSnapshot().revision), { runId: 'run-1' });
    expect(Number(run.outcome.returnValue)).toBeCloseTo(240 / 255, 2);
  });

  it('refuses a script written before a manual change instead of overwriting it', async () => {
    const { session } = open();
    await session.settled();
    const seen = session.getSnapshot().revision;
    session.change(exposure(0.7), 'Exposure');
    const run = await session.runScript(script('photo.current.adjust({ exposureEV: -2 }); photo.current.commit();', seen), { runId: 'run-1' });
    expect(run.outcome.status).toBe('stale_revision');
    expect(session.getSnapshot().state.global.exposureEV).toBe(0.7);
    expect(run.revision).toBe(session.getSnapshot().revision);
  });

  it('refuses a script that arrives while a slider is still moving', async () => {
    const { session } = open();
    await session.settled();
    const seen = session.getSnapshot().revision;
    session.update(exposure(0.4));
    const run = await session.runScript(script('photo.current.adjust({ exposureEV: -2 }); photo.current.commit();', seen), { runId: 'run-1' });
    expect(run.outcome.status).toBe('stale_revision');
    expect(session.getSnapshot().state.global.exposureEV).toBe(0.4);
  });

  it('leaves the photo alone when a script fails', async () => {
    const { session } = open();
    const run = await session.runScript(script('photo.current.adjust({ contrast: 10 }); photo.current.commit(); throw new Error("no");', 1), { runId: 'run-1' });
    expect(run.outcome.status).toBe('error');
    expect(run.revision).toBe(1);
    expect(session.getSnapshot().history).toHaveLength(1);
  });

  it('reverts everything one instruction did, as a step that can itself be undone', async () => {
    const { session } = open();
    session.change(exposure(0.5), 'Exposure');
    let revision = session.getSnapshot().revision;
    revision = (await session.runScript(script('photo.current.adjust({ contrast: 20 }); photo.current.commit();', revision), { runId: 'run-1' })).revision;
    await session.runScript(script('photo.current.adjust({ saturation: 15 }); photo.current.commit();', revision), { runId: 'run-1' });
    expect(session.canRevertRun('run-1')).toBe(true);
    expect(session.revertRun('run-1')).toBe(true);
    expect(session.canRevertRun('run-1')).toBe(false);
    expect(session.getSnapshot().state.global).toMatchObject({ exposureEV: 0.5, contrast: 0, saturation: 0 });
    session.undo();
    expect(session.getSnapshot().state.global).toMatchObject({ contrast: 20, saturation: 15 });
    expect(session.canRevertRun('run-1')).toBe(true);
    expect(session.revertRun('unknown')).toBe(false);
    expect(session.canRevertRun('unknown')).toBe(false);
  });

  it('measures the cropped photo even while the crop tool shows the whole frame', async () => {
    const { session, requests } = open();
    session.setFullFrame(true);
    await session.settled();
    expect(requests.at(-1)?.request.fullFrame).toBe(true);
    session.change(exposure(1), 'Exposure');
    const analysis = await session.measure();
    expect(analysis?.statistics.meanLuminance).toBeCloseTo(240 / 255, 2);
    expect(requests.at(-1)?.request).toMatchObject({ purpose: 'agent' });
  });

  it('renders the original with the current crop for the comparison', async () => {
    const { session, requests } = open();
    session.change((state) => ({ ...adjustGlobal(state, { exposureEV: 2 }), crop: { ...state.crop, rotation: 90 } }), 'edit');
    await session.renderOriginal();
    const last = requests.find((entry) => entry.request.purpose === 'original');
    expect(last).toBeDefined();
    expect(last?.state.global.exposureEV).toBe(0);
    expect(last?.state.crop.rotation).toBe(90);
  });
});

// ---------------------------------------------------------------------------

type Reply = { text?: string; code?: string; baseRevision?: number; raw?: Partial<ChatResponse['message']>; cost?: number };

/** A model that plays back prepared replies and records what it was sent. */
function fakeModel(replies: (Reply | ((request: ChatRequest) => Reply) | Error)[]) {
  const requests: ChatRequest[] = [];
  let call = 0;
  const client: OpenRouterClient = {
    async chat(request, signal) {
      requests.push(JSON.parse(JSON.stringify(request)) as ChatRequest);
      if (signal?.aborted) throw Object.assign(new Error('Aborted'), { name: 'AbortError' });
      const next = replies[call++];
      if (!next) throw new Error('the fake model ran out of replies');
      if (next instanceof Error) throw next;
      const reply = typeof next === 'function' ? next(request) : next;
      const id = `call-${call}`;
      return {
        id: `gen-${call}`,
        model: request.model,
        finishReason: reply.code ? 'tool_calls' : 'stop',
        usage: { prompt_tokens: 1000, completion_tokens: 100, total_tokens: 1100, cost: reply.cost ?? 0.01 },
        message: {
          role: 'assistant',
          content: reply.text ?? null,
          ...(reply.code ? { tool_calls: [{ id, type: 'function' as const, function: { name: TOOL_NAME, arguments: JSON.stringify({ sessionId: 'photo-1', baseRevision: reply.baseRevision, code: reply.code }) } }] } : {}),
          ...reply.raw,
        },
      };
    },
  };
  return { client, requests };
}

/** Reads the revision the model was last told about, the way a real model would. */
function latestRevision(request: ChatRequest): number {
  for (let index = request.messages.length - 1; index >= 0; index--) {
    const message = request.messages[index];
    const text = typeof message.content === 'string' ? message.content : (message.content ?? []).map((part) => (part.type === 'text' ? part.text : '')).join('');
    const match = /"revision":(\d+)/.exec(text);
    if (match) return Number(match[1]);
  }
  throw new Error('no revision in the conversation');
}

function setUp(replies: Parameters<typeof fakeModel>[0], budget: () => BudgetCheck = () => ({ ok: true })) {
  const { session } = open();
  const model = fakeModel(replies);
  const events: AgentEvent[] = [];
  const conversation: ChatMessage[] = [];
  const usage: number[] = [];
  const abort = new AbortController();
  const turn = (instruction: string, runId = 'run-1') =>
    runAgentTurn({
      client: model.client,
      model: 'anthropic/claude-sonnet-5.5',
      port: createAgentPort(session, runId, async (uri) => `BASE64(${uri})`),
      conversation,
      instruction,
      budget,
      onUsage: (entry) => usage.push(entry.cost ?? 0),
      onEvent: (event) => events.push(event),
      signal: abort.signal,
      maxScripts: 3,
    });
  return { session, ...model, events, conversation, usage, abort, turn };
}

const images = (message: ChatMessage): number => (Array.isArray(message.content) ? message.content.filter((part) => part.type === 'image_url').length : 0);

describe('agent turn', () => {
  it('shows the model the photo, runs its script on the phone, shows the result, and relays its note', async () => {
    const test = setUp([
      (request) => ({ text: 'Opening the shadows.', code: 'photo.current.adjust({ exposureEV: 0.5, shadows: 20 }); photo.current.commit();', baseRevision: latestRevision(request) }),
      { text: 'Lifted the exposure by half a stop and opened the shadows.' },
    ]);
    const result = await test.turn('Brighten it a little');

    expect(result).toEqual({ stop: 'done', text: 'Lifted the exposure by half a stop and opened the shadows.', scripts: 1 });
    expect(test.session.getSnapshot().state.global).toMatchObject({ exposureEV: 0.5, shadows: 20 });
    expect(test.usage).toEqual([0.01, 0.01]);

    // First request: system prompt with the API, then the instruction with context and a preview.
    const first = test.requests[0];
    expect(first.messages[0].role).toBe('system');
    expect(first.messages[0].content).toContain('interface PhotoDocument');
    expect(first.tools?.[0].function.name).toBe(TOOL_NAME);
    expect(first.tools).toHaveLength(1);
    expect(first.parallel_tool_calls).toBe(false);
    expect(first.cache_control).toEqual({ type: 'ephemeral' });
    const user = first.messages[1].content as { type: string; text?: string; image_url?: { url: string } }[];
    expect(user[0].text).toContain('Brighten it a little');
    expect(user[0].text).toContain('"sessionId":"photo-1"');
    expect(user[0].text).toContain('"isRaw":true');
    expect(user[0].text).not.toContain('"defaults"');
    expect(user[1].image_url?.url).toMatch(/^data:image\/jpeg;base64,BASE64\(file:\/\/\/renders\/agent-/);

    // Second request: the tool result as JSON, then the new preview as an image.
    const second = test.requests[1];
    const tool = second.messages.find((message) => message.role === 'tool');
    const payload = JSON.parse(tool?.content as string);
    expect(payload).toMatchObject({ status: 'ok', applied: true, revision: 2 });
    expect(payload.changes).toEqual([
      { path: 'global.exposureEV', from: 0, to: 0.5 },
      { path: 'global.shadows', from: 0, to: 20 },
    ]);
    expect(payload.statistics.meanLuminance).toBeGreaterThan(0.6);
    const last = second.messages.at(-1)!;
    expect(last.role).toBe('user');
    expect(images(last)).toBe(1);

    expect(test.events.map((event) => event.type)).toEqual(['status', 'text', 'status', 'script_started', 'script_finished', 'status', 'text']);
  });

  it('lets the model see a failed script and correct it', async () => {
    const test = setUp([
      (request) => ({ code: 'photo.current.adjust({ exposure: 1 }); photo.current.commit();', baseRevision: latestRevision(request) }),
      (request) => ({ code: 'photo.current.adjust({ exposureEV: 1 }); photo.current.commit();', baseRevision: latestRevision(request) }),
      { text: 'Done.' },
    ]);
    const result = await test.turn('One stop brighter');
    expect(result.scripts).toBe(2);
    expect(test.session.getSnapshot().state.global.exposureEV).toBe(1);
    const failure = JSON.parse(test.requests[1].messages.at(-1)!.content as string);
    expect(failure).toMatchObject({ status: 'error', applied: false, revision: 1 });
    expect(failure.error.message).toContain('no setting "exposure"');
    // A failed script changes nothing, so no new picture is sent.
    expect(test.requests[1].messages.at(-1)!.role).toBe('tool');
    expect(test.session.getSnapshot().history).toHaveLength(2);
  });

  it('tells the model when the person changed the photo meanwhile, with the new state and preview', async () => {
    const test = setUp([
      (request) => {
        // The person moves a slider while the model is thinking.
        test.session.change((state) => adjustGlobal(state, { contrast: 33 }), 'Contrast');
        return { code: 'photo.current.adjust({ contrast: -50 }); photo.current.commit();', baseRevision: latestRevision(request) };
      },
      (request) => ({ code: 'const { global } = photo.current.getState(); photo.current.adjust({ contrast: global.contrast + 5 }); photo.current.commit();', baseRevision: latestRevision(request) }),
      { text: 'Kept your contrast and added a touch more.' },
    ]);
    await test.turn('More contrast');
    expect(test.session.getSnapshot().state.global.contrast).toBe(38);
    const stale = test.requests[1].messages.find((message) => message.role === 'tool');
    const payload = JSON.parse(stale?.content as string);
    expect(payload.status).toBe('stale_revision');
    expect(payload.state.global.contrast).toBe(33);
    expect(images(test.requests[1].messages.at(-1)!)).toBe(1);
  });

  it('stops asking for scripts at the limit and lets the model close', async () => {
    const edit = (request: ChatRequest): Reply => ({ code: `photo.current.adjust({ contrast: ${request.messages.length} }); photo.current.commit();`, baseRevision: latestRevision(request) });
    const test = setUp([edit, edit, edit, { text: 'That is as far as I got.' }]);
    const result = await test.turn('Keep going');
    expect(result).toMatchObject({ stop: 'step_limit', scripts: 3, text: 'That is as far as I got.' });
    expect(test.requests[3].tool_choice).toBe('none');
    expect(test.requests[2].tool_choice).toBe('auto');
  });

  it('stops before the next request when the budget is spent, keeping the edits made', async () => {
    let spent = 0;
    const test = setUp(
      [(request) => ({ code: 'photo.current.adjust({ contrast: 10 }); photo.current.commit();', baseRevision: latestRevision(request), cost: 0.6 }), { text: 'never sent' }],
      () => (spent >= 0.5 ? { ok: false, scope: 'perRequest', spent, limit: 0.5 } : { ok: true }),
    );
    const turn = runAgentTurn({
      client: test.client,
      model: 'm',
      port: createAgentPort(test.session, 'run-1', async () => 'x'),
      conversation: test.conversation,
      instruction: 'Add contrast',
      budget: () => (spent >= 0.5 ? { ok: false, scope: 'perRequest', spent, limit: 0.5 } : { ok: true }),
      onUsage: (usage) => {
        spent += usage.cost ?? 0;
      },
      onEvent: () => undefined,
      signal: test.abort.signal,
    });
    const result = await turn;
    expect(result.stop).toBe('budget');
    expect(result.budget).toMatchObject({ ok: false, scope: 'perRequest', limit: 0.5 });
    expect(test.requests).toHaveLength(1);
    expect(test.session.getSnapshot().state.global.contrast).toBe(10);
  });

  it('does not send the caching hint to providers that do not use it', async () => {
    const test = setUp([{ text: 'Looks good already.' }]);
    await runAgentTurn({
      client: test.client,
      model: 'google/gemini-4-carbon',
      port: createAgentPort(test.session, 'run-1', async () => 'x'),
      conversation: test.conversation,
      instruction: 'Anything to fix?',
      budget: () => ({ ok: true }),
      onUsage: () => undefined,
      onEvent: () => undefined,
      signal: test.abort.signal,
    });
    expect(test.requests[0]).not.toHaveProperty('cache_control');
  });

  it('passes reasoning details back with the assistant message they came on', async () => {
    const details = [{ type: 'reasoning.encrypted', data: 'opaque' }];
    const test = setUp([
      (request) => ({ code: 'photo.current.adjust({ contrast: 5 }); photo.current.commit();', baseRevision: latestRevision(request), raw: { reasoning_details: details } }),
      { text: 'Done.' },
    ]);
    await test.turn('A bit more contrast');
    const assistant = test.requests[1].messages.find((message) => message.role === 'assistant');
    expect(assistant?.reasoning_details).toEqual(details);
  });

  it('answers a malformed tool call with an error the model can read', async () => {
    const test = setUp([
      { raw: { tool_calls: [{ id: 'c1', type: 'function', function: { name: 'render_preview', arguments: '{}' } }, { id: 'c2', type: 'function', function: { name: TOOL_NAME, arguments: '{not json' } }] } },
      { text: 'Sorry, nothing changed.' },
    ]);
    const result = await test.turn('Do something');
    expect(result.scripts).toBe(0);
    const tools = test.requests[1].messages.filter((message) => message.role === 'tool');
    expect(tools.map((message) => message.tool_call_id)).toEqual(['c1', 'c2']);
    expect(tools[0].content).toContain('Unknown tool');
    expect(tools[1].content).toContain('not valid JSON');
  });

  it('keeps the conversation going across instructions, with only the latest previews', async () => {
    const edit = (request: ChatRequest): Reply => ({ code: `photo.current.adjust({ contrast: ${request.messages.length} }); photo.current.commit();`, baseRevision: latestRevision(request) });
    const test = setUp([edit, { text: 'First done.' }, edit, { text: 'Second done.' }]);
    await test.turn('First', 'run-1');
    await test.turn('Second', 'run-2');
    const last = test.requests.at(-1)!;
    expect(last.messages.filter((message) => message.role === 'system')).toHaveLength(1);
    expect(last.messages.map(images).reduce((a, b) => a + b, 0)).toBe(2);
    expect(JSON.stringify(last.messages)).toContain('An earlier preview was here');
    expect(test.session.getSnapshot().history.map((entry) => entry.runId)).toEqual([undefined, 'run-1', 'run-2']);
  });

  it('cancels cleanly: the conversation is as before and the turn reports it', async () => {
    const test = setUp([
      (request) => {
        test.abort.abort();
        return { code: 'photo.current.adjust({ contrast: 10 }); photo.current.commit();', baseRevision: latestRevision(request) };
      },
    ]);
    const result = await test.turn('Add contrast');
    expect(result.stop).toBe('cancelled');
    expect(test.conversation).toEqual([]);
    expect(test.session.getSnapshot().state.global.contrast).toBe(0);
  });

  it('surfaces a refused key and leaves the conversation usable', async () => {
    const test = setUp([new OpenRouterError('unauthorized', 'No auth credentials found', 401), { text: 'Now it works.' }]);
    await expect(test.turn('Hello')).rejects.toMatchObject({ kind: 'unauthorized' });
    expect(test.conversation).toEqual([]);
    await expect(test.turn('Hello again')).resolves.toMatchObject({ stop: 'done', text: 'Now it works.' });
  });
});

describe('dropOldImages', () => {
  it('replaces all but the newest images with a note', () => {
    const image = (name: string): ChatMessage => ({ role: 'user', content: [{ type: 'text', text: name }, { type: 'image_url', image_url: { url: name } }] });
    const messages: ChatMessage[] = [image('a'), { role: 'assistant', content: 'ok' }, image('b'), image('c')];
    dropOldImages(messages, 2);
    expect(messages.map(images)).toEqual([0, 0, 1, 1]);
    expect((messages[0].content as { text: string }[])[1].text).toContain('removed to save space');
  });
});
