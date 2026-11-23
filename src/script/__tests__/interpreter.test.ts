import { describe, expect, it, jest } from '@jest/globals';

import { DEFAULT_LIMITS, runScript, ScriptError, type RunOptions, type ScriptErrorKind } from '../interpreter';

/** Run a script and return its value. */
function run(source: string, options?: RunOptions): unknown {
  return runScript(source, options).value;
}

/** Run a script that must fail; returns the ScriptError. */
function fail(source: string, options?: RunOptions): ScriptError {
  try {
    runScript(source, options);
  } catch (e) {
    if (!(e instanceof ScriptError)) throw new Error(`runScript threw a non-ScriptError: ${String(e)}`);
    return e;
  }
  throw new Error(`Expected the script to fail: ${source}`);
}

type Row = [source: string, expected: unknown];

function table(rows: Row[], options?: RunOptions): void {
  it.each(rows)('%s', (source, expected) => {
    expect(run(source, options)).toEqual(expected);
  });
}

function failures(rows: [source: string, kind: ScriptErrorKind, message?: RegExp][], options?: () => RunOptions): void {
  // Rows are padded to three columns: with fewer, jest passes its `done` callback as the last argument.
  it.each(rows.map(([source, kind, message]) => [source, kind, message ?? /./] as const))('%s -> %s', (source, kind, message) => {
    const error = fail(source, options?.());
    expect(error.kind).toBe(kind);
    expect(error.message).toMatch(message);
  });
}

// ---------------------------------------------------------------------------------------------

describe('result value', () => {
  table([
    ['', undefined],
    ['1 + 2', 3],
    ['1; 2; 3', 3],
    ['const a = 5; a * 2; let b = 1;', 10],
    ['return 7; 99', 7],
    ['return', undefined],
    ['if (true) { return "early" } 5', 'early'],
    ['5; if (true) { 6 }', 5],
    ['for (const x of [1, 2]) { if (x === 2) return x * 10 }', 20],
    ['let x = 1; x = 5', 5],
    ['return { ok: true, list: [1, 2] }', { ok: true, list: [1, 2] }],
  ]);

  it('reports steps and duration', () => {
    const result = runScript('let s = 0; for (let i = 0; i < 10; i++) s += i; s');
    expect(result.value).toBe(45);
    expect(result.steps).toBeGreaterThan(50);
    expect(result.steps).toBeLessThan(200);
    expect(result.durationMs).toBeGreaterThanOrEqual(0);
    expect(runScript('let s = 0; for (let i = 0; i < 10; i++) s += i; s').steps).toBe(result.steps);
  });

  it('exposes the documented default limits', () => {
    expect(DEFAULT_LIMITS).toEqual({
      maxSteps: 2_000_000,
      timeoutMs: 3000,
      maxSourceLength: 20_000,
      maxCallDepth: 150,
      maxCollectionSize: 100_000,
    });
  });
});

describe('expressions', () => {
  table([
    ['1 + 2 * 3 - 4 / 2', 5],
    ['(1 + 2) * 3', 9],
    ['2 ** 10', 1024],
    ['2 ** 3 ** 2', 512],
    ['17 % 5', 2],
    ['-7 % 3', -1],
    ['5 & 3', 1],
    ['5 | 3', 7],
    ['5 ^ 3', 6],
    ['~5', -6],
    ['1 << 4', 16],
    ['-16 >> 2', -4],
    ['-1 >>> 28', 15],
    ['0.1 + 0.2 === 0.3', false],
    ['1 < 2 && 2 <= 2 && 3 > 2 && 3 >= 3', true],
    ['"a" < "b"', true],
    ['1 == "1"', true],
    ['1 === "1"', false],
    ['null == undefined', true],
    ['null === undefined', false],
    ['1 != 2', true],
    ['1 !== 1', false],
    ['[1] == 1', true],
    ['const a = [1]; a == a', true],
    ['[1] == [1]', false],
    ['NaN === NaN', false],
    ['"5" * "2"', 10],
    ['"5" - 2', 3],
    ['"5" + 2', '52'],
    ['1 + null', 1],
    ['[1, 2] + [3]', '1,23'],
    ['+"42"', 42],
    ['-"3"', -3],
    ['+[]', 0],
    ['!0', true],
    ['!!"x"', true],
    ['typeof 1', 'number'],
    ['typeof "s"', 'string'],
    ['typeof undefined', 'undefined'],
    ['typeof null', 'object'],
    ['typeof {}', 'object'],
    ['typeof [] ', 'object'],
    ['typeof (() => 1)', 'function'],
    ['typeof Math.max', 'function'],
    ['typeof notDeclaredAnywhere', 'undefined'],
    ['void 0', undefined],
    ['true ? "a" : "b"', 'a'],
    ['0 ? "a" : "b"', 'b'],
    ['(1, 2, 3)', 3],
    ['null ?? "d"', 'd'],
    ['0 ?? "d"', 0],
    ['0 || "d"', 'd'],
    ['"" && "x"', ''],
    ['1 && 2', 2],
    ['let n = 0; false && n++; true || n++; n', 0],
    ['0x10 + 0b11 + 0o7 + 1e2 + .5', 126.5],
    ['"a\\n\\t\\u0041"', 'a\n\tA'],
    ["'single' + \"double\"", 'singledouble'],
    ['true', true],
    ['null', null],
    ['Infinity', Infinity],
    ['-Infinity', -Infinity],
    ['isNaN(NaN)', true],
    ['undefined', undefined],
  ]);
});

describe('template literals', () => {
  table([
    ['`plain`', 'plain'],
    ['const n = 3; `n=${n}, n*2=${n * 2}`', 'n=3, n*2=6'],
    ['`${1}${2}${3}`', '123'],
    ['`a${[1, 2]}b${null}c${undefined}d`', 'a1,2bnullcundefinedd'],
    ['`${{ toString() { return "custom" } }}`', 'custom'],
    ['`line1\nline2`', 'line1\nline2'],
    ['const who = "x"; `nested ${`inner ${who}`}`', 'nested inner x'],
  ]);
});

describe('variables and scoping', () => {
  table([
    ['var a = 1; var a = 2; a', 2],
    ['let a = 1; { let a = 2; } a', 1],
    ['let a = 1; { a = 2; } a', 2],
    ['const a = 1; { const a = 2; } a', 1],
    ['var x = 1; { var x = 2; } x', 2],
    ['function f() { if (true) { var v = 5; } return v; } f()', 5],
    ['function f() { return v; var v = 5; } f()', undefined],
    ['let u; u', undefined],
    ['var a = 1, b = a + 1, c = b + 1; a + b + c', 6],
    ['let x = 1; function f() { return x; } x = 2; f()', 2],
    ['const f = () => later; const later = 9; f()', 9],
    ['let a = 1; let b = 2; [a, b] = [b, a]; [a, b]', [2, 1]],
    ['let i = 5; i++; ++i; i--; i', 6],
    ['let i = 5; [i++, i, ++i, i--, --i]', [5, 6, 7, 7, 5]],
    ['let s = "5"; s++; s', 6],
    ['const o = { n: 1 }; o.n++; ++o.n; o["n"]--; o.n', 2],
    ['const a = [1, 2]; a[0]++; a[1] += 10; a', [2, 12]],
  ]);

  failures([
    ['const a = 1; a = 2', 'runtime', /TypeError: Assignment to constant variable/],
    ['const a = 1; a += 2', 'runtime', /Assignment to constant/],
    ['const a = 1; a++', 'runtime', /Assignment to constant/],
    ['const [a] = [1]; [a] = [2]', 'runtime', /Assignment to constant/],
    ['x; let x = 1', 'runtime', /ReferenceError: Cannot access 'x' before initialization/],
    ['x = 2; let x = 1', 'runtime', /before initialization/],
    ['{ f(); const y = 1; function f() { return y; } }', 'runtime', /before initialization/],
    ['undeclared = 1', 'runtime', /ReferenceError: undeclared is not defined/],
    ['undeclared', 'runtime', /ReferenceError: undeclared is not defined/],
    ['undeclared++', 'runtime', /ReferenceError: undeclared is not defined/],
    ['let a = 1; let a = 2', 'syntax'],
  ]);

  it('gives this === undefined at top level and in plain calls', () => {
    expect(run('this')).toBeUndefined();
    expect(run('function f() { return this } f()')).toBeUndefined();
    expect(run('const f = () => this; f()')).toBeUndefined();
    expect(run('[1].map(function () { return this })[0]')).toBeUndefined();
  });
});

describe('functions and closures', () => {
  table([
    ['hoisted(); function hoisted() { return "ok" }', 'ok'],
    ['const add = function (a, b) { return a + b }; add(2, 3)', 5],
    ['const add = (a, b) => a + b; add(2, 3)', 5],
    ['const sq = x => x * x; sq(7)', 49],
    ['const mk = () => ({ a: 1 }); mk()', { a: 1 }],
    ['function fact(n) { return n <= 1 ? 1 : n * fact(n - 1) } fact(10)', 3628800],
    ['const fib = (n) => (n < 2 ? n : fib(n - 1) + fib(n - 2)); fib(15)', 610],
    ['const f = function inner(n) { return n === 0 ? "done" : inner(n - 1) }; f(3)', 'done'],
    ['function counter() { let c = 0; return () => ++c } const next = counter(); next(); next(); next()', 3],
    ['function mk() { let c = 0; return { inc: () => ++c, get: () => c } } const a = mk(), b = mk(); a.inc(); a.inc(); b.inc(); [a.get(), b.get()]', [2, 1]],
    ['function f(a, b = 2, c = a + b) { return [a, b, c] } f(1)', [1, 2, 3]],
    ['function f(a, b = 2) { return [a, b] } f(1, undefined)', [1, 2]],
    ['function f(a, b = 2) { return [a, b] } f(1, null)', [1, null]],
    ['function f(a, ...rest) { return [a, rest] } f(1, 2, 3)', [1, [2, 3]]],
    ['const f = (...xs) => xs.length; f()', 0],
    ['function f({ a, b = 5 }, [c, d]) { return a + b + c + d } f({ a: 1 }, [2, 3])', 11],
    ['function f(a, b) { return b } f(1)', undefined],
    ['function f() {} f()', undefined],
    ['function f() { return } f()', undefined],
    ['const o = { v: 4, get() { return this.v } }; o.get()', 4],
    ['const o = { v: 4, get: function () { return this.v } }; o.get()', 4],
    ['const o = { v: 4, get() { return [1, 2].map((x) => x * this.v) } }; o.get()', [4, 8]],
    ['const o = { v: 4, get() { return this } }; const g = o.get; g()', undefined],
    ['function f(a, b) { return this.k + a + b } f.call({ k: 1 }, 2, 3)', 6],
    ['function f(a, b) { return this.k + a + b } f.apply({ k: 1 }, [2, 3])', 6],
    ['function f(a, b) { return this.k + a + b } const g = f.bind({ k: 1 }, 2); g(3)', 6],
    ['Math.max.apply(null, [1, 5, 3])', 5],
    ['function named(a, b, c = 1) {} [named.name, named.length]', ['named', 2]],
    ['[(({ a }, [b], c) => 0).length, ((a, ...rest) => 0).length, (() => 0).length]', [3, 1, 0]],
    ['const arrow = () => 1; arrow.name', 'arrow'],
    ['const o = { method() {} }; o.method.name', 'method'],
    ['(function () { return 5 })()', 5],
    ['(() => { let total = 0; for (const n of [1, 2, 3]) total += n; return total })()', 6],
    ['const compose = (...fns) => (x) => fns.reduceRight((acc, f) => f(acc), x); compose((x) => x + 1, (x) => x * 2)(5)', 11],
    ['function outer() { return inner(); function inner() { return "hoisted in body" } } outer()', 'hoisted in body'],
    ['let f; { function g() { return 1 } f = g; } f()', 1],
  ]);

  it('captures a fresh binding per loop iteration (let) but shares var', () => {
    expect(run('const fs = []; for (let i = 0; i < 3; i++) fs.push(() => i); fs.map((f) => f())')).toEqual([0, 1, 2]);
    expect(run('const fs = []; for (var i = 0; i < 3; i++) fs.push(() => i); fs.map((f) => f())')).toEqual([3, 3, 3]);
    expect(run('const fs = []; for (const x of [1, 2, 3]) fs.push(() => x); fs.map((f) => f())')).toEqual([1, 2, 3]);
    expect(run('const fs = []; for (const k in { a: 1, b: 2 }) fs.push(() => k); fs.map((f) => f())')).toEqual(['a', 'b']);
    expect(run('const fs = []; for (let i = 0; i < 3; i++) { const j = i * 2; fs.push(() => i + j); } fs.map((f) => f())')).toEqual([0, 3, 6]);
    expect(run('const fs = []; let i = 0; while (i < 3) { const j = i++; fs.push(() => j); } fs.map((f) => f())')).toEqual([0, 1, 2]);
    expect(run('const fs = []; for (let i = 0; i < 3; i++) { fs.push(() => i); i++; } fs.map((f) => f())')).toEqual([1, 3]);
  });

  failures([
    ['const f = 5; f()', 'runtime', /TypeError: f is not a function/],
    ['const o = {}; o.missing()', 'runtime', /TypeError: o\.missing is not a function/],
    ['undefined()', 'runtime', /is not a function/],
    ['null.x', 'runtime', /TypeError: Cannot read properties of null \(reading 'x'\)/],
    ['undefined.x', 'runtime', /Cannot read properties of undefined/],
    ['let o; o.x = 1', 'runtime', /Cannot set properties of undefined/],
  ]);
});

describe('destructuring', () => {
  table([
    ['const { a, b } = { a: 1, b: 2 }; [a, b]', [1, 2]],
    ['const { a: x, b: { c } } = { a: 1, b: { c: 3 } }; [x, c]', [1, 3]],
    ['const { a = 5, b = 6 } = { a: 1 }; [a, b]', [1, 6]],
    ['const { a, ...rest } = { a: 1, b: 2, c: 3 }; rest', { b: 2, c: 3 }],
    ['const key = "dyn"; const { [key]: v } = { dyn: 9 }; v', 9],
    ['const [a, , c] = [1, 2, 3]; [a, c]', [1, 3]],
    ['const [a, b = 7, ...rest] = [1, undefined, 3, 4]; [a, b, rest]', [1, 7, [3, 4]]],
    ['const [[a, b], { c }] = [[1, 2], { c: 3 }]; a + b + c', 6],
    ['const [x, y] = "hi"; x + y', 'hi'],
    ['const [first, second] = new Set(["p", "q"]); second + first', 'qp'],
    ['const [[k, v]] = new Map([["key", "val"]]); k + v', 'keyval'],
    ['let a, b; ({ a, b } = { a: 1, b: 2 }); a + b', 3],
    ['let a, b; [a, b = 4] = [1]; a + b', 5],
    ['const o = {}; [o.x, o["y"]] = [1, 2]; o', { x: 1, y: 2 }],
    ['const o = {}; ({ a: o.first, b: o.second } = { a: 1, b: 2 }); o', { first: 1, second: 2 }],
    ['const out = []; for (const [k, v] of Object.entries({ a: 1, b: 2 })) out.push(k + v); out', ['a1', 'b2']],
    ['const out = []; for (const { id, tags: [t] } of [{ id: 1, tags: ["x"] }]) out.push(id + t); out', ['1x']],
    ['try { throw { code: 7, detail: "d" } } catch ({ code, detail }) { return code + detail }', '7d'],
    ['const { length } = "abcd"; length', 4],
    ['const f = ({ a, b } = { a: 1, b: 2 }) => a + b; f()', 3],
  ]);

  failures([
    ['const { a } = null', 'runtime', /Cannot destructure null/],
    ['const [a] = 5', 'runtime', /is not iterable/],
    ['const [a] = {}', 'runtime', /is not iterable/],
  ]);
});

describe('statements', () => {
  table([
    ['let r; if (1 > 2) r = "a"; else if (2 > 1) r = "b"; else r = "c"; r', 'b'],
    ['let s = 0; for (let i = 0; i < 5; i++) s += i; s', 10],
    ['let s = 0; for (let i = 0, j = 10; i < j; i++, j--) s += j - i; s', 30],
    ['let i = 0; for (;;) { if (++i > 4) break } i', 5],
    ['let s = ""; for (const c of "abc") s += c.toUpperCase(); s', 'ABC'],
    ['let s = 0; for (const n of [1, 2, 3]) s += n; s', 6],
    ['let s = 0; for (const n of new Set([1, 2, 2, 3])) s += n; s', 6],
    ['const out = []; for (const [k, v] of new Map([["a", 1], ["b", 2]])) out.push(k + v); out', ['a1', 'b2']],
    ['const out = []; for (const k of new Map([["a", 1]]).keys()) out.push(k); out', ['a']],
    ['const out = []; for (const [i, v] of ["x", "y"].entries()) out.push(i + v); out', ['0x', '1y']],
    ['const out = []; for (const v of Object.values({ a: 1, b: 2 })) out.push(v); out', [1, 2]],
    ['const a = [1]; let n = 0; for (const x of a) { if (a.length < 4) a.push(x + 1); n++ } n', 4],
    ['const keys = []; for (const k in { a: 1, b: 2 }) keys.push(k); keys', ['a', 'b']],
    ['const keys = []; for (const k in ["x", "y"]) keys.push(k); keys', ['0', '1']],
    ['const keys = []; for (const k in null) keys.push(k); keys', []],
    ['let k; const seen = []; for (k in { a: 1 }) seen.push(k); k', 'a'],
    ['let x; for (x of [1, 2, 3]) {} x', 3],
    ['let i = 0; while (i < 5) i++; i', 5],
    ['let i = 0; do { i++ } while (i < 5); i', 5],
    ['let i = 10; do { i++ } while (false); i', 11],
    ['let s = 0; for (let i = 0; i < 10; i++) { if (i % 2) continue; if (i > 6) break; s += i } s', 12],
    ['let n = 0; outer: for (let i = 0; i < 5; i++) { for (let j = 0; j < 5; j++) { if (j === 2) continue outer; if (i === 3) break outer; n++ } } n', 6],
    ['let n = 0; block: { n = 1; if (n) break block; n = 2 } n', 1],
    ['let n = 0; a: b: for (;;) { n++; if (n < 3) continue a; break b } n', 3],
    ['let n = 0; outer: while (true) { do { n++; if (n > 2) break outer } while (true) } n', 3],
    ['function f(x) { switch (x) { case 1: return "one"; case 2: return "two"; default: return "many" } } [f(1), f(2), f(3)]', ['one', 'two', 'many']],
    ['const out = []; switch (2) { case 1: out.push(1); case 2: out.push(2); case 3: out.push(3); break; case 4: out.push(4) } out', [2, 3]],
    ['const out = []; switch (9) { default: out.push("d"); case 1: out.push(1) } out', ['d', 1]],
    ['const out = []; switch ("x") { case "y": out.push(1) } out', []],
    ['let r; switch (3) { case 1 + 2: { const v = "computed"; r = v; break } } r', 'computed'],
    ['let n = 0; for (const x of [1, 2, 3]) { switch (x) { case 2: continue; default: n += x } } n', 4],
    ['let s = 0; for (const x of [1, 2, 3]) { switch (x) { case 2: break; default: s += x } } s', 4],
    [';;; 5', 5],
  ]);
});

describe('exceptions', () => {
  table([
    ['try { throw new Error("boom") } catch (e) { return e.message }', 'boom'],
    ['try { throw new TypeError("bad") } catch (e) { return [e.name, e.message, String(e), e instanceof TypeError, e instanceof Error, e instanceof RangeError] }', ['TypeError', 'bad', 'TypeError: bad', true, true, false]],
    ['try { throw RangeError("no new") } catch (e) { return `${e}` }', 'RangeError: no new'],
    ['try { throw new Error("x") } catch (e) { return e.toString() }', 'Error: x'],
    ['try { throw "str" } catch (e) { return e }', 'str'],
    ['try { throw { code: 42 } } catch (e) { return e.code }', 42],
    ['try { null.x } catch (e) { return [e.name, e instanceof TypeError] }', ['TypeError', true]],
    ['try { nope() } catch (e) { return e.name }', 'ReferenceError'],
    ['try { JSON.parse("{bad") } catch (e) { return e.name }', 'SyntaxError'],
    ['try { (1).toFixed(1000) } catch (e) { return e.name }', 'RangeError'],
    ['let r = "none"; try { throw 1 } catch { r = "optional binding" } r', 'optional binding'],
    ['const log = []; try { log.push("try") } catch (e) { log.push("catch") } finally { log.push("finally") } log', ['try', 'finally']],
    ['const log = []; try { log.push("try"); throw 1 } catch (e) { log.push("catch" + e) } finally { log.push("finally") } log', ['try', 'catch1', 'finally']],
    ['const log = []; function f() { try { return "try" } finally { log.push("finally") } } [f(), log]', ['try', ['finally']]],
    ['function f() { try { return "try" } finally { return "finally" } } f()', 'finally'],
    ['function f() { try { throw 1 } catch (e) { return "catch" } finally { return "finally" } } f()', 'finally'],
    ['function f() { try { throw 1 } finally { return "swallowed" } } f()', 'swallowed'],
    ['function g() { return 1 } function f() { try { return "kept" } finally { g() } } f()', 'kept'],
    ['const log = []; try { try { throw "inner" } finally { log.push("f1") } } catch (e) { log.push(e) } log', ['f1', 'inner']],
    ['const log = []; try { try { throw "a" } catch (e) { throw e + "b" } finally { log.push("f") } } catch (e) { log.push(e) } log', ['f', 'ab']],
    ['const log = []; for (const i of [1, 2, 3]) { try { if (i === 2) continue; log.push(i) } finally { log.push("f" + i) } } log', [1, 'f1', 'f2', 3, 'f3']],
    ['const log = []; for (const i of [1, 2, 3]) { try { if (i === 2) break; log.push(i) } finally { log.push("f" + i) } } log', [1, 'f1', 'f2']],
    ['function f() { throw new Error("deep") } function g() { f() } try { g() } catch (e) { return e.message }', 'deep'],
    ['const e = new Error("m"); e.code = 5; e.message = "changed"; [e.code, e.message, e.stack]', [5, 'changed', undefined]],
    ['const e = new Error(); [e.message, e.name]', ['', 'Error']],
  ]);

  it('surfaces uncaught script throws as kind "thrown"', () => {
    expect(fail('throw new Error("boom")')).toMatchObject({ kind: 'thrown', message: 'Error: boom', line: 1, column: 0 });
    expect(fail('throw new RangeError("out")').message).toBe('RangeError: out');
    expect(fail('throw "plain"').message).toBe('plain');
    expect(fail('throw 42').message).toBe('42');
    expect(fail('throw null').message).toBe('null');
    expect(fail('throw [1, 2]').message).toBe('1,2');
    expect(fail('throw { message: "from object" }').message).toBe('from object');
    expect(fail('throw {}').message).toBe('[object Object]');
    expect(fail('try { throw new Error("first") } catch (e) { throw e }').kind).toBe('thrown');
    expect(fail('try { throw 1 } finally { 2 }').kind).toBe('thrown');
  });
});

describe('optional chaining, spread, assignment operators', () => {
  table([
    ['const o = { a: { b: 1 } }; o?.a?.b', 1],
    ['const o = null; o?.a', undefined],
    ['const o = null; o?.a.b.c', undefined],
    ['const o = undefined; o?.["a"]', undefined],
    ['const o = { a: null }; o.a?.b', undefined],
    ['const o = {}; o.f?.()', undefined],
    ['const o = null; o?.f()', undefined],
    ['const o = { f() { return this.v }, v: 3 }; o?.f()', 3],
    ['const o = { f() { return this.v }, v: 3 }; o.f?.()', 3],
    ['const f = null; f?.(1)', undefined],
    ['const o = null; (o?.a) === undefined', true],
    ['const o = { a: [1, 2] }; o?.a?.[1]', 2],
    ['let n = 0; const o = null; o?.[n++]; n', 0],
    ['const o = null; o?.a.b ?? "fallback"', 'fallback'],
    ['const a = [1, 2]; [...a, 3, ...a]', [1, 2, 3, 1, 2]],
    ['[..."ab", ...new Set([1, 1, 2]), ...new Map([["k", "v"]])]', ['a', 'b', 1, 2, ['k', 'v']]],
    ['[...[1, 2].keys(), ...new Map([["k", "v"]]).values()]', [0, 1, 'v']],
    ['Math.max(...[1, 7, 3], 5)', 7],
    ['const f = (a, b, c) => a + b + c; f(...[1, 2], 3)', 6],
    ['const o = { a: 1, b: 2 }; ({ ...o, b: 3, c: 4 })', { a: 1, b: 3, c: 4 }],
    ['({ ...null, ...undefined, ...{ a: 1 }, ..."hi" })', { 0: 'h', 1: 'i', a: 1 }],
    ['({ ...[7, 8] })', { 0: 7, 1: 8 }],
    ['let a = 10; a += 5; a -= 3; a *= 2; a /= 4; a %= 4; a **= 3; a', 8],
    ['let a = 5; a <<= 2; a >>= 1; a >>>= 1; a |= 8; a &= 12; a ^= 5; a', 9],
    ['let s = "a"; s += "b"; s += 1; s', 'ab1'],
    ['let a = null; a ??= 5; a ??= 6; a', 5],
    ['let a = 0; a ||= 7; a ||= 8; a', 7],
    ['let a = 1; a &&= 9; let b = 0; b &&= 9; [a, b]', [9, 0]],
    ['const o = { a: null, b: 1 }; o.a ??= "set"; o.b ||= "kept"; o.c ??= "new"; o', { a: 'set', b: 1, c: 'new' }],
    ['let n = 0; let a = 1; a ||= n++; a ??= n++; n', 0],
    ['const o = { n: 1 }; o.n += 2; o["n"] *= 5; o.n', 15],
    ['let a, b; a = b = 3; a + b', 6],
  ]);
});

describe('objects', () => {
  table([
    ['const a = 1, b = 2; ({ a, b })', { a: 1, b: 2 }],
    ['const k = "dyn"; ({ [k]: 1, [k + "2"]: 2, ["lit"]: 3 })', { dyn: 1, dyn2: 2, lit: 3 }],
    ['({ "quoted key": 1, 42: "num", 1.5: "frac" })', { 'quoted key': 1, 42: 'num', 1.5: 'frac' }],
    ['const o = { sum(a, b) { return a + b } }; o.sum(1, 2)', 3],
    ['const o = {}; o.a = 1; o["b"] = 2; o[3] = 3; o', { a: 1, b: 2, 3: 3 }],
    ['const o = { a: 1 }; o.missing', undefined],
    ['const o = { a: 1, b: 2 }; delete o.a; delete o["zzz"]; o', { b: 2 }],
    ['const o = { a: 1 }; ["a" in o, "b" in o, "toString" in o]', [true, false, false]],
    ['const a = [5]; [0 in a, 1 in a]', [true, false]],
    ['const o = { a: 1 }; [o.hasOwnProperty("a"), o.hasOwnProperty("b"), o.hasOwnProperty("toString")]', [true, false, false]],
    ['({}).toString()', '[object Object]'],
    ['"" + {}', '[object Object]'],
    ['const o = { toString() { return "custom" } }; "" + o + `${o}` + String(o)', 'customcustomcustom'],
    ['const o = { valueOf() { return 42 } }; o + 1', 43],
    ['const o = { length: 1, name: "n", size: 2, call: 3 }; [o.length, o.name, o.size, o.call]', [1, 'n', 2, 3]],
    ['const o = { map: 1 }; o.map', 1],
    ['const o = {}; [o.map, o.push, o.valueOf, o.isPrototypeOf]', [undefined, undefined, undefined, undefined]],
    ['const a = {}; const b = a; b.x = 1; a.x', 1],
    ['[{} instanceof Object, [] instanceof Array, [] instanceof Object, new Map() instanceof Map, new Set() instanceof Map, 5 instanceof Object]', [true, true, true, true, false, false]],
    ['Object.keys({ b: 1, a: 2 })', ['b', 'a']],
    ['Object.values({ b: 1, a: 2 })', [1, 2]],
    ['Object.entries({ a: 1 })', [['a', 1]]],
    ['Object.assign({ a: 1 }, { b: 2 }, null, { a: 3 })', { a: 3, b: 2 }],
    ['Object.assign({}, "ab", 5, [7])', { 0: 7, 1: 'b' }],
    ['const t = {}; Object.assign(t, { x: 1 }) === t', true],
    ['Object.fromEntries([["a", 1], ["b", 2]])', { a: 1, b: 2 }],
    ['Object.fromEntries(new Map([["a", 1]]))', { a: 1 }],
    ['Object.fromEntries(Object.entries({ a: 1, b: 2 }).map(([k, v]) => [k, v * 2]))', { a: 2, b: 4 }],
    ['[Object.hasOwn({ a: 1 }, "a"), Object.hasOwn({}, "toString")]', [true, false]],
    ['const o = Object.freeze({ a: 1 }); o.a', 1],
    ['new Object()', {}],
  ]);

  failures([
    ['const o = Object.freeze({ a: 1 }); o.a = 2', 'runtime', /TypeError/],
    ['const o = Object.freeze({ a: 1 }); o.b = 2', 'runtime', /TypeError/],
    ['const o = Object.freeze({ a: 1 }); delete o.a', 'runtime', /TypeError/],
    ['const a = Object.freeze([1]); a.push(2)', 'runtime', /TypeError/],
    ['const a = Object.freeze([1]); a[0] = 2', 'runtime', /TypeError/],
    ['"x" in 5', 'runtime', /Cannot use 'in' operator/],
    ['({}) instanceof (() => 1)', 'runtime', /instanceof/],
    ['({}) instanceof 5', 'runtime', /instanceof/],
    ['"abc".foo = 1', 'runtime', /Cannot set property/],
    ['const a = []; a.foo = 1', 'runtime', /Cannot set property 'foo' on an array/],
    ['new Map().x = 1', 'runtime', /Cannot set property/],
  ]);
});

describe('arrays', () => {
  table([
    ['[1, 2, 3].length', 3],
    ['const a = [1, 2, 3]; [a[0], a[2], a[3], a[-1], a["1"], a[1.5]]', [1, 3, undefined, undefined, 2, undefined]],
    ['const a = []; a[0] = "x"; a[2] = "z"; [a.length, a[1]]', [3, undefined]],
    ['const a = [1, 2, 3]; a.length = 1; a', [1]],
    ['[1, 2, 3].at(-1)', 3],
    ['[1, 2].concat([3], 4, [[5]])', [1, 2, 3, 4, [5]]],
    ['[1, 2, 3].every((x) => x > 0)', true],
    ['[0, 0, 0].fill(7, 1)', [0, 7, 7]],
    ['new Array(3).fill(0)', [0, 0, 0]],
    ['[1, 2, 3, 4].filter((x) => x % 2 === 0)', [2, 4]],
    ['[1, 2, 3].find((x) => x > 1)', 2],
    ['[1, 2, 3].findIndex((x) => x > 1)', 1],
    ['[1, 2, 3].findLast((x) => x < 3)', 2],
    ['[1, 2, 3].findLastIndex((x) => x > 5)', -1],
    ['[1, [2, [3, [4]]]].flat()', [1, 2, [3, [4]]]],
    ['[1, [2, [3, [4]]]].flat(Infinity)', [1, 2, 3, 4]],
    ['[1, 2].flatMap((x) => [x, x * 10])', [1, 10, 2, 20]],
    ['const out = []; [1, 2].forEach((x, i, arr) => out.push(x + i + arr.length)); out', [3, 5]],
    ['[1, 2, 3].includes(2)', true],
    ['[NaN].includes(NaN)', true],
    ['[1, 2, 1].indexOf(1, 1)', 2],
    ['[1, 2, 1].lastIndexOf(1)', 2],
    ['[1, 2, 3].join("-")', '1-2-3'],
    ['[1, null, undefined, [2, 3]].join()', '1,,,2,3'],
    ['[..."ab"].keys().toString === undefined', true],
    ['[1, 2, 3].map((x, i) => x * i)', [0, 2, 6]],
    ['["1", "2", "3"].map(Number)', [1, 2, 3]],
    ['[1, 4, 9].map(Math.sqrt)', [1, 2, 3]],
    ['const a = [1, 2]; [a.pop(), a]', [2, [1]]],
    ['const a = [1]; [a.push(2, 3), a]', [3, [1, 2, 3]]],
    ['[1, 2, 3, 4].reduce((acc, x) => acc + x, 0)', 10],
    ['[1, 2, 3, 4].reduce((acc, x) => acc + x)', 10],
    ['[[1, 2], [3]].reduceRight((acc, x) => acc.concat(x), [])', [3, 1, 2]],
    ['[1, 2, 3].reverse()', [3, 2, 1]],
    ['const a = [1, 2]; [a.shift(), a]', [1, [2]]],
    ['[1, 2, 3, 4].slice(1, -1)', [2, 3]],
    ['[1, 2, 3].some((x) => x > 2)', true],
    ['[3, 1, 2].sort()', [1, 2, 3]],
    ['[10, 9, 1].sort()', [1, 10, 9]],
    ['[10, 9, 1].sort((a, b) => a - b)', [1, 9, 10]],
    ['[{ n: 2 }, { n: 1 }].sort((a, b) => a.n - b.n).map((o) => o.n)', [1, 2]],
    ['["b", "a", "c"].sort((a, b) => (a < b ? 1 : -1))', ['c', 'b', 'a']],
    ['const a = [1, 2, 3, 4]; [a.splice(1, 2, "x"), a]', [[2, 3], [1, 'x', 4]]],
    ['const a = [3]; [a.unshift(1, 2), a]', [3, [1, 2, 3]]],
    ['[...[5, 6].values()]', [5, 6]],
    ['[1, [2, 3]].toString()', '1,2,3'],
    ['String([1, [2, 3]])', '1,2,3'],
    ['const a = [3, 1, 2]; [a.toSorted(), a.toSorted((x, y) => y - x), a]', [[1, 2, 3], [3, 2, 1], [3, 1, 2]]],
    ['const a = [1, 2]; [a.toReversed(), a]', [[2, 1], [1, 2]]],
    ['const a = [1, 2, 3]; [a.with(1, "x"), a.with(-1, "z"), a]', [[1, 'x', 3], [1, 2, 'z'], [1, 2, 3]]],
    ['Array.isArray([]) && !Array.isArray({})', true],
    ['Array.from("abc")', ['a', 'b', 'c']],
    ['Array.from({ length: 3 }, (_, i) => i * 2)', [0, 2, 4]],
    ['Array.from({ length: 2, 0: "a", 1: "b" })', ['a', 'b']],
    ['Array.from(new Set([1, 1, 2]))', [1, 2]],
    ['Array.from(new Map([["a", 1]]).keys())', ['a']],
    ['Array.from([1, 2], (x) => x + 1)', [2, 3]],
    ['Array.of(1, 2, 3)', [1, 2, 3]],
    ['[Array(3).length, new Array(2, 3), Array("x")]', [3, [2, 3], ['x']]],
    ['[1, 2, 3].map((x) => x * 2).filter((x) => x > 2).reduce((a, b) => a + b, 0)', 10],
    ['const m = [[1, 2], [3, 4]]; m.map((row) => row.map((x) => x * 2))', [[2, 4], [6, 8]]],
    ['const sum = (xs) => xs.reduce((a, b) => a + b, 0); const xs = [2, 4, 6]; sum(xs) / xs.length', 4],
    ['const a = [1, 2]; const m = a.map; m.call([5, 6], (x) => x + 1)', [6, 7]],
    ['[1, 2, 3].map.name', 'map'],
  ]);

  failures([
    ['[].reduce((a, b) => a + b)', 'runtime', /TypeError/],
    ['[1].map(5)', 'runtime', /TypeError/],
    ['[1].with(5, 0)', 'runtime', /RangeError/],
    ['const a = []; a.length = -1', 'runtime', /RangeError: Invalid array length/],
    ['[].push.call({ length: 0 }, 1)', 'runtime', /called on an object/],
    ['[].map.call("abc", (x) => x)', 'runtime', /called on "abc"/],
    ['[1, 2].sort(5)', 'runtime', /comparison function/],
  ]);
});

describe('strings', () => {
  table([
    ['"hello".length', 5],
    ['["abc"[0], "abc"[2], "abc"[3], "abc".at(-1), "abc".charAt(1)]', ['a', 'c', undefined, 'c', 'b']],
    ['["a".charCodeAt(0), "😀".codePointAt(0)]', [97, 128512]],
    ['"a".concat("b", 1, [2, 3])', 'ab12,3'],
    ['["hello".startsWith("he"), "hello".endsWith("lo"), "hello".includes("ell")]', [true, true, true]],
    ['["hello".indexOf("l"), "hello".lastIndexOf("l"), "hello".indexOf("z")]', [2, 3, -1]],
    ['["5".padStart(3, "0"), "5".padEnd(3, "!")]', ['005', '5!!']],
    ['"ab".repeat(3)', 'ababab'],
    ['["hello".slice(1, 3), "hello".slice(-2), "hello".substring(3, 1)]', ['el', 'lo', 'el']],
    ['"a,b,,c".split(",")', ['a', 'b', '', 'c']],
    ['"abc".split("")', ['a', 'b', 'c']],
    ['"a b c".split(" ", 2)', ['a', 'b']],
    ['"abc".split()', ['abc']],
    ['["MiXed".toLowerCase(), "MiXed".toUpperCase()]', ['mixed', 'MIXED']],
    ['["  x ".trim(), "  x ".trimStart(), "  x ".trimEnd()]', ['x', 'x ', '  x']],
    ['"x".toString()', 'x'],
    ['"a-b-c".replace("-", "+")', 'a+b-c'],
    ['"a-b-c".replaceAll("-", "+")', 'a+b+c'],
    ['"a-b-c".replaceAll("-", (m, i) => `[${i}]`)', 'a[1]b[3]c'],
    ['"a-b".replace("-", (m) => m + m)', 'a--b'],
    ['"abc".replace("zzz", "y")', 'abc'],
    ['"abc".replaceAll("", "-")', '-a-b-c-'],
    ['"aaa".replaceAll("aa", "b")', 'ba'],
    ['"x-y".replace("-", "[$&][$$][$`][$\'][$1]")', "x[-][$][x][y][$1]y"],
    ['"hello world".split(" ").map((w) => w[0].toUpperCase() + w.slice(1)).join(" ")', 'Hello World'],
    ['String(123) + String(true) + String(null) + String(undefined) + String()', '123truenullundefined'],
    ['"abc".foo', undefined],
    ['["b", "a"].sort().join("")', 'ab'],
    ['"abc".slice.call("xyz", 1)', 'yz'],
  ]);

  failures([
    ['"abc".split(5)', 'runtime', /split\(\) only supports string separators/],
    ['"abc".replace(5, "x")', 'runtime', /replace\(\) only supports string patterns/],
    ['"abc".replaceAll({}, "x")', 'runtime', /replaceAll\(\) only supports string patterns/],
    ['"abc".match("a")', 'runtime', /is not a function/],
    ['"abc".repeat(-1)', 'runtime', /RangeError/],
    ['"abc".slice.call(5, 1)', 'runtime', /called on 5/],
  ]);
});

describe('numbers, Math, JSON', () => {
  table([
    ['(3.14159).toFixed(2)', '3.14'],
    ['(1234.5678).toPrecision(6)', '1234.57'],
    ['(255).toString(16)', 'ff'],
    ['(5).toString()', '5'],
    ['true.toString()', 'true'],
    ['const n = 2.5; n.toFixed(0)', '3'],
    ['[Number("42"), Number(""), Number("x"), Number(null), Number([5]), Number()]', [42, 0, NaN, 0, 5, 0]],
    ['[Number.isFinite(1), Number.isFinite("1"), Number.isInteger(5.0), Number.isNaN(NaN), Number.isSafeInteger(2 ** 53)]', [true, false, true, true, false]],
    ['[Number.parseFloat("1.5x"), Number.parseInt("42px", 10), parseFloat("2.5"), parseInt("ff", 16)]', [1.5, 42, 2.5, 255]],
    ['[Number.MAX_SAFE_INTEGER, Number.MIN_SAFE_INTEGER, Number.EPSILON > 0, Number.MAX_VALUE > 1e300, Number.MIN_VALUE > 0]', [9007199254740991, -9007199254740991, true, true, true]],
    ['[isNaN("x"), isFinite("5"), isFinite(Infinity)]', [true, true, false]],
    ['[Boolean(0), Boolean("x"), Boolean([])]', [false, true, true]],
    ['[Math.min(3, 1, 2), Math.max(3, 1, 2), Math.abs(-5), Math.round(2.5), Math.floor(-1.5), Math.ceil(1.2), Math.trunc(-1.7), Math.sign(-3)]', [1, 3, 5, 3, -2, 2, -1, -1]],
    ['[Math.sqrt(16), Math.cbrt(27), Math.pow(2, 8), Math.hypot(3, 4), Math.log2(8), Math.log10(1000), Math.exp(0), Math.atan2(0, 1)]', [4, 3, 256, 5, 3, 3, 1, 0]],
    ['[Math.PI > 3.14, Math.E > 2.71, Math.SQRT2 > 1.41, Math.LN2 > 0.69]', [true, true, true, true]],
    ['const r = Math.random(); r >= 0 && r < 1', true],
    ['Math.max()', -Infinity],
    ['Math.max(...[1, 2, 3].map((x) => x * 2))', 6],
    ['const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v)); [clamp(5, 0, 3), clamp(-1, 0, 3), clamp(2, 0, 3)]', [3, 0, 2]],
    ['JSON.stringify({ a: 1, b: [true, null, "s"], c: undefined, d: () => 1 })', '{"a":1,"b":[true,null,"s"]}'],
    ['JSON.stringify([undefined, () => 1, NaN, Infinity])', '[null,null,null,null]'],
    ['JSON.stringify("he said \\"hi\\"")', '"he said \\"hi\\""'],
    ['JSON.stringify({ a: [1, { b: 2 }], e: {}, f: [] }, null, 2)', JSON.stringify({ a: [1, { b: 2 }], e: {}, f: [] }, null, 2)],
    ['JSON.stringify({ a: 1, b: 2, c: 3 }, ["a", "c"])', '{"a":1,"c":3}'],
    ['JSON.stringify({ a: 1, b: "x" }, (k, v) => (typeof v === "number" ? v * 2 : v))', '{"a":2,"b":"x"}'],
    ['JSON.stringify({ toJSON() { return { replaced: true } } })', '{"replaced":true}'],
    ['JSON.stringify(new Map([["a", 1]]))', '{}'],
    ['JSON.stringify(undefined)', undefined],
    ['JSON.stringify(5) + JSON.stringify(null)', '5null'],
    ['JSON.parse("{\\"a\\":[1,2,{\\"b\\":null}]}")', { a: [1, 2, { b: null }] }],
    ['JSON.parse("[1, 2]", (k, v) => (typeof v === "number" ? v + 1 : v))', [2, 3]],
    ['const o = { n: 1, list: [1, "two", { three: 3 }], nested: { ok: true } }; JSON.parse(JSON.stringify(o))', { n: 1, list: [1, 'two', { three: 3 }], nested: { ok: true } }],
    ['const o = JSON.parse("{\\"a\\":1}"); o.b = 2; Object.keys(o)', ['a', 'b']],
  ]);

  failures([
    ['const o = {}; o.self = o; JSON.stringify(o)', 'runtime', /circular/],
    ['JSON.parse("nope")', 'runtime', /SyntaxError/],
    ['(1).toFixed.call("x", 1)', 'runtime', /TypeError/],
    ['Math.PI = 3', 'runtime', /TypeError/],
    ['Math.extra = 3', 'runtime', /TypeError/],
    ['JSON.parse = null', 'runtime', /TypeError/],
  ]);
});

describe('Map and Set', () => {
  table([
    ['const m = new Map(); m.set("a", 1).set("b", 2); [m.size, m.get("a"), m.get("zz"), m.has("b"), m.delete("a"), m.size]', [2, 1, undefined, true, true, 1]],
    ['const m = new Map([["a", 1], ["b", 2]]); [[...m.keys()], [...m.values()], [...m.entries()], [...m]]', [['a', 'b'], [1, 2], [['a', 1], ['b', 2]], [['a', 1], ['b', 2]]]],
    ['const m = new Map([["a", 1]]); const out = []; m.forEach((v, k) => out.push(k + v)); out', ['a1']],
    ['const m = new Map([["a", 1]]); m.clear(); m.size', 0],
    ['const k = {}; const m = new Map([[k, "obj"]]); m.get(k)', 'obj'],
    ['const m = new Map(new Map([["a", 1]])); m.get("a")', 1],
    ['const s = new Set([1, 2, 2]); s.add(3).add(1); [s.size, s.has(2), s.delete(2), s.has(2), [...s]]', [3, true, true, false, [1, 3]]],
    ['const s = new Set("hello"); [...s].join("")', 'helo'],
    ['const s = new Set([1, 2]); const out = []; s.forEach((v) => out.push(v * 2)); out', [2, 4]],
    ['const s = new Set([1]); [[...s.values()], [...s.keys()], [...s.entries()]]', [[1], [1], [[1, 1]]]],
    ['[...new Set([3, 1, 3, 2])].sort((a, b) => a - b)', [1, 2, 3]],
    ['const counts = new Map(); for (const w of ["a", "b", "a"]) counts.set(w, (counts.get(w) ?? 0) + 1); Object.fromEntries(counts)', { a: 2, b: 1 }],
    ['const m = new Map(); [m.foo, typeof m.get, new Set().size]', [undefined, 'function', 0]],
  ]);

  failures([
    ['Map()', 'runtime', /requires 'new'/],
    ['new Map([1, 2])', 'runtime', /pairs/],
    ['new Map().get.call({}, 1)', 'runtime', /called on an object/],
    ['new (() => 1)()', 'runtime', /is not a constructor/],
    ['const F = function () {}; new F()', 'runtime', /F is not a constructor/],
    ['new Math.max()', 'runtime', /is not a constructor/],
  ]);
});

// ---------------------------------------------------------------------------------------------

describe('host globals', () => {
  it('calls host functions with plain host values and returns their results as-is', () => {
    const received: unknown[] = [];
    const shared = { tag: 'host object' };
    const api = {
      record: (...args: unknown[]) => {
        received.push(...args);
        return shared;
      },
    };
    const result = run('const r = api.record({ a: [1, 2], nested: { ok: true } }, [1, "x"], 5, "s", null); r', { globals: { api } });
    expect(result).toBe(shared);
    expect(received).toEqual([{ a: [1, 2], nested: { ok: true } }, [1, 'x'], 5, 's', null]);
    expect(Array.isArray(received[1])).toBe(true);
    expect(Object.getPrototypeOf(received[0])).toBe(Object.prototype);
  });

  it('passes interpreted callbacks that the host can call', () => {
    const api = { twice: (fn: (n: number) => number, n: number) => fn(fn(n)) };
    expect(run('api.twice((n) => n * 3, 2)', { globals: { api } })).toBe(18);
  });

  it('lets host code see a message when a script callback throws', () => {
    const api = {
      attempt: (fn: () => unknown) => {
        try {
          return fn();
        } catch (e) {
          return `host caught: ${(e as { message: string }).message}`;
        }
      },
    };
    expect(run('api.attempt(() => { throw new RangeError("inner") })', { globals: { api } })).toBe('host caught: RangeError: inner');
    expect(run('api.attempt(() => { throw "text" })', { globals: { api } })).toBe('host caught: text');
    expect(run('api.attempt(() => null.x)', { globals: { api } })).toMatch(/^host caught: TypeError: Cannot read properties of null/);
  });

  it('binds this to the object for host methods', () => {
    const api = {
      value: 42,
      read(this: { value: number }) {
        return this.value;
      },
      nested: {
        name: 'inner',
        who(this: { name: string }) {
          return this.name;
        },
      },
    };
    expect(run('[api.read(), api.nested.who(), api["read"]()]', { globals: { api } })).toEqual([42, 'inner', 42]);
  });

  it('reads nested data and host functions as globals', () => {
    const globals = { config: { depth: { value: [1, 2, 3] } }, double: (n: number) => n * 2, answer: 42 };
    expect(run('double(config.depth.value[2]) + answer', { globals })).toBe(48);
    expect(run('Object.keys(config)', { globals })).toEqual(['depth']);
  });

  it('lets scripts catch host errors, keeping name and message', () => {
    const api = {
      fail: () => {
        throw new RangeError('exposureEV must be between -5 and 5');
      },
    };
    expect(run('try { api.fail() } catch (e) { return [e.name, e.message, e instanceof RangeError, String(e)] }', { globals: { api } })).toEqual([
      'RangeError',
      'exposureEV must be between -5 and 5',
      true,
      'RangeError: exposureEV must be between -5 and 5',
    ]);
  });

  it('surfaces uncaught host errors as kind "runtime" at the call site', () => {
    const api = {
      fail: () => {
        throw new RangeError('exposureEV must be between -5 and 5');
      },
    };
    const error = fail('const a = 1;\n  api.fail(a);', { globals: { api } });
    expect(error).toMatchObject({ kind: 'runtime', message: 'RangeError: exposureEV must be between -5 and 5', line: 2, column: 2 });
    expect(fail('api.fail2()', { globals: { api: { fail2: () => { throw 'a string'; } } } })).toMatchObject({ kind: 'runtime', message: 'a string' });
  });

  it('propagates host errors thrown inside native callbacks', () => {
    const api = {
      check: (n: number) => {
        if (n > 1) throw new Error('too big');
        return n;
      },
    };
    expect(fail('[1, 2].map((n) => api.check(n))', { globals: { api } })).toMatchObject({ kind: 'runtime', message: 'Error: too big' });
    expect(run('try { [1, 2].map(api.check) } catch (e) { return e.message }', { globals: { api } })).toBe('too big');
  });

  it('uses the supplied console and falls back to a no-op console', () => {
    const lines: unknown[][] = [];
    const console = { log: (...args: unknown[]) => void lines.push(args) };
    run('console.log("a", 1, { b: 2 })', { globals: { console } });
    expect(lines).toEqual([['a', 1, { b: 2 }]]);
    expect(run('console.log("x"); console.info(1); console.warn(2); console.error(3); console.debug(4); "fine"')).toBe('fine');
  });

  it('does not let scripts rebind or redeclare globals', () => {
    const globals = { photo: { current: 1 } };
    expect(fail('photo = 1', { globals })).toMatchObject({ kind: 'runtime', message: expect.stringMatching(/^TypeError: .*photo/) });
    expect(fail('Math = 1').message).toMatch(/TypeError/);
    expect(fail('undefined = 1').message).toMatch(/TypeError/);
    expect(fail('photo += 1', { globals }).message).toMatch(/TypeError/);
    expect(fail('[photo] = [1]', { globals }).message).toMatch(/TypeError/);
    expect(fail('let photo = 1', { globals }).kind).toBe('syntax');
    expect(fail('var Math = 1').kind).toBe('syntax');
    expect(fail('function JSON() {}').kind).toBe('syntax');
    expect(fail('const { console } = {}').kind).toBe('syntax');
    expect(globals.photo.current).toBe(1);
    // Shadowing in an inner scope is ordinary JavaScript and fine.
    expect(run('function f(photo) { return photo + 1 } f(1)', { globals })).toBe(2);
    expect(run('{ const Math = { max: () => "shadow" }; return Math.max() }')).toBe('shadow');
  });

  it('cannot mutate frozen host objects', () => {
    const photo = Object.freeze({ current: Object.freeze({ value: 1, list: Object.freeze([1, 2]), adjust: () => 1 }) });
    const globals = { photo };
    for (const source of [
      'photo.current = 1',
      'photo.extra = 1',
      'photo.current.value = 2',
      'photo.current.value += 1',
      'photo.current.value++',
      'photo.current.list[0] = 9',
      'photo.current.list.push(3)',
      'photo.current.list.length = 0',
      'delete photo.current.value',
      'Object.assign(photo.current, { value: 2 })',
      'photo.current.adjust.extra = 1',
      'photo.current.list.sort()',
    ]) {
      const error = fail(source, { globals });
      expect([source, error.kind, /TypeError/.test(error.message)]).toEqual([source, 'runtime', true]);
    }
    expect(photo.current).toEqual({ value: 1, list: [1, 2], adjust: expect.any(Function) });
    expect(run('try { photo.current.value = 2 } catch (e) { return e.name }', { globals })).toBe('TypeError');
  });

  it('only exposes own properties of non-plain host objects and keeps them read-only', () => {
    class Thing {
      own = 'visible';
      method() {
        return 'inherited';
      }
    }
    const globals = { thing: new Thing(), when: new Date(0), bytes: new Uint8Array([7, 8, 9]) };
    expect(run('[thing.own, thing.method, when.getTime, when.toISOString]', { globals })).toEqual(['visible', undefined, undefined, undefined]);
    expect(fail('thing.own = 1', { globals })).toMatchObject({ kind: 'runtime' });
    expect(run('[bytes.length, bytes[1], [...bytes], Array.from(bytes), bytes.map]', { globals })).toEqual([3, 8, [7, 8, 9], [7, 8, 9], undefined]);
    expect(run('let s = 0; for (const b of bytes) s += b; s', { globals })).toBe(24);
    expect(fail('bytes[0] = 1', { globals }).kind).toBe('runtime');
  });

  it('refuses to run script functions after the script has finished', () => {
    let saved: (() => unknown) | undefined;
    const api = { keep: (fn: () => unknown) => void (saved = fn) };
    const value = run('api.keep(() => 42); (x) => x', { globals: { api } }) as (x: number) => number;
    expect(() => saved?.()).toThrow(ScriptError);
    expect(() => value(1)).toThrow(/after the script had finished/);
  });

  it('runs the realistic edit script against a fake photo API', () => {
    const state = { global: { exposureEV: 0.5 } };
    const image = {
      getHistogram: jest.fn(() => ({ highlightClipping: 0.05 })),
      getState: jest.fn(() => state),
      adjust: jest.fn(),
      curves: { set: jest.fn() },
      grading: { set: jest.fn() },
      hsl: { adjust: jest.fn() },
      commit: jest.fn(),
    };
    const source = `
const image = photo.current;
const histogram = image.getHistogram();
const current = image.getState();
image.adjust({
  exposureEV: histogram.highlightClipping > 0.03 ? current.global.exposureEV - 0.2 : current.global.exposureEV,
  highlights: -40, shadows: 18, contrast: 10, vibrance: 8
});
image.curves.set("rgb", [[0.00, 0.025],[0.25, 0.21],[0.50, 0.50],[0.75, 0.80],[1.00, 0.985]]);
for (const [range, hue, sat] of [["shadows", 220, 0.10], ["highlights", 38, 0.07]]) {
  image.grading.set(range, { hue, saturation: sat });
}
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
image.hsl.adjust("blue", { saturation: clamp(-8 * 1.5, -100, 100), luminance: -5 });
image.commit();
return { ok: true, stops: Number((current.global.exposureEV - 0.2).toFixed(2)) };
`;
    const result = runScript(source, { globals: { photo: { current: image } } });
    expect(result.value).toEqual({ ok: true, stops: 0.3 });
    expect(image.getHistogram).toHaveBeenCalledTimes(1);
    expect(image.getState).toHaveBeenCalledTimes(1);
    expect(image.adjust).toHaveBeenCalledTimes(1);
    expect(image.adjust).toHaveBeenCalledWith({ exposureEV: 0.3, highlights: -40, shadows: 18, contrast: 10, vibrance: 8 });
    expect(image.curves.set).toHaveBeenCalledWith('rgb', [
      [0, 0.025],
      [0.25, 0.21],
      [0.5, 0.5],
      [0.75, 0.8],
      [1, 0.985],
    ]);
    expect(image.grading.set.mock.calls).toEqual([
      ['shadows', { hue: 220, saturation: 0.1 }],
      ['highlights', { hue: 38, saturation: 0.07 }],
    ]);
    expect(image.hsl.adjust).toHaveBeenCalledWith('blue', { saturation: -12, luminance: -5 });
    expect(image.commit).toHaveBeenCalledTimes(1);
    expect(image.commit.mock.contexts[0]).toBe(image);
    expect(image.curves.set.mock.contexts[0]).toBe(image.curves);
    expect(result.steps).toBeLessThan(500);
  });
});

// ---------------------------------------------------------------------------------------------

describe('security', () => {
  const PROTOTYPES: [string, object][] = [
    ['Object.prototype', Object.prototype],
    ['Array.prototype', Array.prototype],
    ['Function.prototype', Function.prototype],
    ['String.prototype', String.prototype],
    ['Number.prototype', Number.prototype],
    ['Map.prototype', Map.prototype],
    ['Error.prototype', Error.prototype],
    ['globalThis', globalThis],
    ['Math', Math],
    ['JSON', JSON],
    ['Object', Object],
    ['Array', Array],
  ];
  const snapshot = (): string => PROTOTYPES.map(([name, o]) => `${name}:${Object.getOwnPropertyNames(o).sort().join(',')}`).join('\n');

  const makeGlobals = () => {
    const calls: string[] = [];
    const adjust = (...args: unknown[]) => {
      calls.push(JSON.stringify(args));
    };
    return {
      calls,
      globals: {
        photo: Object.freeze({ current: Object.freeze({ adjust, meta: Object.freeze({ iso: 100 }) }) }),
        console: Object.freeze({ log: () => undefined }),
        touch: () => void calls.push('touch'),
        leakGlobal: function (this: unknown) {
          return globalThis;
        },
        hostFunctionCtor: Function,
        box: { fn: Function, ev: globalThis.eval },
      } as Record<string, unknown>,
    };
  };

  /** 'security' | 'runtime' | 'unsupported' | 'syntax' = must fail with that kind; anything else = must return exactly that value. */
  type Outcome = { kind: ScriptErrorKind } | { value: unknown };
  const sec: Outcome = { kind: 'security' };
  const rte: Outcome = { kind: 'runtime' };
  const undef: Outcome = { value: undefined };

  const attempts: [string, Outcome][] = [
    // --- the constructor / prototype chain, by every syntactic route
    ['[].map.constructor', sec],
    ['(() => 1).constructor', sec],
    ['"".constructor', sec],
    ['(5).constructor', sec],
    ['true.constructor', sec],
    ['({}).constructor', sec],
    ['({}).toString.constructor', sec],
    ['[]["con" + "structor"]', sec],
    ['const k = "constructor"; [][k][k]("return this")()', sec],
    ['Math.max.constructor', sec],
    ['Math.constructor', sec],
    ['JSON.stringify.constructor', sec],
    ['console.log.constructor', sec],
    ['photo.current.adjust.constructor', sec],
    ['photo.current.adjust["constructor"]', sec],
    ['Object.keys.call.constructor', sec],
    ['[].map.bind.apply.constructor', sec],
    ['new Map().get.constructor', sec],
    ['new Map().constructor', sec],
    ['[].keys().constructor', sec],
    ['try { null.x } catch (e) { e.constructor }', sec],
    ['const k = "constructor"; try { null.x } catch (e) { e[k] }', sec],
    ['const k = "constructor"; try { photo.current.nope() } catch (e) { return e[k] }', sec],
    ['[].__proto__', sec],
    ['({}).__proto__', sec],
    ['({})["__pro" + "to__"]', sec],
    ['(() => 1)["__proto__"]', sec],
    ['"".__proto__', sec],
    ['Array.prototype', sec],
    ['Object.prototype', sec],
    ['Map.prototype', sec],
    ['Error.prototype', sec],
    ['(function () {}).prototype', sec],
    ['const k = "prototype"; Object[k]', sec],
    ['function f() { return f.caller } f()', sec],
    ['function f() { return f.arguments } f()', sec],
    ['function f() { return f["caller"] } f()', sec],
    ['({}).callee', sec],
    ['({}).__defineGetter__', sec],
    ['({})["__defineSetter__"]("x", () => 1)', sec],
    ['({}).__lookupGetter__', sec],
    ['({})["__lookupSetter__"]', sec],
    ['const o = null; o?.constructor', sec],
    ['const o = {}; o?.["constructor"]', sec],
    ['const o = {}; o?.["__proto__"]?.x', sec],
    ['[].map?.["constructor"]', sec],
    // --- writes and deletes
    ['Array.prototype.x = 1', sec],
    ['Object.prototype.polluted = 1', sec],
    ['const o = {}; o.__proto__ = { polluted: 1 }', sec],
    ['const o = {}; o["__proto__"] = { polluted: 1 }', sec],
    ['const o = {}; o.constructor = 1', sec],
    ['const o = {}; o["__proto__"]["polluted"] = 1', sec],
    ['const k = "__proto__"; const o = {}; o[k] ??= {}', sec],
    ['const k = "__proto__"; const o = {}; o[k]++', sec],
    ['[]["__proto__"]["polluted"] = 1', sec],
    ['delete ({}).constructor', sec],
    ['delete []["__proto__"]', sec],
    ['const k = "prototype"; delete Object[k]', sec],
    ['[].map.x = 1', rte],
    ['Math.max.x = 1', rte],
    ['(() => 1).x = 1', rte],
    ['Object.keys.polluted = 1', rte],
    ['Object.assign = null', rte],
    ['Object.assign([].map, { polluted: 1 })', rte],
    ['Object.assign(Math, { polluted: 1 })', rte],
    ['Object.assign(Object, { polluted: 1 })', rte],
    ['[].push.call(Math.max, 1)', rte],
    ['Object.freeze(Math.max); Object.freeze(Object); "frozen nothing"', { value: 'frozen nothing' }],
    // --- object literals, patterns, `in`
    ['({ constructor: 1 })', sec],
    ['({ __proto__: null })', sec],
    ['({ "__proto__": { polluted: 1 } })', sec],
    ['({ ["__proto__"]: { polluted: 1 } })', sec],
    ['const k = "__proto__"; ({ [k]: { polluted: 1 } })', sec],
    ['({ prototype: 1 })', sec],
    ['({ constructor() {} })', sec],
    ['const { constructor } = {}', sec],
    ['const { constructor: c } = []', sec],
    ['const { __proto__: p } = {}', sec],
    ['const k = "constructor"; const { [k]: c } = {}', sec],
    ['let c; ({ constructor: c } = () => 1)', sec],
    ['function f({ constructor: c }) { return c } f(1)', sec],
    ['for (const { constructor: c } of [1]) {}', sec],
    ['try { throw 1 } catch ({ constructor: c }) {}', sec],
    ['"constructor" in {}', sec],
    ['"__proto__" in []', sec],
    ['const k = "constructor"; k in Math', sec],
    ['({}).hasOwnProperty("constructor")', sec],
    ['Object.hasOwn({}, "__proto__")', sec],
    ['({}).hasOwnProperty.call(photo, "constructor")', sec],
    // --- prototype pollution through data
    ['JSON.parse(\'{"__proto__":{"polluted":1}}\').polluted', undef],
    ['Object.keys(JSON.parse(\'{"__proto__":{"polluted":1},"ok":1}\'))', { value: ['ok'] }],
    ['const o = Object.assign({}, JSON.parse(\'{"__proto__":{"polluted":1}}\')); [o.polluted, ({}).polluted, Object.keys(o).length]', { value: [undefined, undefined, 0] }],
    ['const o = { ...JSON.parse(\'{"__proto__":{"polluted":1}}\') }; [o.polluted, ({}).polluted]', { value: [undefined, undefined] }],
    ['JSON.parse(\'{"a":{"\\\\u005f_proto__":{"polluted":1}}}\').a.polluted', undef],
    ['Object.assign({}, JSON.parse(\'{"constructor":{"prototype":{"polluted":1}}}\'))', sec],
    ['({ ...JSON.parse(\'{"constructor":1}\') })', sec],
    ['const { a, ...rest } = JSON.parse(\'{"a":1,"prototype":2}\')', sec],
    ['Object.fromEntries([["__proto__", { polluted: 1 }]])', sec],
    ['Object.fromEntries([["constructor", 1]])', sec],
    ['Object.assign({}, { a: 1 }, null).a', { value: 1 }],
    ['const data = JSON.parse(\'{"constructor":1}\'); Object.entries(data)', { value: [['constructor', 1]] }],
    // --- nothing but the allow-listed globals exists
    ...['globalThis', 'window', 'global', 'self', 'Function', 'eval', 'require', 'process', 'Reflect', 'Proxy', 'Symbol', 'Promise', 'setTimeout', 'setInterval', 'fetch', 'RegExp', 'Date', 'WeakMap', 'WeakRef', 'Uint8Array', 'ArrayBuffer', 'Buffer', 'module', 'exports', 'jest', 'BigInt', 'Intl', 'queueMicrotask', 'XMLHttpRequest'].flatMap(
      (name): [string, Outcome][] => [
        [name, rte],
        [`typeof ${name}`, { value: 'undefined' }],
        [`${name} = 1`, rte],
      ],
    ),
    ['new Function("return this")()', rte],
    ['eval("1")', rte],
    ['Function("return 1")', rte],
    ['new Date()', rte],
    ['new RegExp("a")', rte],
    // --- the Object / Array / Math / JSON surface is the allow-list only
    ...['getPrototypeOf', 'setPrototypeOf', 'defineProperty', 'defineProperties', 'create', 'getOwnPropertyDescriptor', 'getOwnPropertyDescriptors', 'getOwnPropertyNames', 'getOwnPropertySymbols', 'preventExtensions', 'seal'].flatMap(
      (name): [string, Outcome][] => [
        [`Object.${name}`, undef],
        [`Object["${name}"]`, undef],
      ],
    ),
    ['Object.getPrototypeOf([])', rte],
    ['Object.defineProperty({}, "x", { value: 1 })', rte],
    ['Object.defineProperty({}, "x", { get: () => 1 })', rte],
    ['Object.create(null)', rte],
    ['[Error.captureStackTrace, Error.stackTraceLimit, Error.prepareStackTrace]', { value: [undefined, undefined, undefined] }],
    ['new Error("x").stack', undef],
    ['try { null.x } catch (e) { return e.stack }', undef],
    ['[Array.prototype, 1]', sec],
    ['[[].toLocaleString, [].copyWithin, [].valueOf, [].hasOwnProperty, [].isPrototypeOf]', { value: [undefined, undefined, undefined, undefined, undefined] }],
    ['["".normalize, "".localeCompare, "".match, "".matchAll, "".search, "".valueOf, "".anchor]', { value: [undefined, undefined, undefined, undefined, undefined, undefined, undefined] }],
    ['[(5).valueOf, (5).toLocaleString, (5).toExponential]', { value: [undefined, undefined, undefined] }],
    ['[({}).valueOf, ({}).isPrototypeOf, ({}).propertyIsEnumerable, ({}).toLocaleString]', { value: [undefined, undefined, undefined, undefined] }],
    ['const f = () => 1; [f.toString, f.valueOf, f.hasOwnProperty, f.displayName]', { value: [undefined, undefined, undefined, undefined] }],
    ['[Math.max.toString, photo.current.adjust.toString, photo.current.adjust.hasOwnProperty]', { value: [undefined, undefined, undefined] }],
    ['[new Map().valueOf, new Set().union, new Map().toString]', { value: [undefined, undefined, undefined] }],
    ['[Number.prototype]', sec],
    ['[String.fromCharCode, String.raw, Array.fromAsync, JSON.rawJSON, Math.valueOf, Number.toString]', { value: [undefined, undefined, undefined, undefined, undefined, undefined] }],
    ['const it = [1].values(); [it.next, it.toString, typeof it]', { value: [undefined, undefined, 'object'] }],
    // --- `this` never is the global object
    ['function f() { return this } f()', undef],
    ['(function () { return this })()', undef],
    ['(function () { return this }).call(undefined)', undef],
    ['(function () { return this }).apply(null)', { value: null }],
    ['(function () { return this }).bind(undefined)()', undef],
    ['[1].map(function () { return this })[0]', undef],
    ['[1, 2].sort(function () { return this === undefined ? 0 : 1 }) && [1].reduce(function () { return this }, 0)', undef],
    ['const o = { toString() { return typeof this } }; `${o}`', { value: 'object' }],
    ['JSON.stringify({ toJSON() { return this === undefined ? "undef" : typeof this } })', { value: '"object"' }],
    // --- host objects that would be dangerous if handed over stay unusable
    ['leakGlobal()', sec],
    ['const f = leakGlobal; f.call(null)', sec],
    ['hostFunctionCtor("return 1")', sec],
    ['box.fn("return 1")', sec],
    ['box.ev("1")', sec],
    ['[box.fn].map((f) => f("return 1"))', sec],
    ['hostFunctionCtor.constructor', sec],
    ['hostFunctionCtor.call(null, "return 1")', sec],
    ['hostFunctionCtor.apply(null, ["return 1"])', sec],
    ['hostFunctionCtor.bind(null, "return 1")', sec],
    ['box.ev.call(null, "1")', sec],
    ['Array.from({ length: 1 }, box.fn)', sec],
    ['[1].flatMap(box.fn)', sec],
    ['[1].findLast(box.fn)', sec],
    ['"a".replace("a", box.fn)', sec],
    ['JSON.stringify({ "return 1": { toJSON: box.fn } }, (k, v) => v)', sec],
    ['JSON.stringify({ a: 1 }, box.fn)', sec],
    ['JSON.parse("1", box.fn)', sec],
    ['[leakGlobal()]', sec],
    ['const [g] = [1].map(leakGlobal); g.Function', sec],
    ['const [g] = [1].map(leakGlobal); Object.keys(g)', sec],
    ['const [g] = [1].map(leakGlobal); ({ ...g })', sec],
    ['const [g] = [1].map(leakGlobal); for (const k in g) {}', sec],
    ['const [g] = [1].map(leakGlobal); const { eval: e } = g', sec],
    ['const [g] = [1].map(leakGlobal); "Function" in g', sec],
    ['const [g] = [1].map(leakGlobal); Object.entries(g)', sec],
    ['const [g] = [1].map(leakGlobal); ({}).hasOwnProperty.call(g, "Function")', { value: false }],
    ['const [g] = [1].map(leakGlobal); JSON.stringify(g)', { value: '{}' }],
    // --- misc
    ['String(() => 1)', { value: 'function () { [code] }' }],
    ['function named() { return 1 } "" + named', { value: 'function named() { [code] }' }],
    ['`${Math.max}` + [photo.current.adjust]', { value: 'function max() { [code] }function adjust() { [code] }' }],
    ['({}).toString.call(undefined)', { value: 'undefined' }],
    ['({}).toString.call(null)', { value: 'null' }],
    ['const keys = []; for (const k in []) keys.push(k); for (const k in {}) keys.push(k); for (const k in () => 1) keys.push(k); keys', { value: [] }],
    ['Object.keys(Object).concat(Object.keys(Math.max), Object.keys(photo.current.adjust))', { value: [] }],
    ['Object.entries([].map)', { value: [] }],
    ['const o = {}; o[{ toString() { return "constructor" } }]', sec],
    ['let n = 0; const tricky = { toString() { return n++ ? "constructor" : "safe" } }; const o = { safe: "ok" }; o[tricky]', { value: 'ok' }],
    ['const o = {}; o[["constructor"]]', sec],
    ['const o = {}; o[["__proto__"]] = 1', sec],
    ['photo.current.meta.iso', { value: 100 }],
    ['photo.current.meta.constructor', sec],
    ['photo.current.toString()', { value: '[object Object]' }],
    ['photo["current"]["adjust"].call.call.apply', { value: expect.any(Function) }],
    ['import("fs")', { kind: 'unsupported' }],
    ['arguments', { kind: 'unsupported' }],
    ['function f() { return arguments.callee } f()', { kind: 'unsupported' }],
    ['function f() { return arguments[0] } f()', { kind: 'unsupported' }],
  ];

  it.each(attempts)('%s', (source, outcome) => {
    const before = snapshot();
    const { globals, calls } = makeGlobals();
    let value: unknown;
    let error: ScriptError | undefined;
    try {
      value = runScript(source, { globals }).value;
    } catch (e) {
      expect(e).toBeInstanceOf(ScriptError);
      error = e as ScriptError;
    }
    if ('kind' in outcome) {
      expect(error ? error.kind : `returned ${String(value)}`).toBe(outcome.kind);
    } else {
      expect(error ? `${error.kind}: ${error.message}` : undefined).toBeUndefined();
      expect(value).toEqual(outcome.value);
    }
    // Whatever happened, the host environment is untouched.
    expect(value).not.toBe(globalThis);
    expect(value).not.toBe(Function);
    expect(snapshot()).toBe(before);
    expect(({} as Record<string, unknown>).polluted).toBeUndefined();
    expect(([] as unknown as Record<string, unknown>).polluted).toBeUndefined();
    expect((Object.prototype as Record<string, unknown>).x).toBeUndefined();
    expect(calls).toEqual([]);
  });

  it('never produces a value whose string form names the global object', () => {
    for (const source of ['({}).toString.call(this)', '`${this}`', 'String(this)', '({}).toString.call()', '[].toString.call(this ?? [])']) {
      const { globals } = makeGlobals();
      let text = '';
      try {
        text = String(run(source, { globals }));
      } catch (e) {
        expect(e).toBeInstanceOf(ScriptError);
      }
      expect(text).not.toMatch(/global|Window/i);
    }
  });

  it('makes security errors uncatchable', () => {
    const { globals, calls } = makeGlobals();
    for (const source of [
      'const k = "constructor"; try { ({})[k] } catch (e) { touch(); return "caught" } touch()',
      'const k = "constructor"; try { ({})[k] } finally { touch() }',
      'const k = "__proto__"; try { try { [][k] } finally { touch() } } catch { touch() } touch()',
      'const k = "constructor"; [1, 2].forEach(() => { try { Math[k] } catch { touch() } }); touch()',
      'try { leakGlobal() } catch { touch() }',
    ]) {
      expect(fail(source, { globals }).kind).toBe('security');
    }
    expect(calls).toEqual([]);
  });

  it('keeps failing after host code swallows an uncatchable error', () => {
    const calls: string[] = [];
    const globals = {
      swallow: (fn: () => void) => {
        try {
          fn();
        } catch {
          calls.push('swallowed');
        }
      },
      touch: () => void calls.push('touch'),
    };
    expect(fail('const k = "constructor"; swallow(() => ({})[k]); touch(); "survived"', { globals }).kind).toBe('security');
    expect(fail('swallow(() => { while (true) {} }); touch(); "survived"', { globals, limits: { maxSteps: 500 } }).kind).toBe('limit');
    expect(fail('swallow(() => { while (true) {} }); "survived"', { globals, limits: { maxSteps: 500 } }).kind).toBe('limit');
    expect(calls).toEqual(['swallowed', 'swallowed', 'swallowed']);
  });

  it('passes a clean, ordinary object graph to host functions', () => {
    const seen: unknown[] = [];
    const globals = { take: (v: unknown) => void seen.push(v) };
    run('take({ a: [1, { b: 2 }], m: new Map([["k", 1]]), s: new Set([1]) })', { globals });
    const value = seen[0] as { a: unknown[]; m: Map<string, number>; s: Set<number> };
    expect(Object.getPrototypeOf(value)).toBe(Object.prototype);
    expect(Object.getPrototypeOf(value.a)).toBe(Array.prototype);
    expect(value.m).toBeInstanceOf(Map);
    expect(value.s).toBeInstanceOf(Set);
    expect(JSON.stringify(value.a)).toBe('[1,{"b":2}]');
  });
});

// ---------------------------------------------------------------------------------------------

describe('limits', () => {
  const small = { maxSteps: 20_000 };

  it.each([
    'while (true) {}',
    'for (;;) {}',
    'for (;;);',
    'while (true);',
    'do {} while (true)',
    'let i = 0; while (true) i++',
    'for (let i = 0; ; i++) { continue }',
    'outer: for (;;) { for (;;) { continue outer } }',
    'const f = () => { while (true) {} }; f()',
    '[3, 1, 2].sort(() => { while (true) {} })',
    '[1].map(() => { for (;;) {} })',
    '[1].forEach(function loop() { [1].forEach(loop) })',
    'new Map([[1, 1]]).forEach(() => { while (true) {} })',
    '"a".replace("a", () => { while (true) {} })',
    'JSON.stringify({ toJSON() { while (true) {} } })',
    '`${{ toString() { while (true) {} } }}`',
    'const o = { valueOf() { while (true) {} } }; o + 1',
    'const big = Array.from({ length: 1000 }, (_, i) => i); while (true) big.includes(-1)',
    'const a = []; for (const x of a) {} while (true) { a.indexOf(1) }',
    'const noop = () => {}; while (true) noop()',
    'while (true) Math.max(1, 2)',
  ])('terminates with kind "limit": %s', (source) => {
    const error = fail(source, { limits: small });
    expect(error.kind).toBe('limit');
    expect(error.line).toBe(1);
  });

  it('charges steps and call depth for callbacks invoked by native methods', () => {
    const three = runScript('[1, 2, 3].forEach(() => {})').steps;
    const six = runScript('[1, 2, 3, 4, 5, 6].forEach(() => {})').steps;
    expect(six - three).toBeGreaterThanOrEqual(6);
    // 1000 callbacks cannot fit in a 500-step budget, even though the loop itself is native.
    expect(fail('Array.from({ length: 1000 }, () => 0)', { limits: { maxSteps: 500 } }).kind).toBe('limit');
    expect(fail('Array(1000).fill(0).map((x) => x)', { limits: { maxSteps: 500 } }).kind).toBe('limit');
    expect(fail('const walk = (n) => [n].map((m) => walk(m + 1)); walk(0)', { limits: { maxCallDepth: 20 } }).message).toMatch(/call depth of 20/);
    // Built-ins that do O(n) native work are charged for it as well.
    const cheap = runScript('const a = Array(64).fill(0); a.includes(1)').steps;
    const costly = runScript('const a = Array(64000).fill(0); a.includes(1)').steps;
    expect(costly - cheap).toBeGreaterThan(900);
  });

  it('counts exactly maxSteps steps', () => {
    const { steps } = runScript('let s = 0; for (let i = 0; i < 100; i++) s += i; s');
    expect(runScript('let s = 0; for (let i = 0; i < 100; i++) s += i; s', { limits: { maxSteps: steps } }).value).toBe(4950);
    const error = fail('let s = 0; for (let i = 0; i < 100; i++) s += i; s', { limits: { maxSteps: steps - 1 } });
    expect(error).toMatchObject({ kind: 'limit', message: expect.stringMatching(/step/) });
  });

  it('turns infinite recursion into a limit error, never a host stack overflow', () => {
    expect(fail('function f() { return f() } f()')).toMatchObject({ kind: 'limit', message: expect.stringMatching(/call depth/) });
    expect(fail('const a = () => b(); const b = () => a(); a()').kind).toBe('limit');
    expect(fail('function f() { return [1].map(f) } f()').kind).toBe('limit');
    expect(fail('const o = { toString() { return `${o}` } }; `${o}`').kind).toBe('limit');
    expect(fail('function f(n) { return f(n + 1) + 1 } f(0)', { limits: { maxCallDepth: 1e9, maxSteps: 1e9, timeoutMs: 20_000 } }).kind).toBe('limit');
    const stack = fail('function inner() { return inner() } function outer() { return inner() } outer()').scriptStack;
    expect(stack?.[0]).toBe('inner');
  });

  it('enforces maxCallDepth precisely', () => {
    const source = 'function depth(n) { return n === 0 ? 0 : 1 + depth(n - 1) } depth(N)';
    expect(run(source.replace('N', '149'))).toBe(149);
    expect(fail(source.replace('N', '150')).kind).toBe('limit');
    expect(run(source.replace('N', '9'), { limits: { maxCallDepth: 10 } })).toBe(9);
    expect(fail(source.replace('N', '10'), { limits: { maxCallDepth: 10 } }).kind).toBe('limit');
  });

  it('recovers call depth after catchable errors thrown from deep calls', () => {
    const source = `
      function boom(n) { if (n === 0) throw new Error("deep"); return boom(n - 1) }
      let caught = 0;
      for (let i = 0; i < 50; i++) { try { boom(100) } catch (e) { caught++ } }
      caught`;
    expect(run(source)).toBe(50);
  });

  it('handles deeply nested source without crashing the host', () => {
    const deep = `${'['.repeat(3000)}${']'.repeat(3000)}`;
    let outcome: unknown;
    try {
      outcome = runScript(deep).value;
    } catch (e) {
      expect(e).toBeInstanceOf(ScriptError);
      expect((e as ScriptError).kind).toBe('limit');
      outcome = 'limit';
    }
    expect(outcome).toBeDefined();
    const nestedCalls = `const f = (x) => x; ${'f('.repeat(4000)}1${')'.repeat(4000)}`;
    try {
      expect(runScript(nestedCalls).value).toBe(1);
    } catch (e) {
      expect((e as ScriptError).kind).toBe('limit');
    }
  });

  it('enforces the wall-clock timeout', () => {
    const started = Date.now();
    const error = fail('while (true) {}', { limits: { maxSteps: Number.MAX_SAFE_INTEGER, timeoutMs: 30 } });
    expect(error).toMatchObject({ kind: 'limit', message: expect.stringMatching(/time limit/) });
    expect(Date.now() - started).toBeLessThan(1500);
  });

  it('enforces maxSourceLength before parsing', () => {
    expect(fail(`1;${' '.repeat(20_000)}`)).toMatchObject({ kind: 'limit', message: expect.stringMatching(/too long/) });
    expect(fail('this is not even javascript', { limits: { maxSourceLength: 10 } }).kind).toBe('limit');
    expect(run(`1;${' '.repeat(19_000)}`)).toBe(1);
  });

  it('does not let try/catch/finally intercept limit errors', () => {
    const calls: string[] = [];
    const globals = { touch: () => void calls.push('touch') };
    for (const source of [
      'try { while (true) {} } catch (e) { touch(); return "caught" }',
      'try { while (true) {} } finally { touch() }',
      'try { while (true) {} } catch (e) { touch() } finally { touch() }',
      'function f() { try { return f() } catch (e) { touch(); return 1 } } f()',
      'function f() { try { return f() } finally { touch() } } f()',
      'while (true) { try { while (true) {} } catch { touch() } }',
      'try { "x".repeat(1e9) } catch { touch() }',
      'for (;;) { try { [].length = 1e9 } catch (e) { touch() } finally { touch() } }',
    ]) {
      expect(fail(source, { globals, limits: small }).kind).toBe('limit');
    }
    expect(calls).toEqual([]);
  });

  describe('memory guards (maxCollectionSize)', () => {
    const limits = { maxCollectionSize: 1000, maxSteps: 200_000 };
    const prelude = 'const s = "x".repeat(600); const a = Array(600).fill(0); const big = Array(1000).fill(s); ';

    it.each([
      '"x".repeat(1e9)',
      '"x".repeat(1001)',
      '"ab".repeat(501)',
      '"x".padStart(1e9)',
      '"x".padEnd(1001, "ab")',
      'Array(1e9)',
      'Array(1001)',
      'new Array(1001)',
      'Array.from({ length: 1e9 })',
      'Array.from({ length: 1001 }, (_, i) => i)',
      'Array(1001).fill(0)',
      's + s',
      'let t = s; t += s',
      '`${s}${s}`',
      '`${s}-${a}`',
      's.concat(s)',
      's.concat("", s, "")',
      'let t = "x"; while (true) t += t',
      'let t = "x"; while (true) t = `${t}${t}`',
      'let t = ["x"]; while (true) t = t.concat(t)',
      'let t = ["x"]; while (true) t = [...t, ...t]',
      'let t = ["x"]; while (true) t.push(...t)',
      'let t = ["x"]; while (true) t.unshift(...t)',
      'let t = ["x"]; while (true) t.splice(0, 0, ...t)',
      'let t = [1]; for (let i = 0; ; i++) t.push(i)',
      'let t = []; for (let i = 0; ; i++) t[i] = i',
      'let t = []; for (let i = 0; ; i++) t[t.length] = i',
      'a.concat(a)',
      '[...a, ...a]',
      'a.length = 1001',
      'a.length = 1e9',
      'a[1000] = 1',
      'a[1e9] = 1',
      'a[2 ** 32] = 1',
      'a["5000"] = 1',
      '[a, a].flat()',
      '[[a, a], [a]].flat(Infinity)',
      'a.flatMap(() => a)',
      'a.flatMap(() => [1, 2])',
      'big.join("")',
      'big.join()',
      'big.toString()',
      'String(big)',
      'big + ""',
      '`${big}`',
      'Number(big)',
      'Math.max(big)',
      'big < 1',
      'big == "x"',
      '({})[big]',
      '"x".includes(big)',
      '[].slice(big)',
      'parseInt(big)',
      '[big, big].sort()',
      'a.join(s)',
      'Array(600).fill(a).join()',
      'const nested = [big]; [nested, nested].join()',
      's.replaceAll("x", "yy")',
      's.replaceAll("x", () => "yy")',
      's.replaceAll("", "y")',
      's.replace("x", s)',
      '"abc".replaceAll("b", "$\'".repeat(300) + s)',
      's.split("").concat(s.split(""))',
      'JSON.stringify(big)',
      'JSON.stringify([big, big, big])',
      'JSON.stringify(Array(600).fill(a))',
      'JSON.stringify(a, null, 10)',
      'JSON.stringify({ toJSON() { return big } })',
      `JSON.parse("[" + "1,".repeat(499) + "1]" + " ".repeat(600) + s + s + s + s + s)`,
      'const m = new Map(); for (let i = 0; ; i++) m.set(i, i)',
      'const m = new Set(); for (let i = 0; ; i++) m.add(i)',
      'const o = {}; for (let i = 0; ; i++) o["k" + i] = i',
      'const o = {}; for (let i = 0; ; i++) Object.assign(o, { ["k" + i]: i })',
      'let o = {}; for (let i = 0; i < 600; i++) o["k" + i] = i; ({ ...o, ...Object.fromEntries(Object.entries(o).map(([k, v]) => ["z" + k, v])) })',
      'Math.max(...Array.from({ length: 40000 }, (_, i) => i))',
      'const f = (...xs) => xs.length; f.apply(null, Array.from({ length: 40000 }, () => 1))',
      'const out = []; while (true) out.push(a.slice())',
      'const out = []; while (true) out.push(s + out.length)',
      'const out = []; while (true) out.push(s.toUpperCase())',
      'const out = []; while (true) out.push([...a])',
      'const out = []; while (true) out.push(new Set(a.map((_, i) => i)))',
    ])('%s', (source) => {
      const error = fail(prelude + source, { limits: source.includes('40000') ? { maxSteps: 2_000_000 } : limits });
      expect(error.kind).toBe('limit');
    });

    it('allows collections up to the limit', () => {
      expect(run('"x".repeat(1000).length', { limits })).toBe(1000);
      expect(run('Array(1000).fill(1).length', { limits })).toBe(1000);
      expect(run('const a = []; for (let i = 0; i < 1000; i++) a.push(i); a.length', { limits })).toBe(1000);
      expect(run('const a = []; a[999] = 1; a.length', { limits })).toBe(1000);
      expect(run('const m = new Map(); for (let i = 0; i < 1000; i++) m.set(i, i); m.set(5, "again"); m.size', { limits })).toBe(1000);
      expect(run('const s = new Set(); for (let i = 0; i < 1000; i++) s.add(i); s.add(5); s.size', { limits })).toBe(1000);
      expect(run('const o = {}; for (let i = 0; i < 1000; i++) o["k" + i] = i; o.k5 = "again"; Object.keys(o).length', { limits })).toBe(1000);
      expect(run('const o = {}; for (let r = 0; r < 5; r++) for (let i = 0; i < 400; i++) { o["k" + i] = i; delete o["k" + i] } Object.keys(o).length', { limits })).toBe(0);
      expect(run('const objs = []; for (let i = 0; i < 600; i++) objs.push({ a: i, b: i, c: i }); objs.length', { limits })).toBe(600);
      expect(run('JSON.stringify(Array(1000).fill(1)).length', { limits })).toBe(2001);
      expect(run('let s = ""; for (let i = 0; i < 500; i++) s += "ab"; s.length', { limits })).toBe(1000);
    });

    it('handles the default limits on realistic sizes', () => {
      expect(run('Array.from({ length: 50000 }, (_, i) => i).reduce((a, b) => a + b, 0)')).toBe(1249975000);
      expect(run('const bins = Array(256).fill(0); for (let i = 0; i < 5000; i++) bins[i % 256]++; bins[0]')).toBe(20);
      expect(run('let s = ""; for (let i = 0; i < 2000; i++) s += i + ","; s.length')).toBe(8890);
      // Appending to an accumulator is cheap however long it gets...
      expect(run('let s = ""; for (let i = 0; i < 20000; i++) s += "ab" + "c" + "\\n"; s.length')).toBe(80000);
      expect(run('let s = ""; for (let i = 0; i < 20000; i++) s = s + "abcd"; s.length')).toBe(80000);
      expect(run('let s = ""; for (let i = 0; i < 20000; i++) s = `${s}abcd`; s.length')).toBe(80000);
      // ...but minting a new long string per iteration is not.
      const limits = { maxSteps: 1e7 };
      expect(fail('const big = "x".repeat(50000); const out = []; for (let i = 0; ; i++) out.push(big + i)', { limits }).message).toMatch(/memory budget/);
      expect(fail('const big = "x".repeat(50000); const out = []; for (let i = 0; ; i++) out.push(`${big}${i}`)', { limits }).message).toMatch(/memory budget/);
      expect(fail('const big = "x".repeat(50000); const out = []; for (let i = 0; ; i++) out.push(i + big)', { limits }).message).toMatch(/memory budget/);
      expect(fail('const big = Array(50000).fill(0); const out = []; for (;;) out.push(big.slice())', { limits }).message).toMatch(/memory budget/);
    });
  });
});

describe('abort signal', () => {
  it('aborts when a host function flips the signal', () => {
    const signal = { aborted: false };
    const calls: string[] = [];
    const globals = {
      cancel: () => {
        signal.aborted = true;
      },
      touch: () => void calls.push('touch'),
    };
    const error = fail('cancel(); touch(); "finished"', { globals, signal });
    expect(error).toMatchObject({ kind: 'aborted', line: 1, column: 0 });
    expect(calls).toEqual([]);
  });

  it('does not run anything when already aborted', () => {
    const touch = jest.fn();
    expect(fail('touch()', { globals: { touch }, signal: { aborted: true } }).kind).toBe('aborted');
    expect(touch).not.toHaveBeenCalled();
  });

  it('is not catchable and stops loops', () => {
    const signal = { aborted: false };
    const touch = jest.fn();
    const globals = { cancel: () => void (signal.aborted = true), touch };
    expect(fail('try { cancel() } catch (e) { touch() } finally { touch() } touch()', { globals, signal }).kind).toBe('aborted');
    expect(touch).not.toHaveBeenCalled();

    const later = { aborted: false };
    let ticks = 0;
    const poll = () => {
      if (++ticks === 50) later.aborted = true;
    };
    expect(fail('while (true) { poll() }', { globals: { poll }, signal: later }).kind).toBe('aborted');
    expect(ticks).toBe(50);
  });

  it('notices an abort that happens without any further host call', () => {
    const signal = { aborted: false };
    let n = 0;
    const globals = {
      get: () => {
        // Simulates another task flipping the flag while the script is busy.
        if (++n === 3) signal.aborted = true;
        return [1, 2, 3];
      },
    };
    expect(fail('const xs = get(); get(); for (const x of get()) { while (true) {} }', { globals, signal, limits: { maxSteps: 1e9 } }).kind).toBe('aborted');
  });

  it('leaves an untouched signal alone', () => {
    expect(run('1 + 1', { signal: { aborted: false } })).toBe(2);
  });
});

describe('error reporting', () => {
  it.each<[string, Partial<ScriptError>]>([
    ['const a = 1;\nconst b = 2;\nthrow new Error("line three");', { kind: 'thrown', line: 3, column: 0 }],
    ['let x = 1;\n\n    x.foo.bar;', { kind: 'runtime', line: 3, column: 4 }],
    ['const o = {};\no.a.b = 1;', { kind: 'runtime', line: 2, column: 0 }],
    ['function f() {\n  return missing + 1;\n}\nf();', { kind: 'runtime', line: 2, column: 9 }],
    ['const o = {};\n\n\n  o.method(1, 2);', { kind: 'runtime', line: 4, column: 2, message: 'TypeError: o.method is not a function' }],
    ['[1, 2].map((x) => {\n  return x.y.z;\n});', { kind: 'runtime', line: 2, column: 9 }],
    ['1;\n2;\nwhile (true) {\n}', { kind: 'limit', line: 3 }],
    ['const k = "constructor";\nconst o = {};\n  o[k];', { kind: 'security', line: 3, column: 2 }],
    ['const a = 1;\nconst b = a.constructor;', { kind: 'security', line: 2, column: 12 }],
    ['const a = 1;\n  class A {}', { kind: 'unsupported', line: 2, column: 2 }],
    ['const a = 1;\nconst b = ;', { kind: 'syntax', line: 2, column: 10 }],
    ['let a = (1 + ;', { kind: 'syntax', line: 1 }],
    ['"unterminated', { kind: 'syntax', line: 1, column: 0 }],
    ['break;', { kind: 'syntax', line: 1 }],
    ['const s = "x".repeat(10);\nconst t =\n  s.repeat(1e9);', { kind: 'limit', line: 3 }],
    ['const a = [1, 2, 3];\na.reduce((x, y) => x + y.nope.deeper, 0);', { kind: 'runtime', line: 2, column: 23 }],
    ['const v = 5;\nv();', { kind: 'runtime', line: 2, column: 0, message: 'TypeError: v is not a function' }],
    ['JSON.parse("{");', { kind: 'runtime', line: 1, column: 0 }],
    ['const x = 1n;', { kind: 'unsupported', line: 1, column: 10 }],
  ])('%j', (source, expected) => {
    expect(fail(source)).toMatchObject(expected);
  });

  it('names the callee in "not a function" errors', () => {
    const globals = { photo: { current: { adjust: () => 1 } } };
    expect(fail('photo.current.foo()', { globals }).message).toBe('TypeError: photo.current.foo is not a function');
    expect(fail('photo.current.adjust.nope()', { globals }).message).toBe('TypeError: photo.current.adjust.nope is not a function');
    expect(fail('photo.missing.foo()', { globals }).message).toMatch(/Cannot read properties of undefined \(reading 'foo'\)/);
    expect(fail('[1, 2].mapp((x) => x)').message).toBe('TypeError: [1, 2].mapp is not a function');
    expect(fail('const o = {}; o["a" + "b"]()').message).toBe('TypeError: o["a" + "b"] is not a function');
  });

  it('includes the interpreted call stack', () => {
    const error = fail('function inner() { throw new Error("x") }\nfunction middle() { inner() }\nconst outer = () => middle();\nouter();');
    expect(error.scriptStack).toEqual(['inner', 'middle', 'outer']);
    expect(error.line).toBe(1);
    expect(fail('throw 1').scriptStack).toBeUndefined();
  });

  it('only ever throws ScriptError', () => {
    const weird: unknown[] = [undefined, null, 42, {}, []];
    for (const source of weird) {
      expect(() => runScript(source as string)).toThrow(ScriptError);
    }
    const globals = {
      nullProto: Object.create(null) as object,
      thrower: () => {
        throw undefined;
      },
    };
    expect(fail('"" + nullProto', { globals }).kind).toBe('runtime');
    expect(fail('`${nullProto}`', { globals }).kind).toBe('runtime');
    expect(fail('thrower()', { globals }).kind).toBe('runtime');
    expect(run('try { thrower() } catch (e) { return e === undefined }', { globals })).toBe(true);
    expect(run('try { "" + nullProto } catch (e) { return e.name }', { globals })).toBe('TypeError');
    // Malformed options are tolerated rather than crashing with a host TypeError.
    expect(runScript('1', null as unknown as RunOptions).value).toBe(1);
    expect(runScript('1', { globals: null, limits: null, signal: null } as unknown as RunOptions).value).toBe(1);
    expect(runScript('1', { limits: { maxSteps: 'many' } } as unknown as RunOptions).value).toBe(1);
    const error = fail('throw new Error("x")');
    expect(error).toBeInstanceOf(Error);
    expect(error.name).toBe('ScriptError');
  });
});

describe('unsupported constructs are rejected before anything runs', () => {
  const cases: [string, RegExp][] = [
    ['class A {}', /Classes are not supported in edit scripts/],
    ['const A = class {}', /Classes are not supported in edit scripts/],
    ['function* gen() { yield 1 }', /Generator functions are not supported in edit scripts/],
    ['const g = function* () {}', /Generator/],
    ['async function f() {}', /async functions are not supported in edit scripts/],
    ['const f = async () => 1', /async functions are not supported in edit scripts/],
    ['const o = { async m() {} }', /async/],
    ['await touch()', /async\/await is not supported in edit scripts/],
    ['for await (const x of []) {}', /not supported in edit scripts/],
    ['/ab+c/.test("abc")', /Regular expression literals are not supported in edit scripts/],
    ['"abc".replace(/b/g, "x")', /Regular expression literals are not supported in edit scripts/],
    ['const tag = (s) => s; tag`x`', /Tagged template literals are not supported in edit scripts/],
    ['import fs from "fs"', /'import' declarations are not supported in edit scripts/],
    ['import { a } from "b"', /'import' declarations are not supported in edit scripts/],
    ['export const a = 1', /'export' declarations are not supported in edit scripts/],
    ['export default 1', /'export' declarations are not supported in edit scripts/],
    ['import("fs")', /Dynamic import\(\) is not supported in edit scripts/],
    ['import.meta', /import\.meta is not supported in edit scripts/],
    ['with (Math) { max(1, 2) }', /'with' statements are not supported in edit scripts/],
    ['debugger', /'debugger' statements are not supported in edit scripts/],
    ['const o = { get a() { return 1 } }', /Getters and setters are not supported in edit scripts/],
    ['const o = { set a(v) {} }', /Getters and setters are not supported in edit scripts/],
    ['function f() { return new.target }', /new\.target is not supported in edit scripts/],
    ['const o = { m() { return super.x } }', /'super' is not supported in edit scripts/],
    ['const o = { m() { return super.m() } }', /'super' is not supported in edit scripts/],
    ['const n = 10n', /BigInt literals are not supported in edit scripts/],
    ['function f() { return arguments.length }', /'arguments' object is .*not supported in edit scripts/],
    ['let x = 1; delete x', /not supported in edit scripts/],
    ['if (true) function f() {}', /not supported in edit scripts/],
    ['function outer() { if (false) { class Hidden {} } }', /Classes are not supported in edit scripts/],
    ['const unused = () => { return /re/ }', /Regular expression literals/],
  ];

  it.each(cases)('%s', (source, message) => {
    const touch = jest.fn();
    const error = fail(`touch();\n${source}`, { globals: { touch } });
    expect(error.kind).toBe('unsupported');
    expect(error.message).toMatch(message);
    expect(error.line).toBe(2);
    expect(touch).not.toHaveBeenCalled();
  });

  it('rejects syntax errors and static security violations before anything runs', () => {
    const touch = jest.fn();
    expect(fail('touch(); const = 5', { globals: { touch } }).kind).toBe('syntax');
    expect(fail('touch(); if (false) { ({}).constructor }', { globals: { touch } }).kind).toBe('security');
    expect(fail('touch(); let touch = 1', { globals: { touch } }).kind).toBe('syntax');
    expect(touch).not.toHaveBeenCalled();
  });
});

describe('performance', () => {
  it('runs a million simple loop iterations quickly', () => {
    const source = 'let s = 0; for (let i = 0; i < 1e6; i++) { s += i } s';
    runScript(source, { limits: { maxSteps: 2e7, timeoutMs: 20_000 } }); // warm-up
    const result = runScript(source, { limits: { maxSteps: 2e7, timeoutMs: 20_000 } });
    expect(result.value).toBe(499999500000);
    expect(result.steps).toBeLessThan(2e7);
    console.info(`1e6 loop iterations: ${result.durationMs} ms, ${result.steps} steps`);
    expect(result.durationMs).toBeLessThan(3000);
  });

  it('keeps function calls and array callbacks reasonably fast', () => {
    const source = `
      const xs = Array.from({ length: 20000 }, (_, i) => i);
      const add = (a, b) => a + b;
      let total = 0;
      for (let round = 0; round < 5; round++) total += xs.map((x) => x * 2).filter((x) => x % 3 === 0).reduce(add, 0);
      total`;
    const result = runScript(source, { limits: { maxSteps: 2e7, timeoutMs: 20_000 } });
    let expected = 0;
    for (let x = 0; x < 40000; x += 2) if (x % 3 === 0) expected += x;
    expect(result.value).toBe(expected * 5);
    expect(result.durationMs).toBeLessThan(3000);
  });
});
