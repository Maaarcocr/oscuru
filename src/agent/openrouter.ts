/**
 * A small client for OpenRouter's chat-completions API: the only place the app talks to a model.
 * Swapping the model is a change of `model` id; swapping the provider is a change of this file.
 */

export const OPENROUTER_BASE = 'https://openrouter.ai/api/v1';
export const OPENROUTER_AUTH_URL = 'https://openrouter.ai/auth';

/** Shown on OpenRouter's side as the app that made the request. */
const APP_HEADERS = {
  'HTTP-Referer': 'https://github.com/Maaarcocr/oscuru',
  'X-OpenRouter-Title': 'Oscuru',
  'X-Title': 'Oscuru',
};

export type ContentPart = { type: 'text'; text: string } | { type: 'image_url'; image_url: { url: string } };

export interface ToolCall {
  id: string;
  type: 'function';
  function: { name: string; arguments: string };
}

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant' | 'tool';
  content: string | ContentPart[] | null;
  tool_calls?: ToolCall[];
  tool_call_id?: string;
  /** Returned by reasoning models; must be sent back unchanged with the message it came on. */
  reasoning_details?: unknown;
}

export interface ToolDefinition {
  type: 'function';
  function: { name: string; description: string; parameters: Record<string, unknown> };
}

export interface Usage {
  prompt_tokens: number;
  completion_tokens: number;
  total_tokens: number;
  /** What OpenRouter charged for this request, in US dollars of credit. */
  cost?: number;
  prompt_tokens_details?: { cached_tokens?: number; cache_write_tokens?: number };
}

export interface ChatRequest {
  model: string;
  messages: ChatMessage[];
  tools?: ToolDefinition[];
  tool_choice?: 'auto' | 'none';
  parallel_tool_calls?: boolean;
  max_tokens?: number;
  /** Lets one conversation stay on one provider so prompt caching keeps working. */
  session_id?: string;
  cache_control?: { type: 'ephemeral' };
}

export interface ChatResponse {
  id: string;
  model: string;
  message: ChatMessage;
  finishReason: string | null;
  usage: Usage | null;
}

export type OpenRouterErrorKind = 'unauthorized' | 'payment' | 'rate_limit' | 'bad_request' | 'server' | 'network' | 'invalid_response';

export class OpenRouterError extends Error {
  constructor(
    readonly kind: OpenRouterErrorKind,
    message: string,
    readonly status?: number,
  ) {
    super(message);
    this.name = 'OpenRouterError';
  }
}

export type FetchLike = (url: string, init?: { method?: string; headers?: Record<string, string>; body?: string; signal?: AbortSignal }) => Promise<{
  ok: boolean;
  status: number;
  headers?: { get(name: string): string | null };
  json(): Promise<unknown>;
  text(): Promise<string>;
}>;

function kindForStatus(status: number): OpenRouterErrorKind {
  if (status === 401 || status === 403) return 'unauthorized';
  if (status === 402) return 'payment';
  if (status === 429) return 'rate_limit';
  if (status >= 500) return 'server';
  return 'bad_request';
}

function messageFromBody(body: unknown, fallback: string): string {
  if (typeof body === 'object' && body !== null) {
    const error = (body as { error?: { message?: unknown } }).error;
    if (error && typeof error.message === 'string') return error.message;
  }
  return fallback;
}

async function request(fetchImpl: FetchLike, path: string, init: { method: string; apiKey?: string; body?: unknown; signal?: AbortSignal }): Promise<unknown> {
  let response: Awaited<ReturnType<FetchLike>>;
  try {
    response = await fetchImpl(`${OPENROUTER_BASE}${path}`, {
      method: init.method,
      headers: {
        'Content-Type': 'application/json',
        ...APP_HEADERS,
        ...(init.apiKey ? { Authorization: `Bearer ${init.apiKey}` } : {}),
      },
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
      signal: init.signal,
    });
  } catch (error) {
    if (init.signal?.aborted) throw error;
    throw new OpenRouterError('network', error instanceof Error ? error.message : 'Network request failed');
  }
  let body: unknown;
  try {
    body = await response.json();
  } catch {
    body = undefined;
  }
  if (!response.ok) {
    throw new OpenRouterError(kindForStatus(response.status), messageFromBody(body, `OpenRouter answered ${response.status}`), response.status);
  }
  // OpenRouter can also report a provider error inside a 200 response.
  if (typeof body === 'object' && body !== null && 'error' in body && !('choices' in body) && !('data' in body) && !('key' in body)) {
    const code = (body as { error?: { code?: unknown } }).error?.code;
    const status = typeof code === 'number' ? code : 500;
    throw new OpenRouterError(kindForStatus(status), messageFromBody(body, 'OpenRouter reported an error'), status);
  }
  return body;
}

export interface OpenRouterClient {
  chat(request: ChatRequest, signal?: AbortSignal): Promise<ChatResponse>;
}

export function createOpenRouterClient(apiKey: string, fetchImpl: FetchLike = fetch as unknown as FetchLike): OpenRouterClient {
  return {
    async chat(chatRequest, signal) {
      const send = () => request(fetchImpl, '/chat/completions', { method: 'POST', apiKey, body: chatRequest, signal });
      let body: unknown;
      try {
        body = await send();
      } catch (error) {
        // One retry for failures that are usually momentary.
        if (error instanceof OpenRouterError && (error.kind === 'server' || error.kind === 'network') && !signal?.aborted) {
          body = await send();
        } else {
          throw error;
        }
      }
      const choice = (body as { choices?: { message?: ChatMessage; finish_reason?: string | null }[] }).choices?.[0];
      if (!choice?.message) throw new OpenRouterError('invalid_response', 'OpenRouter returned no message');
      const raw = body as { id?: string; model?: string; usage?: Usage };
      return {
        id: raw.id ?? '',
        model: raw.model ?? chatRequest.model,
        message: choice.message,
        finishReason: choice.finish_reason ?? null,
        usage: raw.usage ?? null,
      };
    },
  };
}

export interface KeyInfo {
  label: string;
  /** Credits used by this key, in US dollars. */
  usage: number;
  usageDaily: number | null;
  usageMonthly: number | null;
  /** The key's own spending cap, or null when it has none. */
  limit: number | null;
  limitRemaining: number | null;
  isFreeTier: boolean;
}

const numberOrNull = (value: unknown): number | null => (typeof value === 'number' && Number.isFinite(value) ? value : null);

/** What OpenRouter knows about a key: also the way to check that a key works. */
export async function fetchKeyInfo(apiKey: string, fetchImpl: FetchLike = fetch as unknown as FetchLike, signal?: AbortSignal): Promise<KeyInfo> {
  const body = (await request(fetchImpl, '/key', { method: 'GET', apiKey, signal })) as { data?: Record<string, unknown> };
  const data = body.data ?? {};
  return {
    label: typeof data.label === 'string' ? data.label : '',
    usage: numberOrNull(data.usage) ?? 0,
    usageDaily: numberOrNull(data.usage_daily),
    usageMonthly: numberOrNull(data.usage_monthly),
    limit: numberOrNull(data.limit),
    limitRemaining: numberOrNull(data.limit_remaining),
    isFreeTier: data.is_free_tier === true,
  };
}

export interface ModelInfo {
  id: string;
  name: string;
  contextLength: number;
  /** US dollars per million tokens. */
  promptPrice: number;
  completionPrice: number;
}

/** Models that can do the job: they accept images and can call tools. Cheapest variants and batch-only endpoints are left out. */
export async function fetchEditingModels(fetchImpl: FetchLike = fetch as unknown as FetchLike, signal?: AbortSignal): Promise<ModelInfo[]> {
  const body = (await request(fetchImpl, '/models?input_modalities=image&supported_parameters=tools', { method: 'GET', signal })) as { data?: unknown[] };
  const models: ModelInfo[] = [];
  for (const entry of body.data ?? []) {
    const model = entry as {
      id?: unknown;
      name?: unknown;
      context_length?: unknown;
      architecture?: { input_modalities?: unknown };
      supported_parameters?: unknown;
      pricing?: { prompt?: unknown; completion?: unknown };
    };
    if (typeof model.id !== 'string' || model.id.endsWith(':batch') || model.id.startsWith('~')) continue;
    const inputs = model.architecture?.input_modalities;
    const parameters = model.supported_parameters;
    if (!Array.isArray(inputs) || !inputs.includes('image') || !Array.isArray(parameters) || !parameters.includes('tools')) continue;
    const prompt = Number(model.pricing?.prompt);
    const completion = Number(model.pricing?.completion);
    if (!Number.isFinite(prompt) || !Number.isFinite(completion) || prompt < 0 || completion < 0) continue;
    models.push({
      id: model.id,
      name: typeof model.name === 'string' ? model.name : model.id,
      contextLength: typeof model.context_length === 'number' ? model.context_length : 0,
      promptPrice: prompt * 1e6,
      completionPrice: completion * 1e6,
    });
  }
  return models;
}

/** Used when a response carries token counts but no cost. */
export function estimateCost(usage: Usage, model: ModelInfo | undefined): number {
  if (typeof usage.cost === 'number' && Number.isFinite(usage.cost)) return usage.cost;
  if (!model) return 0;
  return (usage.prompt_tokens * model.promptPrice + usage.completion_tokens * model.completionPrice) / 1e6;
}

/**
 * The address of OpenRouter's sign-in page for the PKCE flow. Without a callback OpenRouter shows
 * the code for the person to copy instead of redirecting.
 */
export function buildAuthUrl(options: { codeChallenge: string; callbackUrl?: string; limit?: number; keyLabel?: string }): string {
  const parameters: [string, string][] = [];
  if (options.callbackUrl) parameters.push(['callback_url', options.callbackUrl]);
  parameters.push(['code_challenge', options.codeChallenge], ['code_challenge_method', 'S256']);
  if (options.limit && options.limit > 0) parameters.push(['limit', String(Math.round(options.limit * 100) / 100)]);
  if (options.keyLabel) parameters.push(['key_label', options.keyLabel]);
  return `${OPENROUTER_AUTH_URL}?${parameters.map(([key, value]) => `${key}=${encodeURIComponent(value)}`).join('&')}`;
}

/** Trades the code from the sign-in page for the person's own API key. */
export async function exchangeAuthCode(code: string, codeVerifier: string, fetchImpl: FetchLike = fetch as unknown as FetchLike): Promise<{ key: string; userId: string | null }> {
  const body = (await request(fetchImpl, '/auth/keys', {
    method: 'POST',
    body: { code, code_verifier: codeVerifier, code_challenge_method: 'S256' },
  })) as { key?: unknown; user_id?: unknown };
  if (typeof body.key !== 'string' || body.key === '') throw new OpenRouterError('invalid_response', 'OpenRouter returned no key');
  return { key: body.key, userId: typeof body.user_id === 'string' ? body.user_id : null };
}
