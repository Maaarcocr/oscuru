/**
 * The person's OpenRouter connection, model choice, spending limits and spending record.
 *
 * There is no Oscuru server: everyone signs in to their own OpenRouter account (or pastes a key)
 * and pays for their own usage. The key lives in the keychain and is only ever sent to OpenRouter.
 */

import * as Crypto from 'expo-crypto';
import * as Linking from 'expo-linking';
import * as WebBrowser from 'expo-web-browser';

import { checkBudget, CostLedger, parseLimits, type BudgetCheck, type SpendingLimits } from '@/agent/cost';
import {
  buildAuthUrl,
  estimateCost,
  exchangeAuthCode,
  fetchEditingModels,
  fetchKeyInfo,
  type KeyInfo,
  type ModelInfo,
  type Usage,
} from '@/agent/openrouter';
import { deleteSecret, getSecret, readJSON, setSecret, writeJSON } from './storage';
import { createStore } from './store';

const KEY_ITEM = 'openrouter-api-key';
const USER_ITEM = 'openrouter-user-id';

/** Tried in order; the first one OpenRouter currently offers becomes the default model. */
export const PREFERRED_MODELS = ['anthropic/claude-sonnet-5.5', 'anthropic/claude-sonnet-5', 'google/gemini-4-carbon', 'openai/gpt-6.1-terra'];

export interface AccountState {
  loaded: boolean;
  /** Present when connected. Never shown in full. */
  apiKey: string | null;
  /** A stable name for whoever pays: spending is recorded and limited per user. */
  userId: string | null;
  keyInfo: KeyInfo | null;
  /** The chosen model id, or null for the default. */
  model: string | null;
  models: ModelInfo[];
  limits: SpendingLimits;
  /** Bumps whenever spending is recorded, so screens showing totals refresh. */
  spendingVersion: number;
}

export const accountStore = createStore<AccountState>({
  loaded: false,
  apiKey: null,
  userId: null,
  keyInfo: null,
  model: null,
  models: [],
  limits: parseLimits(undefined),
  spendingVersion: 0,
});

let ledger = new CostLedger();

function saveSettings(): void {
  const { model, limits } = accountStore.get();
  writeJSON('settings', { model, limits });
}

const patch = (change: Partial<AccountState>): void => accountStore.set((current) => ({ ...current, ...change }));

/** Spending is tracked per OpenRouter user. Without a user id from sign-in, a fingerprint of the key stands in. */
async function userIdFor(apiKey: string, fromSignIn: string | null): Promise<string> {
  if (fromSignIn) return fromSignIn;
  const digest = await Crypto.digestStringAsync(Crypto.CryptoDigestAlgorithm.SHA256, apiKey);
  return `key-${digest.slice(0, 16)}`;
}

export async function loadAccount(): Promise<void> {
  const settings = (readJSON('settings') ?? {}) as { model?: unknown; limits?: unknown };
  ledger = CostLedger.fromJSON(readJSON('spending'));
  const apiKey = await getSecret(KEY_ITEM);
  const userId = apiKey ? ((await getSecret(USER_ITEM)) ?? (await userIdFor(apiKey, null))) : null;
  patch({
    loaded: true,
    apiKey,
    userId,
    model: typeof settings.model === 'string' ? settings.model : null,
    limits: parseLimits(settings.limits),
  });
  void refreshModels();
  if (apiKey) void refreshKeyInfo();
}

export async function refreshModels(): Promise<void> {
  try {
    patch({ models: await fetchEditingModels() });
  } catch {
    // Offline: the picker shows only the current choice until the list can be fetched.
  }
}

export async function refreshKeyInfo(): Promise<void> {
  const { apiKey } = accountStore.get();
  if (!apiKey) return;
  try {
    patch({ keyInfo: await fetchKeyInfo(apiKey) });
  } catch {
    // Offline or a revoked key: the next request to the model reports it properly.
  }
}

/** Checks a key with OpenRouter and, when it works, stores it in the keychain. */
export async function connectWithKey(apiKey: string, userIdFromSignIn: string | null = null): Promise<void> {
  const trimmed = apiKey.trim();
  const keyInfo = await fetchKeyInfo(trimmed);
  const userId = await userIdFor(trimmed, userIdFromSignIn);
  await setSecret(KEY_ITEM, trimmed);
  await setSecret(USER_ITEM, userId);
  patch({ apiKey: trimmed, userId, keyInfo });
}

export async function disconnect(): Promise<void> {
  await deleteSecret(KEY_ITEM);
  await deleteSecret(USER_ITEM);
  patch({ apiKey: null, userId: null, keyInfo: null });
}

const base64Url = (base64: string): string => base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

function randomVerifier(): string {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  let verifier = '';
  for (const byte of Crypto.getRandomBytes(64)) verifier += alphabet[byte % alphabet.length];
  return verifier;
}

async function challengeFor(verifier: string): Promise<string> {
  const digest = await Crypto.digestStringAsync(Crypto.CryptoDigestAlgorithm.SHA256, verifier, { encoding: Crypto.CryptoEncoding.BASE64 });
  return base64Url(digest);
}

/** Kept between opening OpenRouter's page and getting a code back, including a code typed in by hand. */
let pendingVerifier: string | null = null;

export type SignInResult = 'connected' | 'cancelled' | 'needs_code';

/**
 * Signs in with OpenRouter (OAuth PKCE). OpenRouter creates a key for the person, capped at the
 * monthly limit set here unless they change it on the page, and sends back a one-time code.
 */
export async function signInWithOpenRouter(): Promise<SignInResult> {
  pendingVerifier = randomVerifier();
  const callbackUrl = Linking.createURL('openrouter');
  const { limits } = accountStore.get();
  const url = buildAuthUrl({
    codeChallenge: await challengeFor(pendingVerifier),
    callbackUrl,
    limit: limits.perMonth > 0 ? limits.perMonth : undefined,
    keyLabel: 'Oscuru',
  });
  const result = await WebBrowser.openAuthSessionAsync(url, callbackUrl);
  if (result.type !== 'success') return 'cancelled';
  const code = Linking.parse(result.url).queryParams?.code;
  if (typeof code !== 'string' || code === '') return 'needs_code';
  await finishSignIn(code);
  return 'connected';
}

/**
 * The same sign-in without a redirect: OpenRouter shows the code and the person pastes it into the
 * app. A fallback for when the redirect back to the app does not work.
 */
export async function openSignInPageForCode(): Promise<void> {
  pendingVerifier = randomVerifier();
  const { limits } = accountStore.get();
  const url = buildAuthUrl({
    codeChallenge: await challengeFor(pendingVerifier),
    limit: limits.perMonth > 0 ? limits.perMonth : undefined,
    keyLabel: 'Oscuru',
  });
  await WebBrowser.openBrowserAsync(url);
}

export async function finishSignIn(code: string): Promise<void> {
  if (!pendingVerifier) throw new Error('Start the sign-in again: this code does not belong to a sign-in from this app session.');
  const { key, userId } = await exchangeAuthCode(code.trim(), pendingVerifier);
  pendingVerifier = null;
  await connectWithKey(key, userId);
}

export function setModel(model: string | null): void {
  patch({ model });
  saveSettings();
}

export function setLimits(limits: SpendingLimits): void {
  patch({ limits });
  saveSettings();
}

/** The model that requests go to: the person's choice, else the first preferred model on offer. */
export function activeModel(state: AccountState = accountStore.get()): string {
  if (state.model) return state.model;
  const offered = new Set(state.models.map((model) => model.id));
  return PREFERRED_MODELS.find((id) => offered.has(id)) ?? PREFERRED_MODELS[0];
}

export function recordUsage(usage: Usage, model: string, runId: string, photoId: string): number {
  const state = accountStore.get();
  if (!state.userId) return 0;
  const cost = estimateCost(usage, state.models.find((entry) => entry.id === model));
  ledger.add({
    at: Date.now(),
    userId: state.userId,
    model,
    cost,
    promptTokens: usage.prompt_tokens ?? 0,
    completionTokens: usage.completion_tokens ?? 0,
    runId,
    photoId,
  });
  writeJSON('spending', ledger.toJSON());
  patch({ spendingVersion: state.spendingVersion + 1 });
  return cost;
}

export function budgetFor(runId: string): BudgetCheck {
  const state = accountStore.get();
  if (!state.userId) return { ok: true };
  return checkBudget(ledger, state.limits, state.userId, runId, Date.now());
}

export interface SpendingSummary {
  today: number;
  month: number;
  requestsToday: number;
}

export function spendingSummary(): SpendingSummary {
  const { userId } = accountStore.get();
  if (!userId) return { today: 0, month: 0, requestsToday: 0 };
  const now = Date.now();
  return { today: ledger.spentToday(userId, now), month: ledger.spentThisMonth(userId, now), requestsToday: ledger.requestsToday(userId, now) };
}

export function spentOnRun(runId: string): number {
  const { userId } = accountStore.get();
  return userId ? ledger.spentOnRun(userId, runId) : 0;
}
