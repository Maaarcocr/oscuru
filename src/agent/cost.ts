/**
 * What the assistant has cost, per person, and the limits that stop it.
 *
 * In this prototype everyone pays with their own OpenRouter key, so "person" is the key's account.
 * Every model response is recorded with what OpenRouter charged for it; before each request the
 * agent asks `checkBudget` whether it may go on.
 */

export interface CostEntry {
  /** Milliseconds since the epoch. */
  at: number;
  userId: string;
  model: string;
  /** US dollars. */
  cost: number;
  promptTokens: number;
  completionTokens: number;
  /** One instruction from the person, however many model requests it took. */
  runId: string;
  photoId?: string;
}

export interface SpendingLimits {
  /** Most that one instruction may cost, in US dollars. 0 means no limit. */
  perRequest: number;
  perDay: number;
  perMonth: number;
}

export const DEFAULT_LIMITS: SpendingLimits = { perRequest: 0.5, perDay: 3, perMonth: 20 };

export type BudgetScope = 'perRequest' | 'perDay' | 'perMonth';

export type BudgetCheck = { ok: true } | { ok: false; scope: BudgetScope; spent: number; limit: number };

const KEEP_DAYS = 62;
const DAY = 24 * 60 * 60 * 1000;

const startOfDay = (now: number): number => {
  const date = new Date(now);
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
};

const startOfMonth = (now: number): number => {
  const date = new Date(now);
  return new Date(date.getFullYear(), date.getMonth(), 1).getTime();
};

export class CostLedger {
  private entries: CostEntry[];

  constructor(entries: CostEntry[] = []) {
    this.entries = entries;
  }

  /** Reads a saved ledger, dropping anything that is not a well-formed entry. */
  static fromJSON(value: unknown): CostLedger {
    if (!Array.isArray(value)) return new CostLedger();
    const entries = value.filter(
      (entry): entry is CostEntry =>
        typeof entry === 'object' &&
        entry !== null &&
        typeof entry.at === 'number' &&
        typeof entry.userId === 'string' &&
        typeof entry.model === 'string' &&
        typeof entry.cost === 'number' &&
        Number.isFinite(entry.cost) &&
        entry.cost >= 0 &&
        typeof entry.runId === 'string',
    );
    return new CostLedger(entries);
  }

  toJSON(): CostEntry[] {
    return this.entries;
  }

  add(entry: CostEntry): void {
    this.entries.push(entry);
    const cutoff = entry.at - KEEP_DAYS * DAY;
    if (this.entries[0].at < cutoff) this.entries = this.entries.filter((item) => item.at >= cutoff);
  }

  private sum(userId: string, include: (entry: CostEntry) => boolean): number {
    let total = 0;
    for (const entry of this.entries) {
      if (entry.userId === userId && include(entry)) total += entry.cost;
    }
    return total;
  }

  spentToday(userId: string, now: number): number {
    const from = startOfDay(now);
    return this.sum(userId, (entry) => entry.at >= from);
  }

  spentThisMonth(userId: string, now: number): number {
    const from = startOfMonth(now);
    return this.sum(userId, (entry) => entry.at >= from);
  }

  spentOnRun(userId: string, runId: string): number {
    return this.sum(userId, (entry) => entry.runId === runId);
  }

  spentOnPhoto(userId: string, photoId: string): number {
    return this.sum(userId, (entry) => entry.photoId === photoId);
  }

  requestsToday(userId: string, now: number): number {
    const from = startOfDay(now);
    return new Set(this.entries.filter((entry) => entry.userId === userId && entry.at >= from).map((entry) => entry.runId)).size;
  }
}

/** Whether another model request may be made. The first limit that is reached is reported. */
export function checkBudget(ledger: CostLedger, limits: SpendingLimits, userId: string, runId: string, now: number): BudgetCheck {
  const checks: [BudgetScope, number, number][] = [
    ['perRequest', ledger.spentOnRun(userId, runId), limits.perRequest],
    ['perDay', ledger.spentToday(userId, now), limits.perDay],
    ['perMonth', ledger.spentThisMonth(userId, now), limits.perMonth],
  ];
  for (const [scope, spent, limit] of checks) {
    if (limit > 0 && spent >= limit) return { ok: false, scope, spent, limit };
  }
  return { ok: true };
}

export function parseLimits(value: unknown): SpendingLimits {
  const input = (typeof value === 'object' && value !== null ? value : {}) as Partial<Record<BudgetScope, unknown>>;
  const pick = (key: BudgetScope): number => {
    const candidate = input[key];
    return typeof candidate === 'number' && Number.isFinite(candidate) && candidate >= 0 ? candidate : DEFAULT_LIMITS[key];
  };
  return { perRequest: pick('perRequest'), perDay: pick('perDay'), perMonth: pick('perMonth') };
}

export function formatDollars(amount: number): string {
  if (amount > 0 && amount < 0.01) return `$${amount.toFixed(4)}`;
  return `$${amount.toFixed(2)}`;
}
