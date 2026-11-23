/**
 * Runtime half of the sandboxed script interpreter: error types, limits, guarded
 * property access and the allow-listed built-ins. The compiler half (AST -> closures)
 * lives in `interpreter.ts`.
 *
 * Security model in one paragraph: scripts only ever touch host values through
 * `Runtime.get/set/del/has/call`. Property reads are answered from per-type allow-lists
 * or from OWN properties, never from the prototype chain, and a small set of property
 * names is rejected outright. Every built-in a script can call is a wrapper created here
 * that validates its receiver, bounds the size of what it produces and charges the step
 * budget, so native code can never run unbounded on behalf of a script.
 */
// The sandbox depends on strict-mode `this` (never the global object, never boxed) in every
// function of this file. React Native's Babel preset does not add the directive to modules.
'use strict';

import type { Node } from 'acorn';

export type ScriptErrorKind = 'syntax' | 'unsupported' | 'security' | 'limit' | 'aborted' | 'runtime' | 'thrown';

export class ScriptError extends Error {
  kind: ScriptErrorKind;
  /** 1-based source line of the node being evaluated, when known. */
  line?: number;
  /** 0-based column. */
  column?: number;
  /** Names of interpreted functions on the call stack, innermost first. */
  scriptStack?: string[];

  constructor(kind: ScriptErrorKind, message: string, line?: number, column?: number, scriptStack?: string[]) {
    super(message);
    Object.setPrototypeOf(this, ScriptError.prototype);
    this.name = 'ScriptError';
    this.kind = kind;
    this.line = line;
    this.column = column;
    this.scriptStack = scriptStack;
  }
}

export interface RunLimits {
  /** AST node evaluations. */
  maxSteps: number;
  /** Wall clock, checked every ~1000 steps. */
  timeoutMs: number;
  /** Characters. */
  maxSourceLength: number;
  /** Interpreted call depth. */
  maxCallDepth: number;
  /** Max array length / string length / object key count / Map/Set size. */
  maxCollectionSize: number;
}

export const DEFAULT_LIMITS: RunLimits = Object.freeze({
  maxSteps: 2_000_000,
  timeoutMs: 3000,
  maxSourceLength: 20_000,
  maxCallDepth: 150,
  maxCollectionSize: 100_000,
});

/** A catchable script exception in flight (script `throw`, runtime TypeError, host error). */
export class Thrown {
  constructor(
    readonly value: unknown,
    readonly kind: 'thrown' | 'runtime',
    readonly line: number | undefined,
    readonly column: number | undefined,
    readonly scriptStack: string[] | undefined,
  ) {}

  /** For host code that catches an exception thrown by a script callback. */
  get message(): string {
    const v = this.value;
    return v instanceof Error ? errorText(v) : typeof v === 'string' ? v : 'Uncaught script exception';
  }
}

export type Dict = Record<string, unknown>;
type Fn = (this: unknown, ...args: unknown[]) => unknown;
type HostClass = abstract new (...args: never[]) => unknown;
export interface CtorInfo {
  /** Host class used for `instanceof`. */
  host: HostClass;
  construct(args: unknown[]): unknown;
}
interface FnMeta {
  name: string;
  length: number;
}

/**
 * Property names that are never readable, writable or deletable, on any value. They are the
 * only ways from an ordinary value to its constructor / prototype / caller, i.e. to `Function`.
 */
const FORBIDDEN_KEYS: ReadonlySet<string> = new Set([
  'constructor',
  '__proto__',
  'prototype',
  '__defineGetter__',
  '__defineSetter__',
  '__lookupGetter__',
  '__lookupSetter__',
  'caller',
  'callee',
  'arguments',
]);

export function isForbiddenKey(key: string): boolean {
  return FORBIDDEN_KEYS.has(key);
}

const CHECK_INTERVAL = 1000;
/** Upper bound for the number of arguments of one call (spread calls); engines overflow beyond this. */
export const MAX_CALL_ARGS = 32_768;
/** Cumulative allocation budget, in units of maxCollectionSize (1 unit = 1 string char = 1/4 array slot). */
const ALLOC_BUDGET_FACTOR = 400;
/** Strings shorter than this are never treated as append accumulators (see `concatenated`). */
const APPEND_MIN = 256;

const hasOwn = Object.prototype.hasOwnProperty;
const ObjectProto: unknown = Object.prototype;
const isArray: (v: unknown) => v is unknown[] = Array.isArray;
const NO_ARGS: readonly number[] = [];

// Defence in depth: even if a host function hands these to a script they stay unusable.
const GLOBAL_OBJ: unknown = typeof globalThis === 'object' ? globalThis : undefined;
const HOST_FUNCTION: unknown = (() => 0).constructor;
const HOST_EVAL: unknown = GLOBAL_OBJ ? (GLOBAL_OBJ as Dict).eval : undefined;

// Fail loudly rather than run with sloppy-mode `this` should a build ever strip the directive.
if (
  !(function (this: unknown) {
    return this === undefined;
  })()
) {
  throw new Error('The script interpreter must be compiled as strict-mode code');
}

const ITERATOR_PROTOS: unknown[] = [
  [][Symbol.iterator](),
  new Map()[Symbol.iterator](),
  new Set()[Symbol.iterator](),
  ''[Symbol.iterator](),
].map((it) => Object.getPrototypeOf(it));

function isPlain(o: object): boolean {
  const proto: unknown = Object.getPrototypeOf(o);
  return proto === ObjectProto || proto === null;
}

function isTypedArray(o: object): o is Uint8Array {
  return ArrayBuffer.isView(o) && !(o instanceof DataView);
}

function isNativeIterator(o: object): o is Iterator<unknown> {
  return ITERATOR_PROTOS.indexOf(Object.getPrototypeOf(o)) !== -1;
}

/** Canonical array index ("0", "17", not "01" / "1.5" / "-1"). */
function isIndex(key: string): boolean {
  const n = key.length;
  if (n === 0 || n > 10) return false;
  const first = key.charCodeAt(0);
  if (first === 48) return n === 1;
  for (let i = 0; i < n; i++) {
    const c = key.charCodeAt(i);
    if (c < 48 || c > 57) return false;
  }
  return true;
}

export function isStackOverflow(e: unknown): boolean {
  return e instanceof RangeError && /call stack|stack size|stack depth|recursion/i.test(e.message);
}

export function describe(v: unknown): string {
  if (v === null) return 'null';
  if (isArray(v)) return 'an array';
  if (typeof v === 'object') {
    if (v instanceof Map) return 'a Map';
    if (v instanceof Set) return 'a Set';
    if (v instanceof Error) return 'an error object';
    return isPlain(v) ? 'an object' : 'a host object';
  }
  if (typeof v === 'string') return v.length > 30 ? 'a string' : JSON.stringify(v);
  if (typeof v === 'function') return 'a function';
  return String(v);
}

/** "Name: message" for error objects, without invoking any script code. */
export function errorText(e: Error): string {
  const name = typeof e.name === 'string' && e.name !== '' ? e.name : 'Error';
  const message = typeof e.message === 'string' ? e.message : '';
  return message === '' ? name : `${name}: ${message}`;
}

export class Runtime {
  /** Evaluated AST nodes (plus work charged by built-ins). */
  steps = 0;
  /** Step count at which the slow check (budget, clock, abort) runs next; 0 once poisoned. */
  nextCheck: number;
  depth = 0;
  /** Node being evaluated; the fallback location for errors raised without an explicit node. */
  node: Node | null = null;
  /** Completion registers: `return` value, break/continue label, last top-level expression value. */
  retVal: unknown = undefined;
  label: string | null = null;
  last: unknown = undefined;
  /** The first uncatchable error. Once set, every further step rethrows it. */
  fatal: ScriptError | null = null;
  /** Set when runScript returns; interpreted functions refuse to run afterwards. */
  done = false;
  readonly stack: string[] = [];
  readonly max: number;
  readonly maxDepth: number;
  readonly globals: Dict = Object.create(null) as Dict;
  readonly fnMeta = new WeakMap<object, FnMeta>();
  readonly statics = new Map<unknown, Dict>();
  readonly ctors = new Map<unknown, CtorInfo>();
  arrayM: Dict = Object.create(null) as Dict;
  stringM: Dict = Object.create(null) as Dict;
  numberM: Dict = Object.create(null) as Dict;
  booleanM: Dict = Object.create(null) as Dict;
  mapM: Dict = Object.create(null) as Dict;
  setM: Dict = Object.create(null) as Dict;
  fnM: Dict = Object.create(null) as Dict;
  objectM: Dict = Object.create(null) as Dict;
  errorM: Dict = Object.create(null) as Dict;

  private alloc = 0;
  private accumulator: string | null = null;
  private readonly allocBudget: number;
  private readonly deadline: number;
  private keyAdds = 0;
  private sizes: WeakMap<object, number> | null = null;

  constructor(
    readonly limits: RunLimits,
    readonly signal: { aborted: boolean } | undefined,
    started: number,
    hostGlobals: Record<string, unknown> | undefined,
  ) {
    this.max = limits.maxCollectionSize;
    this.maxDepth = limits.maxCallDepth;
    this.allocBudget = limits.maxCollectionSize * ALLOC_BUDGET_FACTOR;
    this.deadline = started + limits.timeoutMs;
    this.nextCheck = Math.min(CHECK_INTERVAL, limits.maxSteps + 1);
    installBuiltins(this, hostGlobals);
  }

  // ---------------------------------------------------------------- budget and errors

  /** Slow path of the per-node step counter. */
  check(): void {
    if (this.fatal !== null) throw this.fatal;
    if (this.steps > this.limits.maxSteps) {
      throw this.fail('limit', `Script exceeded the limit of ${this.limits.maxSteps} steps`);
    }
    if (this.signal !== undefined && this.signal.aborted) throw this.fail('aborted', 'Script was aborted');
    if (Date.now() > this.deadline) {
      throw this.fail('limit', `Script exceeded the time limit of ${this.limits.timeoutMs} ms`);
    }
    this.nextCheck = Math.min(this.steps + CHECK_INTERVAL, this.limits.maxSteps + 1);
  }

  /** Charge `n` steps for work done natively by a built-in. */
  tick(n: number): void {
    if ((this.steps += n) >= this.nextCheck) this.check();
  }

  /** Charge the cumulative allocation budget. */
  charge(units: number): void {
    if ((this.alloc += units) > this.allocBudget) {
      throw this.fail('limit', 'Script exceeded its memory budget (too many large strings or arrays were created)');
    }
  }

  /**
   * Create an uncatchable error and poison the runtime: script `catch`/`finally` never see
   * it, and should host code swallow it, the very next step throws it again.
   */
  fail(kind: 'limit' | 'aborted' | 'security', message: string, node?: Node | null): ScriptError {
    if (this.fatal !== null) return this.fatal;
    const at = node ?? this.node;
    const err = new ScriptError(kind, message, at?.loc?.start.line, at?.loc?.start.column, this.stackTrace());
    this.fatal = err;
    this.nextCheck = 0;
    return err;
  }

  tooBig(what: string, node?: Node | null): ScriptError {
    return this.fail('limit', `${what} exceeds the maximum collection size of ${this.max}`, node);
  }

  forbidden(key: string, node?: Node | null): ScriptError {
    return this.fail('security', `Access to '${key}' is not allowed in edit scripts`, node);
  }

  thrown(value: unknown, kind: 'thrown' | 'runtime', node?: Node | null): Thrown {
    const at = node ?? this.node;
    return new Thrown(value, kind, at?.loc?.start.line, at?.loc?.start.column, this.stackTrace());
  }

  typeError(message: string, node?: Node | null): Thrown {
    return this.thrown(new TypeError(message), 'runtime', node);
  }

  /** Normalise anything caught from host/native code into what should be rethrown. */
  wrap(e: unknown, node?: Node | null): unknown {
    if (e instanceof Thrown) return e;
    if (this.fatal !== null) return this.fatal;
    if (isStackOverflow(e)) {
      return this.fail('limit', 'Script exceeded the maximum nesting depth (host stack overflow)', node);
    }
    return this.thrown(e, 'runtime', node);
  }

  /** For `try`: returns the catchable exception or rethrows the uncatchable one. */
  catchable(e: unknown, node?: Node | null): Thrown {
    const w = this.wrap(e, node);
    if (w instanceof Thrown) return w;
    throw w;
  }

  finished(): ScriptError {
    return new ScriptError('aborted', 'A script function was called after the script had finished');
  }

  private stackTrace(): string[] | undefined {
    return this.stack.length === 0 ? undefined : this.stack.slice(-20).reverse();
  }

  // ---------------------------------------------------------------- conversions

  fnName(fn: object): string {
    const meta = this.fnMeta.get(fn);
    if (meta !== undefined) return meta.name;
    const name: unknown = (fn as { name?: unknown }).name;
    return typeof name === 'string' ? name : '';
  }

  /**
   * Bounded Array.prototype.join. Implicit array->string conversion multiplies sizes (an array
   * of N references to one long string), so it is never left to the engine.
   */
  join(arr: unknown[], sep: string, seen?: unknown[]): string {
    const n = arr.length;
    let total = sep.length * Math.max(0, n - 1);
    if (n > this.max || total > this.max) throw this.tooBig('String length');
    this.tick(1 + (n >> 6));
    const parts = new Array<string>(n);
    for (let i = 0; i < n; i++) {
      const el = arr[i];
      let s: string;
      if (el === null || el === undefined) s = '';
      else if (typeof el === 'string') s = el;
      else if (isArray(el)) {
        const path = seen === undefined ? [arr] : seen.concat([arr]);
        s = path.indexOf(el) !== -1 ? '' : this.join(el, ',', path);
      } else s = this.str(el);
      total += s.length;
      if (total > this.max) throw this.tooBig('String length');
      parts[i] = s;
    }
    this.charge(total);
    return parts.join(sep);
  }

  /** Guarded ToString. */
  str(v: unknown): string {
    if (typeof v === 'string') return v;
    if (typeof v === 'function') return `function ${this.fnName(v)}() { [code] }`;
    if (typeof v === 'object' && v !== null && isArray(v)) return this.join(v, ',');
    return String(v);
  }

  /** Pre-convert the values whose implicit ToPrimitive would be unbounded or leak host source. */
  prim(v: unknown): unknown {
    if (typeof v === 'object') return v !== null && isArray(v) ? this.join(v, ',') : v;
    if (typeof v === 'function') return this.str(v);
    return v;
  }

  toNum(v: unknown, node?: Node | null): number {
    if (typeof v === 'number') return v;
    try {
      return Number(this.prim(v));
    } catch (e) {
      throw this.wrap(e, node);
    }
  }

  checkStr(s: string, node?: Node | null): string {
    if (s.length > this.max) throw this.tooBig('String length', node);
    this.charge(s.length);
    return s;
  }

  /**
   * Account for a string built by `+`, `+=` or a template literal. Extending the most recent
   * large concatenation result (`out += piece` in a loop) is charged for the appended part
   * only, which is what it costs in engines with ropes or append buffers; everything else is
   * charged in full, since it may be a fresh copy that the script keeps alive.
   */
  concatenated(result: string, left: unknown, node?: Node | null): string {
    const n = result.length;
    if (n > this.max) throw this.tooBig('String length', node);
    if (n < APPEND_MIN) this.charge(n);
    else {
      this.charge(left === this.accumulator ? n - (left as string).length : n);
      this.accumulator = result;
    }
    return result;
  }

  checkArr<T extends unknown[]>(a: T, node?: Node | null): T {
    if (a.length > this.max) throw this.tooBig('Array length', node);
    this.charge(4 + a.length * 4);
    return a;
  }

  /** Normalise a computed property key; rejects symbols and the forbidden names. */
  toKey(key: unknown, node?: Node | null): string {
    let k: string;
    if (typeof key === 'string') k = key;
    else if (typeof key === 'number') return String(key);
    else if (typeof key === 'symbol') throw this.fail('security', 'Symbol property keys are not allowed', node);
    else {
      try {
        k = this.str(key);
      } catch (e) {
        throw this.wrap(e, node);
      }
    }
    if (FORBIDDEN_KEYS.has(k)) throw this.forbidden(k, node);
    return k;
  }

  // ---------------------------------------------------------------- property access

  /** Read `obj[key]`. `key` must already be validated (static keys at compile time, else toKey). */
  get(obj: unknown, key: string, node?: Node | null): unknown {
    if (typeof obj === 'object') {
      if (obj === null) throw this.typeError(`Cannot read properties of null (reading '${key}')`, node);
      if (isArray(obj)) {
        if (key === 'length') return obj.length;
        const m = this.arrayM[key];
        if (m !== undefined) return m;
        return isIndex(key) ? obj[key as unknown as number] : undefined;
      }
      const proto: unknown = Object.getPrototypeOf(obj);
      if (proto === ObjectProto || proto === null) {
        if (obj === GLOBAL_OBJ) throw this.fail('security', 'Access to the host global object is not allowed', node);
        // Own properties only; the two allow-listed Object.prototype methods are served from a table.
        return hasOwn.call(obj, key) ? (obj as Dict)[key] : this.objectM[key];
      }
      if (obj instanceof Map) return key === 'size' ? obj.size : this.mapM[key];
      if (obj instanceof Set) return key === 'size' ? obj.size : this.setM[key];
      if (obj instanceof Error) {
        if (key === 'name' || key === 'message') return obj[key];
        if (key === 'toString') return this.errorM.toString;
        if (key === 'stack') return undefined; // host stack traces are not script business
        return hasOwn.call(obj, key) ? (obj as unknown as Dict)[key] : undefined;
      }
      if (isTypedArray(obj)) {
        if (key === 'length') return obj.length;
        return isIndex(key) ? obj[key as unknown as number] : undefined;
      }
      if (obj === GLOBAL_OBJ) throw this.fail('security', 'Access to the host global object is not allowed', node);
      // Any other host object (class instance, iterator, ...): own properties, nothing inherited.
      return hasOwn.call(obj, key) ? (obj as Dict)[key] : undefined;
    }
    switch (typeof obj) {
      case 'string': {
        if (key === 'length') return obj.length;
        const m = this.stringM[key];
        if (m !== undefined) return m;
        return isIndex(key) ? obj[key as unknown as number] : undefined;
      }
      case 'function': {
        const m = this.fnM[key];
        if (m !== undefined) return m;
        if (key === 'name') return this.fnName(obj);
        if (key === 'length') {
          const meta = this.fnMeta.get(obj);
          return meta !== undefined ? meta.length : Number((obj as { length: unknown }).length) || 0;
        }
        const st = this.statics.get(obj);
        return st !== undefined ? st[key] : undefined;
      }
      case 'number':
        return this.numberM[key];
      case 'boolean':
        return this.booleanM[key];
      case 'undefined':
        throw this.typeError(`Cannot read properties of undefined (reading '${key}')`, node);
      default:
        return undefined;
    }
  }

  /** Read with a computed key (`obj[expr]`). */
  getc(obj: unknown, key: unknown, node?: Node | null): unknown {
    if (typeof key === 'number') {
      if (isArray(obj)) return key >>> 0 === key ? obj[key] : undefined;
      if (typeof obj === 'string') return key >>> 0 === key ? obj[key] : undefined;
    }
    return this.get(obj, this.toKey(key, node), node);
  }

  /** Write `obj[key] = value` with strict-mode semantics. `key` must already be validated. */
  set(obj: unknown, key: string, value: unknown, node?: Node | null): void {
    if (typeof obj !== 'object' || obj === null) {
      if (obj === null || obj === undefined) {
        throw this.typeError(`Cannot set properties of ${String(obj)} (setting '${key}')`, node);
      }
      // Functions (built-ins, host functions, script functions) and primitives are never writable.
      throw this.typeError(`Cannot set property '${key}' on ${describe(obj)}`, node);
    }
    if (isArray(obj)) {
      if (key === 'length') {
        if (typeof value !== 'number' || !(value >= 0) || value !== Math.floor(value)) {
          throw this.thrown(new RangeError('Invalid array length'), 'runtime', node);
        }
        if (value > this.max) throw this.tooBig('Array length', node);
        if (value > obj.length) this.charge((value - obj.length) * 4);
      } else if (isIndex(key)) {
        this.setIndex(obj, Number(key), value, node);
        return;
      } else {
        throw this.typeError(`Cannot set property '${key}' on an array`, node);
      }
    } else if (isPlain(obj)) {
      if (obj === GLOBAL_OBJ) throw this.fail('security', 'Access to the host global object is not allowed', node);
      if (!hasOwn.call(obj, key)) this.noteNewKey(obj, node);
    } else if (!(obj instanceof Error) || key === 'stack') {
      // Map/Set instances and non-plain host objects are read-only for scripts.
      throw this.typeError(`Cannot set property '${key}' on ${describe(obj)}`, node);
    }
    this.write(obj, key, value, node);
  }

  /** Write with a computed key. */
  setc(obj: unknown, key: unknown, value: unknown, node?: Node | null): void {
    if (typeof key === 'number' && isArray(obj) && key >>> 0 === key) this.setIndex(obj, key, value, node);
    else this.set(obj, this.toKey(key, node), value, node);
  }

  private setIndex(arr: unknown[], index: number, value: unknown, node?: Node | null): void {
    if (index >= arr.length) {
      // Growth: refuse indexes past the limit so a single write cannot create a huge sparse array.
      if (index >= this.max) throw this.tooBig('Array index', node);
      this.charge(4);
    }
    this.write(arr, index, value, node);
  }

  private write(obj: object, key: string | number, value: unknown, node?: Node | null): void {
    try {
      (obj as Dict)[key] = value; // strict mode: throws for frozen / read-only / non-extensible targets
    } catch (e) {
      throw this.wrap(e, node);
    }
  }

  /**
   * Object key-count guard. No object can exceed the limit before the whole run has added
   * that many keys, so per-object counting only starts once that has happened.
   */
  noteNewKey(obj: object, node?: Node | null): void {
    if (++this.keyAdds <= this.max) return;
    const sizes = this.sizes ?? (this.sizes = new WeakMap());
    let n = sizes.get(obj);
    if (n === undefined) n = Object.keys(obj).length;
    if (n >= this.max) throw this.tooBig('Object key count', node);
    sizes.set(obj, n + 1);
  }

  /** Account for `count` keys written by an object literal. */
  addKeys(count: number): void {
    this.keyAdds += count;
  }

  /** `delete obj[key]`. */
  del(obj: unknown, key: string, node?: Node | null): boolean {
    if (typeof obj !== 'object' || obj === null) {
      if (obj === null || obj === undefined) {
        throw this.typeError(`Cannot delete property '${key}' of ${String(obj)}`, node);
      }
      throw this.typeError(`Cannot delete property '${key}' of ${describe(obj)}`, node);
    }
    const ok = isArray(obj) ? isIndex(key) : isPlain(obj) && obj !== GLOBAL_OBJ;
    if (!ok) throw this.typeError(`Cannot delete property '${key}' of ${describe(obj)}`, node);
    if (!hasOwn.call(obj, key)) return true;
    if (!Reflect.deleteProperty(obj, key)) throw this.typeError(`Cannot delete property '${key}'`, node);
    const n = this.sizes?.get(obj);
    if (n !== undefined) this.sizes?.set(obj, n - 1);
    return true;
  }

  /** `key in obj`, restricted to own properties. */
  has(key: unknown, obj: unknown, node?: Node | null): boolean {
    const k = this.toKey(key, node);
    if ((typeof obj !== 'object' && typeof obj !== 'function') || obj === null) {
      throw this.typeError(`Cannot use 'in' operator to search for '${k}' in ${describe(obj)}`, node);
    }
    if (obj === GLOBAL_OBJ) throw this.fail('security', 'Access to the host global object is not allowed', node);
    if (obj instanceof Map || obj instanceof Set || typeof obj === 'function') return false;
    return hasOwn.call(obj, k);
  }

  /** `value instanceof ctor`, only against the sandbox constructors. */
  instanceOf(value: unknown, ctor: unknown, node?: Node | null): boolean {
    const info = this.ctors.get(ctor);
    if (info === undefined) {
      throw this.typeError("The right-hand side of 'instanceof' must be a built-in constructor in edit scripts", node);
    }
    return value instanceof info.host;
  }

  /** Own enumerable string keys, for `for…in`, spread, rest and Object.assign. */
  ownKeys(obj: unknown): string[] {
    if (obj === null || obj === undefined) return [];
    if (obj === GLOBAL_OBJ) throw this.fail('security', 'Access to the host global object is not allowed');
    const keys = Object.keys(obj);
    this.tick(1 + (keys.length >> 6));
    return keys;
  }

  // ---------------------------------------------------------------- calls and iteration

  call(fn: unknown, thisVal: unknown, args: unknown[], node: Node, text: string): unknown {
    if (typeof fn !== 'function') throw this.typeError(`${text} is not a function`, node);
    if (fn === HOST_FUNCTION || fn === HOST_EVAL) {
      throw this.fail('security', 'Calling the host Function/eval is not allowed', node);
    }
    // Errors raised inside built-ins without a location of their own are reported at the call site.
    this.node = node;
    let result: unknown;
    try {
      result = Reflect.apply(fn, thisVal, args);
    } catch (e) {
      throw this.wrap(e, node);
    }
    // A sloppy-mode host function called without a receiver could hand back `this` === global.
    if (result === GLOBAL_OBJ && result !== undefined) {
      throw this.fail('security', 'A host function returned the global object', node);
    }
    if (this.signal !== undefined && this.signal.aborted) throw this.fail('aborted', 'Script was aborted', node);
    return result;
  }

  construct(ctor: unknown, args: unknown[], node: Node, text: string): unknown {
    const info = this.ctors.get(ctor);
    if (info === undefined) {
      throw this.typeError(
        `${text} is not a constructor (only Map, Set, Array, Object, Error, TypeError and RangeError can be used with 'new' in edit scripts)`,
        node,
      );
    }
    this.node = node;
    try {
      return info.construct(args);
    } catch (e) {
      throw this.wrap(e, node);
    }
  }

  isIterable(v: unknown): boolean {
    if (typeof v === 'string') return true;
    if (typeof v !== 'object' || v === null) return false;
    return isArray(v) || v instanceof Map || v instanceof Set || isTypedArray(v) || isNativeIterator(v);
  }

  /**
   * Snapshot an iterable as an array. Only built-in iterables are accepted, so no
   * script- or host-defined iterator protocol ever runs. Arrays are returned as-is unless `copy`.
   */
  toArray(v: unknown, node?: Node | null, copy = false): unknown[] {
    if (isArray(v)) return copy ? this.checkArr(v.slice(), node) : v;
    let out: unknown[] | null = null;
    if (typeof v === 'string') {
      if (v.length > this.max) throw this.tooBig('String length', node);
      out = Array.from(v);
    } else if (typeof v === 'object' && v !== null) {
      if (v instanceof Map || v instanceof Set) {
        if (v.size > this.max) throw this.tooBig('Collection size', node);
        out = [];
        if (v instanceof Map) v.forEach((value, key) => (out as unknown[]).push([key, value]));
        else v.forEach((value) => (out as unknown[]).push(value));
      } else if (isTypedArray(v)) {
        if (v.length > this.max) throw this.tooBig('Array length', node);
        out = Array.prototype.slice.call(v) as unknown[];
      } else if (isNativeIterator(v)) {
        out = [];
        for (let r = v.next(); r.done !== true; r = v.next()) {
          out.push(r.value);
          if (out.length > this.max) throw this.tooBig('Array length', node);
        }
      }
    }
    if (out === null) throw this.typeError(`${describe(v)} is not iterable`, node);
    this.tick(1 + (out.length >> 6));
    this.charge(4 + out.length * 4);
    return out;
  }
}

// ------------------------------------------------------------------ built-ins

const MATH_NAMES =
  'abs acos acosh asin asinh atan atan2 atanh cbrt ceil clz32 cos cosh exp expm1 floor fround hypot imul log log10 log1p log2 max min pow random round sign sin sinh sqrt tan tanh trunc E LN10 LN2 LOG10E LOG2E PI SQRT1_2 SQRT2'.split(
    ' ',
  );

function installBuiltins(rt: Runtime, hostGlobals: Record<string, unknown> | undefined): void {
  const max = rt.max;
  const g = rt.globals;
  const meta = <F extends Fn>(fn: F, name: string, length = 0): F => {
    rt.fnMeta.set(fn, { name, length });
    return fn;
  };
  const statics = (fn: Fn, members: Dict): void => {
    const table = Object.create(null) as Dict;
    for (const k of Object.keys(members)) {
      const v = members[k];
      table[k] = typeof v === 'function' ? meta(v as Fn, k) : v;
    }
    rt.statics.set(fn, table);
  };
  /** Wrap a native that only takes primitives: arguments are pre-converted with the size guard. */
  const primFn = (fn: Fn): Fn =>
    function (...args: unknown[]) {
      rt.tick(1 + (args.length >> 6));
      for (let i = 0; i < args.length; i++) args[i] = rt.prim(args[i]);
      const r = fn.apply(undefined, args);
      return typeof r === 'string' ? rt.checkStr(r) : r;
    };
  /** Every function a built-in is about to invoke itself passes through here. */
  const callable = (v: unknown, what: string): Fn => {
    if (typeof v !== 'function') throw new TypeError(`${what} is not a function`);
    if (v === HOST_FUNCTION || v === HOST_EVAL) throw rt.fail('security', 'Calling the host Function/eval is not allowed');
    return v as Fn;
  };
  const relIndex = (index: unknown, length: number): number => {
    const i = Math.trunc(Number(index)) || 0;
    return i < 0 ? i + length : i;
  };

  // ---- arrays
  const AP = Array.prototype as unknown as Dict;
  interface ArrOpts {
    /** Argument positions that expect primitives (indexes, separators). */
    prim?: readonly number[];
    /** The method returns a newly allocated array. */
    fresh?: boolean;
    impl?: (this: unknown[], ...args: never[]) => unknown;
  }
  const arr = (name: string, opts: ArrOpts = {}): void => {
    const fn = opts.impl ?? AP[name];
    if (typeof fn !== 'function') return; // not available on this engine
    const primPos = opts.prim ?? NO_ARGS;
    const fresh = opts.fresh === true;
    rt.arrayM[name] = meta(function (this: unknown, ...args: unknown[]) {
      if (!isArray(this)) throw new TypeError(`Array method '${name}' called on ${describe(this)}`);
      const before = this.length;
      rt.tick(1 + (before >> 6));
      for (let i = 0; i < primPos.length; i++) {
        const p = primPos[i];
        if (p < args.length) args[p] = rt.prim(args[p]);
      }
      const r = (fn as unknown as Fn).apply(this, args);
      if (this.length > before) {
        if (this.length > max) throw rt.tooBig('Array length');
        rt.charge((this.length - before) * 4);
      }
      if (typeof r === 'string') return rt.checkStr(r);
      return fresh && isArray(r) ? rt.checkArr(r) : r;
    }, name);
  };
  const flatInto = (out: unknown[], src: unknown[], depth: number): void => {
    rt.tick(1 + (src.length >> 6));
    for (let i = 0; i < src.length; i++) {
      if (!(i in src)) continue;
      const el = src[i];
      if (depth >= 1 && isArray(el)) flatInto(out, el, depth - 1);
      else {
        out.push(el);
        if (out.length > max) throw rt.tooBig('Array length');
      }
    }
  };
  const findLastIndex = (list: unknown[], pred: unknown, thisArg: unknown): number => {
    const fn = callable(pred, 'The findLast callback');
    for (let i = list.length - 1; i >= 0; i--) {
      if (Reflect.apply(fn, thisArg, [list[i], i, list])) return i;
    }
    return -1;
  };
  for (const n of 'entries every find findIndex forEach keys pop push reduce reduceRight reverse shift some unshift values'.split(' ')) {
    arr(n);
  }
  arr('filter', { fresh: true });
  arr('map', { fresh: true });
  arr('fill', { prim: [1, 2] });
  arr('includes', { prim: [1] });
  arr('indexOf', { prim: [1] });
  arr('lastIndexOf', { prim: [1] });
  arr('slice', { prim: [0, 1], fresh: true });
  arr('splice', { prim: [0, 1], fresh: true });
  arr('at', {
    prim: [0],
    impl: function (this: unknown[], index: unknown) {
      return this[relIndex(index, this.length)];
    },
  });
  arr('findLast', {
    impl: function (this: unknown[], pred: unknown, thisArg: unknown) {
      const i = findLastIndex(this, pred, thisArg);
      return i === -1 ? undefined : this[i];
    },
  });
  arr('findLastIndex', {
    impl: function (this: unknown[], pred: unknown, thisArg: unknown) {
      return findLastIndex(this, pred, thisArg);
    },
  });
  arr('concat', {
    fresh: true,
    impl: function (this: unknown[], ...items: unknown[]) {
      let n = this.length;
      for (const item of items) n += isArray(item) ? item.length : 1;
      if (n > max) throw rt.tooBig('Array length');
      return (AP.concat as Fn).apply(this, items);
    },
  });
  arr('join', {
    impl: function (this: unknown[], sep: unknown) {
      return rt.join(this, sep === undefined ? ',' : rt.str(sep));
    },
  });
  arr('toString', {
    impl: function (this: unknown[]) {
      return rt.join(this, ',');
    },
  });
  arr('flat', {
    fresh: true,
    impl: function (this: unknown[], depth: unknown) {
      const out: unknown[] = [];
      flatInto(out, this, depth === undefined ? 1 : Number(rt.prim(depth)));
      return out;
    },
  });
  arr('flatMap', {
    fresh: true,
    impl: function (this: unknown[], callback: unknown, thisArg: unknown) {
      const fn = callable(callback, 'The flatMap callback');
      const out: unknown[] = [];
      for (let i = 0; i < this.length; i++) {
        if (!(i in this)) continue;
        const r = Reflect.apply(fn, thisArg, [this[i], i, this]);
        if (isArray(r)) for (let j = 0; j < r.length; j++) out.push(r[j]);
        else out.push(r);
        if (out.length > max) throw rt.tooBig('Array length');
      }
      return out;
    },
  });
  const sortImpl = function (this: unknown[], compare: unknown): unknown[] {
    if (compare !== undefined) callable(compare, 'The comparison function');
    rt.tick(this.length >> 2);
    // The default comparator stringifies elements; make sure that is bounded first.
    if (compare === undefined && this.some((el) => typeof el === 'object' || typeof el === 'function')) {
      rt.join(this, ',');
    }
    return (AP.sort as Fn).call(this, compare) as unknown[];
  };
  arr('sort', { impl: sortImpl });
  arr('toSorted', {
    fresh: true,
    impl: function (this: unknown[], compare: unknown) {
      return sortImpl.call(this.slice(), compare);
    },
  });
  arr('toReversed', {
    fresh: true,
    impl: function (this: unknown[]) {
      return this.slice().reverse();
    },
  });
  arr('with', {
    fresh: true,
    prim: [0],
    impl: function (this: unknown[], index: unknown, value: unknown) {
      const i = relIndex(index, this.length);
      if (i < 0 || i >= this.length) throw new RangeError('Invalid index');
      const copy = this.slice();
      copy[i] = value;
      return copy;
    },
  });

  // ---- strings
  const SP = String.prototype as unknown as Dict;
  const str = (name: string, impl?: (this: string, ...args: never[]) => unknown, search = false): void => {
    const fn = impl ?? SP[name];
    if (typeof fn !== 'function') return;
    rt.stringM[name] = meta(function (this: unknown, ...args: unknown[]) {
      if (typeof this !== 'string') throw new TypeError(`String method '${name}' called on ${describe(this)}`);
      for (let i = 0; i < args.length; i++) args[i] = rt.prim(args[i]);
      let cost = 1 + (this.length >> 8);
      const needle = args[0];
      if (search && typeof needle === 'string') cost += (this.length >> 8) * (needle.length >> 8);
      rt.tick(cost);
      const r = (fn as unknown as Fn).apply(this, args);
      if (typeof r === 'string') return rt.checkStr(r);
      return isArray(r) ? rt.checkArr(r) : r;
    }, name);
  };
  for (const n of 'charAt charCodeAt codePointAt slice substring toLowerCase toUpperCase trim trimEnd trimStart toString'.split(' ')) {
    str(n);
  }
  for (const n of 'endsWith includes indexOf lastIndexOf startsWith'.split(' ')) str(n, undefined, true);
  str('at', function (this: string, index: unknown) {
    return this[relIndex(index, this.length)];
  });
  str('concat', function (this: string, ...parts: unknown[]) {
    let total = this.length;
    const strings = parts.map((p) => {
      const s = rt.str(p);
      if ((total += s.length) > max) throw rt.tooBig('String length');
      return s;
    });
    return this + strings.join('');
  });
  str('repeat', function (this: string, count: unknown) {
    const n = Number(count);
    if (this.length * n > max) throw rt.tooBig('String length');
    return (SP.repeat as Fn).call(this, n);
  });
  for (const n of ['padStart', 'padEnd']) {
    str(n, function (this: string, length: unknown, fill: unknown) {
      if (Number(length) > max) throw rt.tooBig('String length');
      return (SP[n] as Fn).call(this, length, fill);
    });
  }
  str(
    'split',
    function (this: string, separator: unknown, limit: unknown) {
      if (separator !== undefined && typeof separator !== 'string') {
        throw new TypeError('split() only supports string separators (regular expressions are not supported in edit scripts)');
      }
      return (SP.split as Fn).call(this, separator, limit);
    },
    true,
  );
  // replace/replaceAll: string patterns only; the result size is bounded before it is built.
  const replacer = (name: string, all: boolean): void => {
    rt.stringM[name] = meta(function (this: unknown, pattern: unknown, replacement: unknown) {
      if (typeof this !== 'string') throw new TypeError(`String method '${name}' called on ${describe(this)}`);
      if (typeof pattern !== 'string') {
        throw new TypeError(`${name}() only supports string patterns (regular expressions are not supported in edit scripts)`);
      }
      const s = this;
      const step = Math.max(1, pattern.length);
      rt.tick(1 + (s.length >> 6) + (s.length >> 8) * (pattern.length >> 8));
      const matches: number[] = [];
      for (let i = s.indexOf(pattern); i !== -1 && i <= s.length; i = s.indexOf(pattern, i + step)) {
        matches.push(i);
        if (!all || i + step > s.length) break;
      }
      const fn = typeof replacement === 'function' ? callable(replacement, 'The replacement') : null;
      const text = fn === null ? rt.str(replacement) : '';
      // Each `$` in the replacement can expand to (at most) the whole subject string.
      const perMatch = text.length + (text.split('$').length - 1) * s.length;
      if (fn === null && s.length + matches.length * perMatch > max) throw rt.tooBig('String length');
      let out = '';
      let pos = 0;
      for (const at of matches) {
        const piece = fn === null ? text : rt.str(fn(pattern, at, s));
        // String.prototype.replace expands `$` patterns for string replacements; delegate that.
        out += s.slice(pos, at) + (fn === null && perMatch !== text.length ? expand(s, pattern, at, piece) : piece);
        if (out.length > max) throw rt.tooBig('String length');
        pos = at + pattern.length;
      }
      return rt.checkStr(out + s.slice(pos));
    }, name);
  };
  /** Expand `$$`, `$&`, `` $` `` and `$'` in a replacement string (no capture groups without regex). */
  const expand = (s: string, pattern: string, at: number, replacement: string): string => {
    let out = '';
    for (let i = 0; i < replacement.length; i++) {
      const c = replacement[i];
      const next = c === '$' ? replacement[i + 1] : undefined;
      if (next === '$') out += '$';
      else if (next === '&') out += pattern;
      else if (next === '`') out += s.slice(0, at);
      else if (next === "'") out += s.slice(at + pattern.length);
      else {
        out += c;
        continue;
      }
      i++;
    }
    return out;
  };
  replacer('replace', false);
  replacer('replaceAll', true);

  // ---- numbers / booleans
  const NP = Number.prototype as unknown as Dict;
  for (const n of ['toFixed', 'toPrecision', 'toString']) {
    rt.numberM[n] = meta(function (this: unknown, ...args: unknown[]) {
      if (typeof this !== 'number') throw new TypeError(`Number method '${n}' called on ${describe(this)}`);
      rt.tick(1);
      for (let i = 0; i < args.length; i++) args[i] = rt.prim(args[i]);
      return (NP[n] as Fn).apply(this, args);
    }, n);
  }
  rt.booleanM.toString = meta(function (this: unknown) {
    if (typeof this !== 'boolean') throw new TypeError(`Boolean method 'toString' called on ${describe(this)}`);
    return String(this);
  }, 'toString');

  // ---- Map / Set
  const collection = (table: Dict, Host: MapConstructor | SetConstructor, label: string, names: string, adder: string): void => {
    const proto = Host.prototype as unknown as Dict;
    for (const n of names.split(' ')) {
      const fn = proto[n] as Fn;
      table[n] = meta(function (this: unknown, ...args: unknown[]) {
        if (!(this instanceof Host)) throw new TypeError(`${label} method '${n}' called on ${describe(this)}`);
        rt.tick(n === 'forEach' ? 1 + (this.size >> 6) : 1);
        if (n === adder && this.size >= max && !this.has(args[0])) throw rt.tooBig(`${label} size`);
        return fn.apply(this, args);
      }, n);
    }
  };
  collection(rt.mapM, Map, 'Map', 'get set has delete clear forEach keys values entries', 'set');
  collection(rt.setM, Set, 'Set', 'add has delete clear forEach keys values entries', 'add');

  // ---- functions: own implementations so the native Function.prototype is never handed out
  rt.fnM.call = meta(function (this: unknown, thisArg: unknown, ...args: unknown[]) {
    rt.tick(1);
    return Reflect.apply(callable(this, 'The call() target'), thisArg, args);
  }, 'call', 1);
  rt.fnM.apply = meta(function (this: unknown, thisArg: unknown, list: unknown) {
    rt.tick(1);
    const target = callable(this, 'The apply() target');
    if (list !== null && list !== undefined && !isArray(list)) throw new TypeError('apply() expects an array of arguments');
    const args = list ?? [];
    if (args.length > MAX_CALL_ARGS) throw rt.fail('limit', 'Too many arguments in one call');
    return Reflect.apply(target, thisArg, args);
  }, 'apply', 2);
  rt.fnM.bind = meta(function (this: unknown, thisArg: unknown, ...bound: unknown[]) {
    rt.tick(1);
    const target = callable(this, 'The bind() target');
    return meta(function (...more: unknown[]) {
      return Reflect.apply(target, thisArg, bound.concat(more));
    }, `bound ${rt.fnName(target)}`);
  }, 'bind', 1);

  // ---- plain objects / errors
  rt.objectM.hasOwnProperty = meta(function (this: unknown, key: unknown) {
    const k = rt.toKey(key);
    return this !== null && this !== undefined && this !== GLOBAL_OBJ && hasOwn.call(this, k);
  }, 'hasOwnProperty', 1);
  rt.objectM.toString = meta(function (this: unknown) {
    return typeof this === 'object' && this !== null && !isArray(this) ? '[object Object]' : rt.str(this);
  }, 'toString');
  rt.errorM.toString = meta(function (this: unknown) {
    if (!(this instanceof Error)) throw new TypeError(`Error method 'toString' called on ${describe(this)}`);
    return errorText(this);
  }, 'toString');

  // ---- globals
  const def = (name: string, value: unknown): void => {
    g[name] = typeof value === 'function' ? meta(value as Fn, name, 1) : value;
  };
  def('undefined', undefined);
  def('NaN', NaN);
  def('Infinity', Infinity);

  const math: Dict = {};
  for (const name of MATH_NAMES) {
    const v = (Math as unknown as Dict)[name];
    if (typeof v === 'function') math[name] = meta(primFn(v as Fn), name);
    else if (typeof v === 'number') math[name] = v;
  }
  def('Math', Object.freeze(math));

  const numberFn = function (...args: unknown[]): number {
    return args.length === 0 ? 0 : rt.toNum(args[0]);
  };
  statics(numberFn, {
    isFinite: Number.isFinite,
    isInteger: Number.isInteger,
    isNaN: Number.isNaN,
    isSafeInteger: Number.isSafeInteger,
    parseFloat: primFn(parseFloat as Fn),
    parseInt: primFn(parseInt as Fn),
    EPSILON: Number.EPSILON,
    MAX_SAFE_INTEGER: Number.MAX_SAFE_INTEGER,
    MIN_SAFE_INTEGER: Number.MIN_SAFE_INTEGER,
    MAX_VALUE: Number.MAX_VALUE,
    MIN_VALUE: Number.MIN_VALUE,
    POSITIVE_INFINITY: Infinity,
    NEGATIVE_INFINITY: -Infinity,
    NaN: NaN,
  });
  def('Number', numberFn);
  def('String', function (...args: unknown[]): string {
    return args.length === 0 ? '' : rt.checkStr(rt.str(args[0]));
  });
  def('Boolean', (v: unknown): boolean => Boolean(v));
  def('parseFloat', primFn(parseFloat as Fn));
  def('parseInt', primFn(parseInt as Fn));
  def('isNaN', primFn(isNaN as Fn));
  def('isFinite', primFn(isFinite as Fn));

  const arrayFn = function (...args: unknown[]): unknown[] {
    const n = args[0];
    if (args.length !== 1 || typeof n !== 'number') return rt.checkArr(args);
    if (!(n >= 0) || n !== Math.floor(n)) throw new RangeError('Invalid array length');
    if (n > max) throw rt.tooBig('Array length');
    rt.tick(1 + (n >> 6));
    return rt.checkArr(new Array<unknown>(n));
  };
  statics(arrayFn, {
    isArray: Array.isArray,
    of: (...items: unknown[]): unknown[] => rt.checkArr(items),
    from: (source: unknown, mapFn?: unknown, thisArg?: unknown): unknown[] => {
      const map = mapFn === undefined ? null : callable(mapFn, 'The Array.from mapping argument');
      let out: unknown[];
      if (rt.isIterable(source)) out = rt.toArray(source, null, true);
      else if (typeof source === 'object' && source !== null) {
        // Array-like such as { length: n }
        const n = Math.max(0, Math.trunc(rt.toNum(rt.get(source, 'length'))) || 0);
        if (n > max) throw rt.tooBig('Array length');
        rt.tick(1 + (n >> 6));
        out = rt.checkArr(new Array<unknown>(n));
        for (let i = 0; i < n; i++) out[i] = rt.get(source, String(i));
      } else if (source === null || source === undefined) throw new TypeError(`${String(source)} is not iterable`);
      else out = [];
      if (map !== null) for (let i = 0; i < out.length; i++) out[i] = Reflect.apply(map, thisArg, [out[i], i]);
      return out;
    },
  });
  rt.ctors.set(arrayFn, { host: Array, construct: (args) => arrayFn(...args) });
  def('Array', arrayFn);

  const objectFn = function (v?: unknown): unknown {
    if (v === null || v === undefined) return {};
    if (typeof v === 'object' || typeof v === 'function') return v;
    throw new TypeError('Object() cannot wrap primitive values in edit scripts');
  };
  const listOwn = (native: (o: object) => unknown[], perItem: number) => (o: unknown): unknown[] => {
    if (o === null || o === undefined) throw new TypeError('Cannot convert undefined or null to object');
    if (o === GLOBAL_OBJ) throw rt.fail('security', 'Access to the host global object is not allowed');
    const out = native(Object(o) as object);
    rt.tick(1 + (out.length >> 6));
    rt.charge(out.length * 4 * perItem);
    return rt.checkArr(out);
  };
  statics(objectFn, {
    keys: listOwn(Object.keys, 0),
    values: listOwn(Object.values, 0),
    entries: listOwn(Object.entries, 3),
    // Object.assign goes through the guarded setter: forbidden keys are rejected, limits apply.
    assign: (target: unknown, ...sources: unknown[]): unknown => {
      if (target === null || target === undefined) throw new TypeError('Cannot convert undefined or null to object');
      for (const source of sources) {
        if (typeof source !== 'object' && typeof source !== 'function' && typeof source !== 'string') continue;
        for (const k of rt.ownKeys(source)) rt.set(target, rt.toKey(k), (source as Dict)[k]);
      }
      return target;
    },
    fromEntries: (entries: unknown): unknown => {
      const out: Dict = {};
      for (const entry of rt.toArray(entries)) {
        if (!isArray(entry)) throw new TypeError('Object.fromEntries expects [key, value] pairs');
        rt.set(out, rt.toKey(entry[0]), entry[1]);
      }
      return out;
    },
    freeze: (o: unknown): unknown =>
      typeof o === 'object' && o !== null && o !== GLOBAL_OBJ && (isArray(o) || isPlain(o)) ? Object.freeze(o) : o,
    hasOwn: (o: unknown, key: unknown): boolean => {
      if (o === null || o === undefined) throw new TypeError('Cannot convert undefined or null to object');
      const k = rt.toKey(key);
      return o !== GLOBAL_OBJ && hasOwn.call(o, k);
    },
  });
  rt.ctors.set(objectFn, { host: Object, construct: (args) => objectFn(args[0]) });
  def('Object', objectFn);

  const needsNew = (name: string): Fn =>
    function () {
      throw new TypeError(`Constructor ${name} requires 'new'`);
    };
  const mapFn = needsNew('Map');
  rt.ctors.set(mapFn, {
    host: Map,
    construct: (args) => {
      const m = new Map<unknown, unknown>();
      if (args[0] !== null && args[0] !== undefined) {
        for (const entry of rt.toArray(args[0])) {
          if (!isArray(entry)) throw new TypeError('The Map constructor expects [key, value] pairs');
          m.set(entry[0], entry[1]);
        }
      }
      if (m.size > max) throw rt.tooBig('Map size');
      rt.charge(m.size * 8);
      return m;
    },
  });
  def('Map', mapFn);
  const setFn = needsNew('Set');
  rt.ctors.set(setFn, {
    host: Set,
    construct: (args) => {
      const s = new Set<unknown>(args[0] === null || args[0] === undefined ? [] : rt.toArray(args[0]));
      if (s.size > max) throw rt.tooBig('Set size');
      rt.charge(s.size * 4);
      return s;
    },
  });
  def('Set', setFn);

  for (const Host of [Error, TypeError, RangeError]) {
    const make = function (message?: unknown): Error {
      return message === undefined ? new Host() : new Host(rt.str(message));
    };
    rt.ctors.set(make, { host: Host, construct: (args) => make(args[0]) });
    def(Host.name, make);
  }

  // ---- JSON (own serializer so the output size is bounded while it is produced)
  const jsonCap = max * 4;
  const stringify = (value: unknown, replacer?: unknown, space?: unknown): string | undefined => {
    let indent = '';
    if (typeof space === 'number') indent = ' '.repeat(Math.max(0, Math.min(10, Math.floor(space))));
    else if (typeof space === 'string') indent = space.slice(0, 10);
    const replace = typeof replacer === 'function' ? callable(replacer, 'The replacer') : null;
    const allow = isArray(replacer) ? new Set(replacer.map(String)) : null;
    const path: unknown[] = [];
    let size = 0;
    const count = (n: number): void => {
      if ((size += n) > jsonCap) throw rt.fail('limit', `JSON.stringify output exceeds the maximum size of ${jsonCap}`);
    };
    const ser = (holder: object, key: string, pad: string): string | undefined => {
      rt.tick(1);
      let v = (holder as Dict)[key];
      if (typeof v === 'object' && v !== null) {
        const toJSON = isArray(v) || isPlain(v) ? (hasOwn.call(v, 'toJSON') ? (v as Dict).toJSON : undefined) : (v as Dict).toJSON;
        if (typeof toJSON === 'function') v = Reflect.apply(callable(toJSON, 'toJSON'), v, [key]);
      }
      if (replace !== null) v = Reflect.apply(replace, holder, [key, v]);
      if (v === null) return count(4), 'null';
      if (typeof v === 'string') {
        const s = JSON.stringify(v);
        return count(s.length), s;
      }
      if (typeof v === 'number') {
        const s = Number.isFinite(v) ? String(v) : 'null';
        return count(s.length), s;
      }
      if (typeof v === 'boolean') return count(5), v ? 'true' : 'false';
      if (typeof v === 'bigint') throw new TypeError('Do not know how to serialize a BigInt');
      if (typeof v !== 'object') return undefined;
      if (path.indexOf(v) !== -1) throw new TypeError('Converting circular structure to JSON');
      path.push(v);
      const inner = pad + indent;
      const parts: string[] = [];
      const overhead = 2 + (indent === '' ? 0 : inner.length + 1);
      if (isArray(v)) {
        for (let i = 0; i < v.length; i++) {
          count(overhead);
          parts.push(ser(v, String(i), inner) ?? (count(4), 'null'));
        }
      } else {
        const keys = v === GLOBAL_OBJ ? [] : Object.keys(v);
        for (const k of keys) {
          if (allow !== null && !allow.has(k)) continue;
          const s = ser(v, k, inner);
          if (s === undefined) continue;
          const quoted = JSON.stringify(k);
          count(overhead + quoted.length + 2);
          parts.push(quoted + (indent === '' ? ':' : ': ') + s);
        }
      }
      path.pop();
      const open = isArray(v) ? '[' : '{';
      const close = isArray(v) ? ']' : '}';
      if (parts.length === 0) return open + close;
      return indent === '' ? open + parts.join(',') + close : `${open}\n${inner}${parts.join(`,\n${inner}`)}\n${pad}${close}`;
    };
    const out = ser({ '': value }, '', '');
    if (out !== undefined) rt.charge(out.length);
    return out;
  };
  const parse = (text: unknown, reviver?: unknown): unknown => {
    const s = rt.str(text);
    if (s.length > jsonCap) throw rt.fail('limit', `JSON.parse input exceeds the maximum size of ${jsonCap}`);
    rt.tick(1 + (s.length >> 6));
    rt.charge(s.length);
    const revive = reviver === undefined ? null : callable(reviver, 'The JSON.parse reviver');
    // "__proto__" keys are dropped: harmless as own data, but a pollution vector once copied around.
    return JSON.parse(s, function (this: unknown, key: string, value: unknown) {
      if (key === '__proto__') return undefined;
      return revive === null ? value : Reflect.apply(revive, this, [key, value]);
    });
  };
  def('JSON', Object.freeze({ parse: meta(parse, 'parse', 2), stringify: meta(stringify, 'stringify', 3) }));

  const noop = (): void => {};
  def('console', Object.freeze({ log: noop, info: noop, warn: noop, error: noop, debug: noop }));

  // Host globals last: the caller is trusted and may override e.g. `console`.
  if (hostGlobals !== undefined && hostGlobals !== null) {
    for (const name of Object.keys(hostGlobals)) g[name] = hostGlobals[name];
  }
}
