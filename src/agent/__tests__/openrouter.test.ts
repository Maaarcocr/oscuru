import { buildAuthUrl, createOpenRouterClient, estimateCost, exchangeAuthCode, fetchEditingModels, fetchKeyInfo, OpenRouterError, type FetchLike } from '../openrouter';

type Call = { url: string; init: Parameters<FetchLike>[1] };

function fakeFetch(responses: { status?: number; body: unknown }[]): { fetch: FetchLike; calls: Call[] } {
  const calls: Call[] = [];
  const queue = [...responses];
  return {
    calls,
    fetch: async (url, init) => {
      calls.push({ url, init });
      const next = queue.shift();
      if (!next) throw new Error('no more responses');
      const status = next.status ?? 200;
      return { ok: status >= 200 && status < 300, status, json: async () => next.body, text: async () => JSON.stringify(next.body) };
    },
  };
}

const completion = { id: 'gen-1', model: 'anthropic/claude-sonnet-5.5', choices: [{ message: { role: 'assistant', content: 'Done.' }, finish_reason: 'stop' }], usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15, cost: 0.0021 } };

describe('OpenRouter client', () => {
  it('sends the key, the app headers and the request body', async () => {
    const { fetch, calls } = fakeFetch([{ body: completion }]);
    const response = await createOpenRouterClient('sk-or-test', fetch).chat({ model: 'm', messages: [{ role: 'user', content: 'hi' }] });
    expect(response.message.content).toBe('Done.');
    expect(response.usage?.cost).toBe(0.0021);
    expect(calls[0].url).toBe('https://openrouter.ai/api/v1/chat/completions');
    expect(calls[0].init?.headers).toMatchObject({ Authorization: 'Bearer sk-or-test', 'X-OpenRouter-Title': 'Oscuru', 'Content-Type': 'application/json' });
    expect(JSON.parse(calls[0].init?.body ?? '{}')).toEqual({ model: 'm', messages: [{ role: 'user', content: 'hi' }] });
  });

  it.each([
    [401, 'unauthorized'],
    [402, 'payment'],
    [429, 'rate_limit'],
    [400, 'bad_request'],
  ])('reports HTTP %i as %s with the message from OpenRouter', async (status, kind) => {
    const { fetch } = fakeFetch([{ status, body: { error: { message: 'because' } } }]);
    const error = await createOpenRouterClient('k', fetch).chat({ model: 'm', messages: [] }).catch((caught) => caught);
    expect(error).toBeInstanceOf(OpenRouterError);
    expect(error.kind).toBe(kind);
    expect(error.message).toBe('because');
  });

  it('retries once when the server fails, and gives up after that', async () => {
    const ok = fakeFetch([{ status: 503, body: {} }, { body: completion }]);
    await expect(createOpenRouterClient('k', ok.fetch).chat({ model: 'm', messages: [] })).resolves.toMatchObject({ id: 'gen-1' });
    expect(ok.calls).toHaveLength(2);
    const bad = fakeFetch([{ status: 503, body: {} }, { status: 502, body: {} }]);
    await expect(createOpenRouterClient('k', bad.fetch).chat({ model: 'm', messages: [] })).rejects.toMatchObject({ kind: 'server' });
  });

  it('does not retry a refused key', async () => {
    const { fetch, calls } = fakeFetch([{ status: 401, body: {} }, { body: completion }]);
    await expect(createOpenRouterClient('k', fetch).chat({ model: 'm', messages: [] })).rejects.toMatchObject({ kind: 'unauthorized' });
    expect(calls).toHaveLength(1);
  });

  it('treats an error inside a 200 response as an error', async () => {
    const { fetch } = fakeFetch([{ body: { error: { code: 402, message: 'Insufficient credits' } } }]);
    await expect(createOpenRouterClient('k', fetch).chat({ model: 'm', messages: [] })).rejects.toMatchObject({ kind: 'payment', message: 'Insufficient credits' });
  });

  it('turns a failed connection into a network error', async () => {
    let attempts = 0;
    const fetch: FetchLike = async () => {
      attempts++;
      throw new TypeError('Network request failed');
    };
    await expect(createOpenRouterClient('k', fetch).chat({ model: 'm', messages: [] })).rejects.toMatchObject({ kind: 'network' });
    expect(attempts).toBe(2);
  });

  it('rejects a response without a message', async () => {
    const { fetch } = fakeFetch([{ body: { choices: [] } }]);
    await expect(createOpenRouterClient('k', fetch).chat({ model: 'm', messages: [] })).rejects.toMatchObject({ kind: 'invalid_response' });
  });
});

describe('account helpers', () => {
  it('reads what a key has used and what it may still use', async () => {
    const { fetch, calls } = fakeFetch([{ body: { data: { label: 'sk-or-v1-abc…xyz', usage: 1.5, usage_daily: 0.2, usage_monthly: 1.1, limit: 20, limit_remaining: 18.5, is_free_tier: false } } }]);
    await expect(fetchKeyInfo('sk', fetch)).resolves.toEqual({ label: 'sk-or-v1-abc…xyz', usage: 1.5, usageDaily: 0.2, usageMonthly: 1.1, limit: 20, limitRemaining: 18.5, isFreeTier: false });
    expect(calls[0].url).toBe('https://openrouter.ai/api/v1/key');
    const none = fakeFetch([{ body: { data: { label: 'x', usage: 0, limit: null, limit_remaining: null } } }]);
    await expect(fetchKeyInfo('sk', none.fetch)).resolves.toMatchObject({ limit: null, limitRemaining: null, usageDaily: null });
  });

  it('lists only models that read images and call tools, with prices per million tokens', async () => {
    const model = (id: string, extra: Record<string, unknown> = {}) => ({
      id,
      name: id.toUpperCase(),
      context_length: 1000,
      architecture: { input_modalities: ['text', 'image'] },
      supported_parameters: ['tools', 'temperature'],
      pricing: { prompt: '0.000002', completion: '0.00001' },
      ...extra,
    });
    const { fetch, calls } = fakeFetch([
      {
        body: {
          data: [
            model('a/vision-tools'),
            model('a/vision-tools:batch'),
            model('~a/latest'),
            model('b/text-only', { architecture: { input_modalities: ['text'] } }),
            model('c/no-tools', { supported_parameters: ['temperature'] }),
            model('d/router', { pricing: { prompt: '-1', completion: '-1' } }),
          ],
        },
      },
    ]);
    await expect(fetchEditingModels(fetch)).resolves.toEqual([{ id: 'a/vision-tools', name: 'A/VISION-TOOLS', contextLength: 1000, promptPrice: 2, completionPrice: 10 }]);
    expect(calls[0].url).toContain('input_modalities=image');
    expect(calls[0].init?.headers).not.toHaveProperty('Authorization');
  });

  it('uses the charged cost when given, and prices tokens otherwise', () => {
    const model = { id: 'm', name: 'm', contextLength: 0, promptPrice: 2, completionPrice: 10 };
    expect(estimateCost({ prompt_tokens: 1000, completion_tokens: 100, total_tokens: 1100, cost: 0.5 }, model)).toBe(0.5);
    expect(estimateCost({ prompt_tokens: 1000, completion_tokens: 100, total_tokens: 1100 }, model)).toBeCloseTo(0.003);
    expect(estimateCost({ prompt_tokens: 1000, completion_tokens: 100, total_tokens: 1100 }, undefined)).toBe(0);
  });

  it('builds the sign-in address with and without a way back to the app', () => {
    expect(buildAuthUrl({ codeChallenge: 'abc', callbackUrl: 'oscuru://openrouter', limit: 20, keyLabel: 'Oscuru' })).toBe(
      'https://openrouter.ai/auth?callback_url=oscuru%3A%2F%2Fopenrouter&code_challenge=abc&code_challenge_method=S256&limit=20&key_label=Oscuru',
    );
    expect(buildAuthUrl({ codeChallenge: 'abc' })).toBe('https://openrouter.ai/auth?code_challenge=abc&code_challenge_method=S256');
  });

  it('exchanges a sign-in code for a key', async () => {
    const { fetch, calls } = fakeFetch([{ body: { key: 'sk-or-v1-new', user_id: 'user_1' } }]);
    await expect(exchangeAuthCode('code-1', 'verifier-1', fetch)).resolves.toEqual({ key: 'sk-or-v1-new', userId: 'user_1' });
    expect(calls[0].url).toBe('https://openrouter.ai/api/v1/auth/keys');
    expect(JSON.parse(calls[0].init?.body ?? '{}')).toEqual({ code: 'code-1', code_verifier: 'verifier-1', code_challenge_method: 'S256' });
    const refused = fakeFetch([{ status: 403, body: { error: { message: 'Invalid code or code_verifier' } } }]);
    await expect(exchangeAuthCode('x', 'y', refused.fetch)).rejects.toMatchObject({ kind: 'unauthorized' });
    const empty = fakeFetch([{ body: { key: '' } }]);
    await expect(exchangeAuthCode('x', 'y', empty.fetch)).rejects.toMatchObject({ kind: 'invalid_response' });
  });
});
