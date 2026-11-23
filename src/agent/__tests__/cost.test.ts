import { checkBudget, CostLedger, DEFAULT_LIMITS, formatDollars, parseLimits, type CostEntry } from '../cost';

const at = (year: number, month: number, day: number, hour = 12): number => new Date(year, month - 1, day, hour).getTime();
const entry = (overrides: Partial<CostEntry>): CostEntry => ({
  at: at(2026, 11, 23),
  userId: 'ada',
  model: 'anthropic/claude-sonnet-5.5',
  cost: 0.1,
  promptTokens: 1000,
  completionTokens: 200,
  runId: 'run-1',
  ...overrides,
});

describe('cost ledger', () => {
  it('adds up spending per person, per day, per month and per request', () => {
    const ledger = new CostLedger();
    ledger.add(entry({ cost: 0.1 }));
    ledger.add(entry({ cost: 0.2, runId: 'run-2', photoId: 'p1' }));
    ledger.add(entry({ cost: 0.4, at: at(2026, 11, 2), runId: 'run-0' }));
    ledger.add(entry({ cost: 9, userId: 'grace' }));
    ledger.add(entry({ cost: 5, at: at(2026, 10, 30), runId: 'old' }));
    const now = at(2026, 11, 23, 18);
    expect(ledger.spentToday('ada', now)).toBeCloseTo(0.3);
    expect(ledger.spentThisMonth('ada', now)).toBeCloseTo(0.7);
    expect(ledger.spentOnRun('ada', 'run-2')).toBeCloseTo(0.2);
    expect(ledger.spentOnPhoto('ada', 'p1')).toBeCloseTo(0.2);
    expect(ledger.requestsToday('ada', now)).toBe(2);
    expect(ledger.spentToday('grace', now)).toBe(9);
    expect(ledger.spentToday('nobody', now)).toBe(0);
  });

  it('survives a round trip and ignores damaged entries', () => {
    const ledger = new CostLedger();
    ledger.add(entry({ cost: 0.25 }));
    const restored = CostLedger.fromJSON(JSON.parse(JSON.stringify([...ledger.toJSON(), { cost: 'lots' }, null, { ...entry({}), cost: -1 }])));
    expect(restored.toJSON()).toHaveLength(1);
    expect(restored.spentOnRun('ada', 'run-1')).toBe(0.25);
    expect(CostLedger.fromJSON('nonsense').toJSON()).toEqual([]);
  });

  it('forgets entries older than about two months', () => {
    const ledger = new CostLedger();
    ledger.add(entry({ at: at(2026, 8, 1), runId: 'ancient' }));
    ledger.add(entry({ at: at(2026, 11, 23) }));
    expect(ledger.toJSON().map((item) => item.runId)).toEqual(['run-1']);
  });
});

describe('budget', () => {
  const now = at(2026, 11, 23, 18);
  const limits = { perRequest: 0.5, perDay: 1, perMonth: 2 };

  it('lets a request through while every limit has room', () => {
    const ledger = new CostLedger([entry({ cost: 0.4 })]);
    expect(checkBudget(ledger, limits, 'ada', 'run-1', now)).toEqual({ ok: true });
  });

  it('stops at the request limit first', () => {
    const ledger = new CostLedger([entry({ cost: 0.3 }), entry({ cost: 0.25 })]);
    expect(checkBudget(ledger, limits, 'ada', 'run-1', now)).toEqual({ ok: false, scope: 'perRequest', spent: 0.55, limit: 0.5 });
    // A new request the same day is still allowed.
    expect(checkBudget(ledger, limits, 'ada', 'run-2', now)).toEqual({ ok: true });
  });

  it('stops at the day and month limits across requests', () => {
    const day = new CostLedger([entry({ cost: 0.45, runId: 'a' }), entry({ cost: 0.45, runId: 'b' }), entry({ cost: 0.2, runId: 'c' })]);
    expect(checkBudget(day, limits, 'ada', 'run-9', now)).toMatchObject({ ok: false, scope: 'perDay', limit: 1 });
    const month = new CostLedger([entry({ cost: 0.9, at: at(2026, 11, 3), runId: 'a' }), entry({ cost: 0.9, at: at(2026, 11, 9), runId: 'b' }), entry({ cost: 0.3, runId: 'c' })]);
    expect(checkBudget(month, limits, 'ada', 'run-9', now)).toMatchObject({ ok: false, scope: 'perMonth', limit: 2 });
  });

  it('counts each person separately and treats 0 as no limit', () => {
    const ledger = new CostLedger([entry({ cost: 50, userId: 'grace' })]);
    expect(checkBudget(ledger, limits, 'ada', 'run-1', now)).toEqual({ ok: true });
    expect(checkBudget(ledger, { perRequest: 0, perDay: 0, perMonth: 0 }, 'grace', 'run-1', now)).toEqual({ ok: true });
  });

  it('reads saved limits, falling back to the defaults', () => {
    expect(parseLimits({ perRequest: 1, perDay: 'x', perMonth: -3 })).toEqual({ perRequest: 1, perDay: DEFAULT_LIMITS.perDay, perMonth: DEFAULT_LIMITS.perMonth });
    expect(parseLimits(null)).toEqual(DEFAULT_LIMITS);
    expect(parseLimits({ perDay: 0 }).perDay).toBe(0);
  });

  it('formats small amounts with enough digits to mean something', () => {
    expect(formatDollars(0)).toBe('$0.00');
    expect(formatDollars(0.0042)).toBe('$0.0042');
    expect(formatDollars(1.239)).toBe('$1.24');
  });
});
