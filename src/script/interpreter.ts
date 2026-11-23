/**
 * Sandboxed JavaScript interpreter for short, untrusted edit scripts.
 *
 * The source is parsed with acorn and compiled, once, into a tree of host closures
 * (one per AST node); nothing is ever handed to `eval`/`Function`. Compilation doubles as
 * the validation pass: unsupported syntax and statically visible forbidden property names
 * are rejected before a single node runs.
 *
 * Variables are resolved at compile time to (scope hops, slot) pairs, so a scope at run time
 * is just an array whose slot 0 points at the parent scope. Scripts can only name what the
 * compiler resolves: their own bindings and the entries of `Runtime.globals`.
 *
 * Everything that touches a value (property access, calls, built-ins, limits) lives in
 * `interpreter-runtime.ts`.
 */
// The sandbox depends on strict-mode `this` (never the global object, never boxed) in every
// function of this file. React Native's Babel preset does not add the directive to modules.
'use strict';

import { parse } from 'acorn';
import type * as es from 'acorn';

import {
  DEFAULT_LIMITS,
  MAX_CALL_ARGS,
  Runtime,
  ScriptError,
  Thrown,
  errorText,
  isForbiddenKey,
  isStackOverflow,
  type Dict,
  type RunLimits,
  type ScriptErrorKind,
} from './interpreter-runtime';

export { DEFAULT_LIMITS, ScriptError };
export type { RunLimits, ScriptErrorKind };

export interface RunOptions {
  /** Extra global bindings (host API objects/functions). Bindings are read-only. */
  globals?: Record<string, unknown>;
  limits?: Partial<RunLimits>;
  /** Checked together with the wall clock and after every call; when true the run ends with kind 'aborted'. */
  signal?: { aborted: boolean };
}

export interface RunResult {
  value: unknown;
  steps: number;
  durationMs: number;
}

// ------------------------------------------------------------------ compile-time model

type Env = unknown[];
type Ex = (env: Env) => unknown;
type St = (env: Env) => Completion;
type Setter = (env: Env, value: unknown) => void;

class Signal {
  constructor(readonly kind: string) {}
}
type Completion = Signal | undefined;
const BREAK = new Signal('break');
const CONTINUE = new Signal('continue');
const RETURN = new Signal('return');
/** Slot content of a `let`/`const` binding before its declaration has run. */
const TDZ: unknown = new Signal('uninitialized');
/** Result of an optional chain that short-circuited. */
const SHORT: unknown = new Signal('short-circuit');

const NO_LABELS: readonly string[] = [];

type DeclKind = 'var' | 'let' | 'const' | 'fn';
interface Decl {
  index: number;
  kind: DeclKind;
}

class CScope {
  readonly names = new Map<string, Decl>();
  /** Slot 0 is the parent scope. */
  size = 1;

  constructor(readonly parent: CScope | null) {}

  declare(name: string, kind: DeclKind): Decl {
    const existing = this.names.get(name);
    if (existing !== undefined) {
      if (kind !== 'var') existing.kind = kind;
      return existing;
    }
    const decl: Decl = { index: this.size++, kind };
    this.names.set(name, decl);
    return decl;
  }

  /** The initial slot array; cloned every time the scope is entered. */
  template(): Env {
    const slots: Env = new Array<unknown>(this.size).fill(undefined);
    for (const decl of this.names.values()) {
      if (decl.kind === 'let' || decl.kind === 'const') slots[decl.index] = TDZ;
    }
    return slots;
  }
}

function up(env: Env, hops: number): Env {
  let e = env;
  for (let i = hops; i > 0; i--) e = e[0] as Env;
  return e;
}

/** How a loop reacts to an abrupt body completion: 0 = next iteration, 1 = leave the loop, 2 = propagate. */
function loopControl(rt: Runtime, c: Signal, labels: readonly string[]): number {
  if (c === BREAK) return rt.label === null ? 1 : 2;
  if (c === CONTINUE) {
    if (rt.label === null) return 0;
    if (labels.indexOf(rt.label) !== -1) {
      rt.label = null;
      return 0;
    }
  }
  return 2;
}

function looseEquals(rt: Runtime, l: unknown, r: unknown): boolean {
  const lo = (typeof l === 'object' && l !== null) || typeof l === 'function';
  const ro = (typeof r === 'object' && r !== null) || typeof r === 'function';
  if (lo && ro) return l === r;
  // eslint-disable-next-line eqeqeq
  return lo || ro ? rt.prim(l) == rt.prim(r) : l == r;
}

/** `+` when at least one operand is not a number: bounded string conversion, bounded result. */
function addSlow(rt: Runtime, l: unknown, r: unknown, node: es.Node): unknown {
  const left = rt.prim(l);
  const v: unknown = (left as number) + (rt.prim(r) as number);
  return typeof v === 'string' ? rt.concatenated(v, left, node) : v;
}

function arithSlow(rt: Runtime, op: string, l0: unknown, r0: unknown): unknown {
  if (op === '==') return looseEquals(rt, l0, r0);
  if (op === '!=') return !looseEquals(rt, l0, r0);
  const l = rt.prim(l0) as number;
  const r = rt.prim(r0) as number;
  switch (op) {
    case '-':
      return l - r;
    case '*':
      return l * r;
    case '/':
      return l / r;
    case '%':
      return l % r;
    case '**':
      return l ** r;
    case '<':
      return l < r;
    case '>':
      return l > r;
    case '<=':
      return l <= r;
    case '>=':
      return l >= r;
    case '|':
      return l | r;
    case '&':
      return l & r;
    case '^':
      return l ^ r;
    case '<<':
      return l << r;
    case '>>':
      return l >> r;
    case '>>>':
      return l >>> r;
    default:
      throw new TypeError(`Unknown operator ${op}`);
  }
}

interface MemberRef {
  obj: Ex;
  /** Validated static key, or null when the key is computed. */
  key: string | null;
  keyEx: Ex | null;
}

type FunctionNode = es.FunctionDeclaration | es.FunctionExpression | es.ArrowFunctionExpression | es.AnonymousFunctionDeclaration;

// ------------------------------------------------------------------ compiler

/*
 * Every closure produced below starts with the same two statements, written out by hand
 * because Hermes does not inline calls:
 *     rt.node = node;                                  // error location register
 *     if (++rt.steps >= rt.nextCheck) rt.check();      // step budget, clock, abort
 */
class Compiler {
  private scope = new CScope(null);
  private readonly programScope = this.scope;
  /** Number of function nodes compiled so far; lets loops detect closures in their body. */
  private fnCount = 0;

  constructor(
    private readonly rt: Runtime,
    private readonly source: string,
  ) {}

  compileProgram(ast: es.Program): () => unknown {
    const rt = this.rt;
    const scope = this.scope;
    scope.declare('this', 'var');
    this.hoistVars(ast.body, scope);
    this.declareLexical(ast.body, scope);
    const body = this.statements(ast.body, true);
    const template = scope.template();
    return () => {
      const env = template.slice();
      env[0] = null;
      const c = body(env);
      return c === RETURN ? rt.retVal : rt.last;
    };
  }

  // ---------------------------------------------------------------- errors

  private unsupported(what: string, node: es.Node): ScriptError {
    return new ScriptError('unsupported', `${what} not supported in edit scripts`, node.loc?.start.line, node.loc?.start.column);
  }

  /** Validate a statically known property name. */
  private key(name: string, node: es.Node): string {
    if (isForbiddenKey(name)) {
      throw new ScriptError('security', `Access to '${name}' is not allowed in edit scripts`, node.loc?.start.line, node.loc?.start.column);
    }
    return name;
  }

  // ---------------------------------------------------------------- scopes

  private push(): CScope {
    this.scope = new CScope(this.scope);
    return this.scope;
  }

  private pop(): void {
    if (this.scope.parent !== null) this.scope = this.scope.parent;
  }

  private resolve(name: string): { hops: number; decl: Decl } | null {
    let hops = 0;
    for (let s: CScope | null = this.scope; s !== null; s = s.parent, hops++) {
      const decl = s.names.get(name);
      if (decl !== undefined) return { hops, decl };
    }
    return null;
  }

  private declareName(name: string, kind: DeclKind, scope: CScope, node: es.Node): Decl {
    // Global bindings (built-ins and host API) can be shadowed in inner scopes but not redeclared.
    if (scope === this.programScope && name in this.rt.globals) {
      throw new ScriptError('syntax', `Identifier '${name}' is a global and cannot be redeclared`, node.loc?.start.line, node.loc?.start.column);
    }
    return scope.declare(name, kind);
  }

  private declarePattern(p: es.Pattern, kind: DeclKind, scope: CScope): void {
    switch (p.type) {
      case 'Identifier':
        this.declareName(p.name, kind, scope, p);
        break;
      case 'ObjectPattern':
        for (const prop of p.properties) this.declarePattern(prop.type === 'RestElement' ? prop.argument : prop.value, kind, scope);
        break;
      case 'ArrayPattern':
        for (const el of p.elements) if (el !== null) this.declarePattern(el, kind, scope);
        break;
      case 'AssignmentPattern':
        this.declarePattern(p.left, kind, scope);
        break;
      case 'RestElement':
        this.declarePattern(p.argument, kind, scope);
        break;
      default:
        break;
    }
  }

  /** Hoist `var` declarations of a function body (not descending into nested functions). */
  private hoistVars(nodes: readonly es.Node[], scope: CScope): void {
    for (const n of nodes) this.hoistVarsIn(n as es.AnyNode, scope);
  }

  private hoistVarsIn(node: es.AnyNode | null | undefined, scope: CScope): void {
    if (node === null || node === undefined) return;
    switch (node.type) {
      case 'VariableDeclaration':
        if (node.kind === 'var') for (const d of node.declarations) this.declarePattern(d.id, 'var', scope);
        break;
      case 'BlockStatement':
        this.hoistVars(node.body, scope);
        break;
      case 'IfStatement':
        this.hoistVarsIn(node.consequent, scope);
        this.hoistVarsIn(node.alternate, scope);
        break;
      case 'ForStatement':
        this.hoistVarsIn(node.init, scope);
        this.hoistVarsIn(node.body, scope);
        break;
      case 'ForInStatement':
      case 'ForOfStatement':
        this.hoistVarsIn(node.left, scope);
        this.hoistVarsIn(node.body, scope);
        break;
      case 'WhileStatement':
      case 'DoWhileStatement':
      case 'LabeledStatement':
        this.hoistVarsIn(node.body, scope);
        break;
      case 'TryStatement':
        this.hoistVarsIn(node.block, scope);
        this.hoistVarsIn(node.handler?.body, scope);
        this.hoistVarsIn(node.finalizer, scope);
        break;
      case 'SwitchStatement':
        for (const c of node.cases) this.hoistVars(c.consequent, scope);
        break;
      default:
        break;
    }
  }

  private needsScope(nodes: readonly es.Node[]): boolean {
    return (nodes as es.AnyNode[]).some(
      (n) => (n.type === 'VariableDeclaration' && n.kind !== 'var') || n.type === 'FunctionDeclaration' || n.type === 'ClassDeclaration',
    );
  }

  /** Declare the let/const/function bindings a statement list introduces directly. */
  private declareLexical(nodes: readonly es.Node[], scope: CScope): void {
    for (const n of nodes as es.AnyNode[]) {
      if (n.type === 'VariableDeclaration' && n.kind !== 'var') {
        const kind: DeclKind = n.kind === 'const' ? 'const' : 'let';
        for (const d of n.declarations) this.declarePattern(d.id, kind, scope);
      } else if (n.type === 'FunctionDeclaration' && n.id) {
        this.declareName(n.id.name, 'fn', scope, n.id);
      }
    }
  }

  // ---------------------------------------------------------------- statements

  private statements(nodes: readonly es.Node[], top = false): St {
    const rt = this.rt;
    const hoisted: ((env: Env) => void)[] = [];
    const list: St[] = [];
    for (const n of nodes as (es.Statement | es.ModuleDeclaration)[]) {
      if (n.type === 'FunctionDeclaration') {
        // Function declarations are initialised when their scope is entered.
        const make = this.fn(n, n.id.name);
        const decl = this.scope.names.get(n.id.name);
        if (decl === undefined) throw this.unsupported('This function declaration is', n);
        const index = decl.index;
        hoisted.push((env) => {
          env[index] = make(env);
        });
      } else if (top && n.type === 'ExpressionStatement') {
        // The value of the last top-level expression statement is the script's result.
        const ex = this.expr(n.expression);
        const node = n;
        list.push((env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          rt.last = ex(env);
          return undefined;
        });
      } else {
        list.push(this.stmt(n));
      }
    }
    const n = list.length;
    if (hoisted.length === 0 && n === 1) return list[0];
    return (env) => {
      for (let i = 0; i < hoisted.length; i++) hoisted[i](env);
      for (let i = 0; i < n; i++) {
        const c = list[i](env);
        if (c !== undefined) return c;
      }
      return undefined;
    };
  }

  private block(node: es.BlockStatement): St {
    const rt = this.rt;
    if (!this.needsScope(node.body)) {
      const body = this.statements(node.body);
      return (env) => {
        rt.node = node;
        if (++rt.steps >= rt.nextCheck) rt.check();
        return body(env);
      };
    }
    const scope = this.push();
    this.declareLexical(node.body, scope);
    const body = this.statements(node.body);
    this.pop();
    const template = scope.template();
    return (env) => {
      rt.node = node;
      if (++rt.steps >= rt.nextCheck) rt.check();
      const e = template.slice();
      e[0] = env;
      return body(e);
    };
  }

  private stmt(node: es.Statement | es.ModuleDeclaration, labels: readonly string[] = NO_LABELS): St {
    const rt = this.rt;
    switch (node.type) {
      case 'ExpressionStatement': {
        const ex = this.expr(node.expression);
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          ex(env);
          return undefined;
        };
      }
      case 'BlockStatement':
        return this.block(node);
      case 'EmptyStatement':
        return () => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          return undefined;
        };
      case 'VariableDeclaration':
        return this.declaration(node);
      case 'IfStatement': {
        const test = this.expr(node.test);
        const yes = this.stmt(node.consequent);
        const no = node.alternate ? this.stmt(node.alternate) : null;
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          if (test(env)) return yes(env);
          return no === null ? undefined : no(env);
        };
      }
      case 'ForStatement':
        return this.forLoop(node, labels);
      case 'ForOfStatement':
      case 'ForInStatement':
        return this.forEach(node, labels);
      case 'WhileStatement': {
        const test = this.expr(node.test);
        const body = this.stmt(node.body);
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          while (test(env)) {
            const c = body(env);
            if (c !== undefined) {
              const k = loopControl(rt, c, labels);
              if (k === 1) break;
              if (k === 2) return c;
            }
          }
          return undefined;
        };
      }
      case 'DoWhileStatement': {
        const test = this.expr(node.test);
        const body = this.stmt(node.body);
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          do {
            const c = body(env);
            if (c !== undefined) {
              const k = loopControl(rt, c, labels);
              if (k === 1) break;
              if (k === 2) return c;
            }
          } while (test(env));
          return undefined;
        };
      }
      case 'ReturnStatement': {
        const arg = node.argument ? this.expr(node.argument) : null;
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          rt.retVal = arg === null ? undefined : arg(env);
          return RETURN;
        };
      }
      case 'BreakStatement':
      case 'ContinueStatement': {
        const label = node.label ? node.label.name : null;
        const signal = node.type === 'BreakStatement' ? BREAK : CONTINUE;
        return () => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          rt.label = label;
          return signal;
        };
      }
      case 'LabeledStatement': {
        const name = node.label.name;
        const body = this.stmt(node.body, labels.concat(name));
        return (env) => {
          const c = body(env);
          if (c === BREAK && rt.label === name) {
            rt.label = null;
            return undefined;
          }
          return c;
        };
      }
      case 'SwitchStatement':
        return this.switchStatement(node);
      case 'ThrowStatement': {
        const arg = this.expr(node.argument);
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          throw rt.thrown(arg(env), 'thrown', node);
        };
      }
      case 'TryStatement':
        return this.tryStatement(node);
      case 'FunctionDeclaration':
        throw this.unsupported('Function declarations that are not directly inside a block are', node);
      case 'ClassDeclaration':
        throw this.unsupported('Classes are', node);
      case 'WithStatement':
        throw this.unsupported("'with' statements are", node);
      case 'DebuggerStatement':
        throw this.unsupported("'debugger' statements are", node);
      case 'ImportDeclaration':
        throw this.unsupported("'import' declarations are", node);
      case 'ExportNamedDeclaration':
      case 'ExportDefaultDeclaration':
      case 'ExportAllDeclaration':
        throw this.unsupported("'export' declarations are", node);
      default:
        throw this.unsupported(`${(node as es.Node).type} statements are`, node);
    }
  }

  private declaration(node: es.VariableDeclaration): St {
    const rt = this.rt;
    if (node.kind !== 'var' && node.kind !== 'let' && node.kind !== 'const') {
      throw this.unsupported(`'${String(node.kind)}' declarations are`, node);
    }
    const parts: ((env: Env) => void)[] = [];
    for (const d of node.declarations) {
      const id = d.id;
      const init = d.init ? this.expr(d.init, id.type === 'Identifier' ? id.name : undefined) : null;
      if (init === null) {
        if (node.kind === 'var') continue; // `var x;` does not reset an existing value
        const bind = this.pattern(id, true);
        parts.push((env) => bind(env, undefined));
        continue;
      }
      const local = id.type === 'Identifier' ? this.scope.names.get(id.name) : undefined;
      if (local !== undefined) {
        const index = local.index;
        parts.push((env) => {
          env[index] = init(env);
        });
      } else {
        const bind = this.pattern(id, true);
        parts.push((env) => bind(env, init(env)));
      }
    }
    if (parts.length === 1) {
      const only = parts[0];
      return (env) => {
        rt.node = node;
        if (++rt.steps >= rt.nextCheck) rt.check();
        only(env);
        return undefined;
      };
    }
    return (env) => {
      rt.node = node;
      if (++rt.steps >= rt.nextCheck) rt.check();
      for (let i = 0; i < parts.length; i++) parts[i](env);
      return undefined;
    };
  }

  private forLoop(node: es.ForStatement, labels: readonly string[]): St {
    const rt = this.rt;
    const fnBefore = this.fnCount;
    let scope: CScope | null = null;
    let init: ((env: Env) => unknown) | null = null;
    if (node.init) {
      if (node.init.type === 'VariableDeclaration') {
        if (node.init.kind !== 'var') {
          scope = this.push();
          this.declareLexical([node.init], scope);
        }
        init = this.declaration(node.init);
      } else {
        init = this.expr(node.init);
      }
    }
    const test = node.test ? this.expr(node.test) : null;
    const update = node.update ? this.expr(node.update) : null;
    const body = this.stmt(node.body);
    if (scope !== null) this.pop();
    const template = scope === null ? null : scope.template();
    // let/const loop variables get a fresh binding per iteration, but the copy is only
    // observable (and only paid for) when a closure inside the loop can capture them.
    const perIteration = template !== null && this.fnCount !== fnBefore;
    return (env) => {
      rt.node = node;
      if (++rt.steps >= rt.nextCheck) rt.check();
      let e = env;
      if (template !== null) {
        e = template.slice();
        e[0] = env;
      }
      if (init !== null) init(e);
      while (test === null || test(e)) {
        const c = body(e);
        if (c !== undefined) {
          const k = loopControl(rt, c, labels);
          if (k === 1) break;
          if (k === 2) return c;
        }
        if (perIteration) e = e.slice();
        if (update !== null) update(e);
      }
      return undefined;
    };
  }

  private forEach(node: es.ForOfStatement | es.ForInStatement, labels: readonly string[]): St {
    const rt = this.rt;
    if (node.type === 'ForOfStatement' && node.await) throw this.unsupported("'for await' loops are", node);
    const isOf = node.type === 'ForOfStatement';
    const right = this.expr(node.right);
    const fnBefore = this.fnCount;
    let scope: CScope | null = null;
    let bind: Setter;
    if (node.left.type === 'VariableDeclaration') {
      const target = node.left.declarations[0].id;
      if (node.left.kind !== 'var') {
        scope = this.push();
        this.declareLexical([node.left], scope);
      }
      bind = this.pattern(target, true);
    } else {
      bind = this.pattern(node.left, false);
    }
    const body = this.stmt(node.body);
    if (scope !== null) this.pop();
    const template = scope === null ? null : scope.template();
    const perIteration = template !== null && this.fnCount !== fnBefore;
    return (env) => {
      rt.node = node;
      if (++rt.steps >= rt.nextCheck) rt.check();
      const subject = right(env);
      // for…of over an array is live (sees pushes); every other iterable is snapshotted.
      const items = isOf ? rt.toArray(subject, node.right) : rt.ownKeys(subject);
      let e = env;
      if (template !== null) {
        e = template.slice();
        e[0] = env;
      }
      for (let i = 0; i < items.length; i++) {
        if (perIteration && i > 0 && template !== null) {
          e = template.slice();
          e[0] = env;
        }
        bind(e, items[i]);
        const c = body(e);
        if (c !== undefined) {
          const k = loopControl(rt, c, labels);
          if (k === 1) break;
          if (k === 2) return c;
        }
      }
      return undefined;
    };
  }

  private switchStatement(node: es.SwitchStatement): St {
    const rt = this.rt;
    const discriminant = this.expr(node.discriminant);
    const all = node.cases.flatMap((c) => c.consequent);
    let scope: CScope | null = null;
    if (this.needsScope(all)) {
      scope = this.push();
      this.declareLexical(all, scope);
    }
    const tests = node.cases.map((c) => (c.test ? this.expr(c.test) : null));
    const bodies = node.cases.map((c) => this.statements(c.consequent));
    if (scope !== null) this.pop();
    const template = scope === null ? null : scope.template();
    const fallback = tests.indexOf(null);
    return (env) => {
      rt.node = node;
      if (++rt.steps >= rt.nextCheck) rt.check();
      const value = discriminant(env);
      let e = env;
      if (template !== null) {
        e = template.slice();
        e[0] = env;
      }
      let start = -1;
      for (let i = 0; i < tests.length; i++) {
        const test = tests[i];
        if (test !== null && test(e) === value) {
          start = i;
          break;
        }
      }
      if (start === -1) start = fallback;
      if (start === -1) return undefined;
      for (let i = start; i < bodies.length; i++) {
        const c = bodies[i](e);
        if (c !== undefined) return c === BREAK && rt.label === null ? undefined : c;
      }
      return undefined;
    };
  }

  private tryStatement(node: es.TryStatement): St {
    const rt = this.rt;
    const block = this.block(node.block);
    let handler: ((env: Env, value: unknown) => Completion) | null = null;
    if (node.handler) {
      const clause = node.handler;
      if (clause.param) {
        const scope = this.push();
        this.declarePattern(clause.param, 'let', scope);
        const bind = this.pattern(clause.param, true);
        const body = this.block(clause.body);
        this.pop();
        const template = scope.template();
        handler = (env, value) => {
          const e = template.slice();
          e[0] = env;
          bind(e, value);
          return body(e);
        };
      } else {
        handler = this.block(clause.body);
      }
    }
    const finalizer = node.finalizer ? this.block(node.finalizer) : null;
    return (env) => {
      rt.node = node;
      if (++rt.steps >= rt.nextCheck) rt.check();
      let c: Completion;
      let pending: Thrown | null = null;
      try {
        c = block(env);
      } catch (e) {
        // Limit / abort / security errors are rethrown right here by catchable(): neither the
        // handler nor the finalizer below ever runs for them.
        const t = rt.catchable(e);
        if (handler === null) pending = t;
        else {
          try {
            c = handler(env, t.value);
          } catch (e2) {
            pending = rt.catchable(e2);
          }
        }
      }
      if (finalizer !== null) {
        const retVal = rt.retVal;
        const label = rt.label;
        const fc = finalizer(env);
        if (fc !== undefined) return fc; // an abrupt `finally` overrides everything
        rt.retVal = retVal;
        rt.label = label;
      }
      if (pending !== null) throw pending;
      return c;
    };
  }

  // ---------------------------------------------------------------- bindings and patterns

  /** Non-counting read of a variable (used by compound assignment, update and `typeof`). */
  private getter(name: string, node: es.Node): Ex {
    const rt = this.rt;
    const r = this.resolve(name);
    if (r === null) {
      if (name in rt.globals) {
        const value = rt.globals[name];
        return () => value;
      }
      if (name === 'arguments') throw this.unsupported("The 'arguments' object is (use rest parameters instead);", node);
      return () => {
        throw rt.thrown(new ReferenceError(`${name} is not defined`), 'runtime', node);
      };
    }
    const hops = r.hops;
    const index = r.decl.index;
    if (r.decl.kind === 'let' || r.decl.kind === 'const') {
      return (env) => {
        const v = up(env, hops)[index];
        if (v === TDZ) throw this.uninitialized(name, node);
        return v;
      };
    }
    return hops === 0 ? (env) => env[index] : (env) => up(env, hops)[index];
  }

  private uninitialized(name: string, node: es.Node): Thrown {
    return this.rt.thrown(new ReferenceError(`Cannot access '${name}' before initialization`), 'runtime', node);
  }

  /** Assignment to an existing binding (not a declaration). */
  private setter(name: string, node: es.Node): Setter {
    const rt = this.rt;
    const r = this.resolve(name);
    if (r === null) {
      if (name in rt.globals) {
        return () => {
          throw rt.typeError(`Cannot assign to '${name}': globals are read-only`, node);
        };
      }
      // Strict-mode semantics: no implicit globals.
      return () => {
        throw rt.thrown(new ReferenceError(`${name} is not defined`), 'runtime', node);
      };
    }
    const hops = r.hops;
    const index = r.decl.index;
    if (r.decl.kind === 'const') {
      return () => {
        throw rt.typeError(`Assignment to constant variable '${name}'`, node);
      };
    }
    if (r.decl.kind === 'let') {
      return (env, value) => {
        const e = up(env, hops);
        if (e[index] === TDZ) throw this.uninitialized(name, node);
        e[index] = value;
      };
    }
    return hops === 0
      ? (env, value) => {
          env[index] = value;
        }
      : (env, value) => {
          up(env, hops)[index] = value;
        };
  }

  private propertyKey(prop: { key: es.Node; computed: boolean }): { key: string | null; keyEx: Ex | null } {
    const k = prop.key as es.AnyNode;
    if (prop.computed) return { key: null, keyEx: this.expr(k as es.Expression) };
    if (k.type === 'Identifier') return { key: this.key(k.name, k), keyEx: null };
    if (k.type === 'Literal' && (typeof k.value === 'string' || typeof k.value === 'number')) {
      return { key: this.key(String(k.value), k), keyEx: null };
    }
    throw this.unsupported('This kind of property key is', k);
  }

  /**
   * Compile a binding/assignment target. With `init` the identifiers are freshly declared
   * bindings (no const/TDZ checks); otherwise they are assignment targets.
   */
  private pattern(p: es.Pattern, init: boolean): Setter {
    const rt = this.rt;
    switch (p.type) {
      case 'Identifier': {
        if (!init) return this.setter(p.name, p);
        const r = this.resolve(p.name);
        if (r === null) throw this.unsupported(`The declaration of '${p.name}' is`, p);
        const hops = r.hops;
        const index = r.decl.index;
        return hops === 0
          ? (env, value) => {
              env[index] = value;
            }
          : (env, value) => {
              up(env, hops)[index] = value;
            };
      }
      case 'MemberExpression': {
        const ref = this.memberRef(p);
        const key = ref.key;
        const keyEx = ref.keyEx;
        return (env, value) => {
          const o = ref.obj(env);
          if (key !== null) rt.set(o, key, value, p);
          else if (keyEx !== null) rt.setc(o, keyEx(env), value, p);
        };
      }
      case 'AssignmentPattern': {
        const target = this.pattern(p.left, init);
        const fallback = this.expr(p.right, p.left.type === 'Identifier' ? p.left.name : undefined);
        return (env, value) => target(env, value === undefined ? fallback(env) : value);
      }
      case 'ArrayPattern': {
        const targets = p.elements.map((el) => (el === null ? null : this.pattern(el.type === 'RestElement' ? el.argument : el, init)));
        const restAt = p.elements.findIndex((el) => el !== null && el.type === 'RestElement');
        return (env, value) => {
          const items = rt.toArray(value, p);
          for (let i = 0; i < targets.length; i++) {
            const target = targets[i];
            if (target === null) continue;
            target(env, i === restAt ? rt.checkArr(items.slice(i), p) : items[i]);
          }
        };
      }
      case 'ObjectPattern': {
        const props: { key: string | null; keyEx: Ex | null; target: Setter }[] = [];
        let rest: Setter | null = null;
        for (const prop of p.properties) {
          if (prop.type === 'RestElement') rest = this.pattern(prop.argument, init);
          else props.push({ ...this.propertyKey(prop), target: this.pattern(prop.value, init) });
        }
        const restTarget = rest;
        return (env, value) => {
          if (value === null || value === undefined) {
            throw rt.typeError(`Cannot destructure ${String(value)}: it has no properties`, p);
          }
          const used: string[] = [];
          for (let i = 0; i < props.length; i++) {
            const prop = props[i];
            const k = prop.key ?? rt.toKey(prop.keyEx === null ? undefined : prop.keyEx(env), p);
            if (restTarget !== null) used.push(k);
            prop.target(env, rt.get(value, k, p));
          }
          if (restTarget !== null) {
            const out: Dict = {};
            for (const k of rt.ownKeys(value)) {
              if (used.indexOf(k) === -1) rt.set(out, rt.toKey(k, p), (value as Dict)[k], p);
            }
            restTarget(env, out);
          }
        };
      }
      default:
        throw this.unsupported('This destructuring pattern is', p);
    }
  }

  private memberRef(node: es.MemberExpression): MemberRef {
    if (node.object.type === 'Super') throw this.unsupported("'super' is", node.object);
    const obj = this.expr(node.object);
    if (node.computed) return { obj, key: null, keyEx: this.expr(node.property as es.Expression) };
    if (node.property.type !== 'Identifier') throw this.unsupported('Private fields are', node.property);
    return { obj, key: this.key(node.property.name, node.property), keyEx: null };
  }

  // ---------------------------------------------------------------- expressions

  private expr(node: es.Expression | es.Literal, nameHint?: string): Ex {
    const rt = this.rt;
    switch (node.type) {
      case 'Identifier':
        return this.identifier(node);
      case 'Literal': {
        if (node.regex) throw this.unsupported('Regular expression literals are', node);
        if (typeof node.value === 'bigint' || node.bigint !== undefined) throw this.unsupported('BigInt literals are', node);
        const value = node.value;
        return () => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          return value;
        };
      }
      case 'TemplateLiteral': {
        const quasis = node.quasis.map((q) => q.value.cooked ?? '');
        const parts = node.expressions.map((e) => this.expr(e));
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          let s = quasis[0];
          let first: unknown = null;
          for (let i = 0; i < parts.length; i++) {
            const v = parts[i](env);
            if (i === 0 && s === '') first = v;
            s += (typeof v === 'string' ? v : rt.str(v)) + quasis[i + 1];
            if (s.length > rt.max) throw rt.tooBig('String length', node);
          }
          return rt.concatenated(s, first, node);
        };
      }
      case 'ThisExpression': {
        const get = this.getter('this', node);
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          return get(env);
        };
      }
      case 'ArrayExpression':
        return this.arrayLiteral(node);
      case 'ObjectExpression':
        return this.objectLiteral(node);
      case 'FunctionExpression':
      case 'ArrowFunctionExpression':
        return this.fn(node, nameHint);
      case 'UnaryExpression':
        return this.unary(node);
      case 'UpdateExpression':
        return this.update(node);
      case 'BinaryExpression': {
        if (node.left.type === 'PrivateIdentifier') throw this.unsupported('Private fields are', node.left);
        const left = this.expr(node.left);
        const right = this.expr(node.right);
        const apply = this.binary(node.operator, node);
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          return apply(left(env), right(env));
        };
      }
      case 'LogicalExpression': {
        const left = this.expr(node.left);
        const right = this.expr(node.right);
        const op = node.operator;
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          const l = left(env);
          if (op === '&&') return l ? right(env) : l;
          if (op === '||') return l ? l : right(env);
          return l === null || l === undefined ? right(env) : l;
        };
      }
      case 'AssignmentExpression':
        return this.assignment(node);
      case 'ConditionalExpression': {
        const test = this.expr(node.test);
        const yes = this.expr(node.consequent, nameHint);
        const no = this.expr(node.alternate, nameHint);
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          return test(env) ? yes(env) : no(env);
        };
      }
      case 'SequenceExpression': {
        const parts = node.expressions.map((e) => this.expr(e));
        const last = parts.length - 1;
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          for (let i = 0; i < last; i++) parts[i](env);
          return parts[last](env);
        };
      }
      case 'MemberExpression':
        return this.member(node, false);
      case 'CallExpression':
        return this.call(node, false);
      case 'NewExpression': {
        const callee = this.expr(node.callee);
        const args = this.args(node.arguments);
        const text = this.text(node.callee);
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          const ctor = callee(env);
          return rt.construct(ctor, args(env), node, text);
        };
      }
      case 'ChainExpression': {
        const inner = this.chainPart(node.expression);
        return (env) => {
          const v = inner(env);
          return v === SHORT ? undefined : v;
        };
      }
      case 'ParenthesizedExpression':
        return this.expr(node.expression, nameHint);
      case 'ClassExpression':
        throw this.unsupported('Classes are', node);
      case 'TaggedTemplateExpression':
        throw this.unsupported('Tagged template literals are', node);
      case 'YieldExpression':
        throw this.unsupported('Generators and yield are', node);
      case 'AwaitExpression':
        throw this.unsupported('async/await is', node);
      case 'ImportExpression':
        throw this.unsupported('Dynamic import() is', node);
      case 'MetaProperty':
        throw this.unsupported(`${node.meta.name}.${node.property.name} is`, node);
      default:
        throw this.unsupported(`${(node as es.Node).type} expressions are`, node);
    }
  }

  private identifier(node: es.Identifier): Ex {
    const rt = this.rt;
    const name = node.name;
    const r = this.resolve(name);
    if (r === null) {
      // A global (captured as a constant: global bindings are immutable) or an undeclared name.
      const get = this.getter(name, node);
      return (env) => {
        rt.node = node;
        if (++rt.steps >= rt.nextCheck) rt.check();
        return get(env);
      };
    }
    const hops = r.hops;
    const index = r.decl.index;
    if (r.decl.kind === 'let' || r.decl.kind === 'const') {
      if (hops === 0) {
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          const v = env[index];
          if (v === TDZ) throw this.uninitialized(name, node);
          return v;
        };
      }
      return (env) => {
        rt.node = node;
        if (++rt.steps >= rt.nextCheck) rt.check();
        const v = up(env, hops)[index];
        if (v === TDZ) throw this.uninitialized(name, node);
        return v;
      };
    }
    if (hops === 0) {
      return (env) => {
        rt.node = node;
        if (++rt.steps >= rt.nextCheck) rt.check();
        return env[index];
      };
    }
    return (env) => {
      rt.node = node;
      if (++rt.steps >= rt.nextCheck) rt.check();
      return up(env, hops)[index];
    };
  }

  private text(node: es.Node): string {
    const s = this.source.slice(node.start, node.end).replace(/\s+/g, ' ');
    return s.length > 60 ? `${s.slice(0, 57)}...` : s;
  }

  private arrayLiteral(node: es.ArrayExpression): Ex {
    const rt = this.rt;
    const n = node.elements.length;
    const spread = node.elements.map((el) => el !== null && el.type === 'SpreadElement');
    const items = node.elements.map((el) => (el === null ? null : this.expr(el.type === 'SpreadElement' ? el.argument : el)));
    if (spread.indexOf(true) === -1) {
      return (env) => {
        rt.node = node;
        if (++rt.steps >= rt.nextCheck) rt.check();
        const out = new Array<unknown>(n);
        for (let i = 0; i < n; i++) {
          const item = items[i];
          out[i] = item === null ? undefined : item(env);
        }
        rt.charge(4 + n * 4);
        return out;
      };
    }
    return (env) => {
      rt.node = node;
      if (++rt.steps >= rt.nextCheck) rt.check();
      const out: unknown[] = [];
      for (let i = 0; i < n; i++) {
        const item = items[i];
        const v = item === null ? undefined : item(env);
        if (spread[i]) {
          const more = rt.toArray(v, node.elements[i]);
          for (let j = 0; j < more.length; j++) out.push(more[j]);
        } else out.push(v);
        if (out.length > rt.max) throw rt.tooBig('Array length', node);
      }
      rt.charge(4 + out.length * 4);
      return out;
    };
  }

  private objectLiteral(node: es.ObjectExpression): Ex {
    const rt = this.rt;
    type Part = { kind: 'static'; key: string; value: Ex } | { kind: 'computed'; key: Ex; value: Ex } | { kind: 'spread'; value: Ex };
    const parts: Part[] = [];
    let staticCount = 0;
    for (const prop of node.properties) {
      if (prop.type === 'SpreadElement') {
        parts.push({ kind: 'spread', value: this.expr(prop.argument) });
        continue;
      }
      if (prop.kind !== 'init') throw this.unsupported('Getters and setters are', prop);
      const { key, keyEx } = this.propertyKey(prop);
      const value = this.expr(prop.value, key ?? undefined);
      if (key !== null) {
        parts.push({ kind: 'static', key, value });
        staticCount++;
      } else if (keyEx !== null) parts.push({ kind: 'computed', key: keyEx, value });
    }
    const n = parts.length;
    return (env) => {
      rt.node = node;
      if (++rt.steps >= rt.nextCheck) rt.check();
      // A normal object (not null-prototype) so it serialises and interoperates with host code.
      // Keys can never be "__proto__" here: static keys were validated, computed ones go through toKey.
      const out: Dict = {};
      rt.addKeys(staticCount);
      for (let i = 0; i < n; i++) {
        const part = parts[i];
        if (part.kind === 'static') out[part.key] = part.value(env);
        else if (part.kind === 'computed') {
          const k = rt.toKey(part.key(env), node);
          rt.set(out, k, part.value(env), node);
        } else {
          const source = part.value(env);
          if (typeof source === 'string') {
            for (let j = 0; j < source.length; j++) rt.set(out, String(j), source[j], node);
          } else if (typeof source === 'object' || typeof source === 'function') {
            for (const k of rt.ownKeys(source)) rt.set(out, rt.toKey(k, node), (source as Dict)[k], node);
          }
        }
      }
      return out;
    };
  }

  private unary(node: es.UnaryExpression): Ex {
    const rt = this.rt;
    const op = node.operator;
    const target = node.argument;
    if (op === 'delete') {
      if (target.type === 'MemberExpression') {
        const ref = this.memberRef(target);
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          const o = ref.obj(env);
          const k = ref.key ?? rt.toKey(ref.keyEx === null ? undefined : ref.keyEx(env), node);
          return rt.del(o, k, node);
        };
      }
      throw this.unsupported("'delete' on anything other than a property is", node);
    }
    if (op === 'typeof' && target.type === 'Identifier' && this.resolve(target.name) === null && !(target.name in rt.globals)) {
      return () => {
        rt.node = node;
        if (++rt.steps >= rt.nextCheck) rt.check();
        return 'undefined';
      };
    }
    const arg = this.expr(target);
    switch (op) {
      case '-':
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          const v = arg(env);
          return typeof v === 'number' ? -v : -rt.toNum(v, node);
        };
      case '!':
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          return !arg(env);
        };
      default:
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          const v = arg(env);
          if (op === 'typeof') return typeof v;
          if (op === 'void') return undefined;
          return op === '~' ? ~rt.toNum(v, node) : rt.toNum(v, node);
        };
    }
  }

  private update(node: es.UpdateExpression): Ex {
    const rt = this.rt;
    const delta = node.operator === '++' ? 1 : -1;
    const prefix = node.prefix;
    const target = node.argument;
    if (target.type === 'Identifier') {
      const name = target.name;
      const r = this.resolve(name);
      if (r !== null && r.decl.kind !== 'const') {
        const hops = r.hops;
        const index = r.decl.index;
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          const e = hops === 0 ? env : up(env, hops);
          let old = e[index];
          if (typeof old !== 'number') {
            if (old === TDZ) throw this.uninitialized(name, node);
            old = rt.toNum(old, node);
          }
          e[index] = (old as number) + delta;
          return prefix ? (old as number) + delta : old;
        };
      }
      const get = this.getter(name, target);
      const set = this.setter(name, target);
      return (env) => {
        rt.node = node;
        if (++rt.steps >= rt.nextCheck) rt.check();
        const old = rt.toNum(get(env), node);
        set(env, old + delta);
        return prefix ? old + delta : old;
      };
    }
    if (target.type !== 'MemberExpression') throw this.unsupported('This update target is', node);
    const ref = this.memberRef(target);
    return (env) => {
      rt.node = node;
      if (++rt.steps >= rt.nextCheck) rt.check();
      const o = ref.obj(env);
      const k = ref.key ?? this.computedKey(ref, env, target);
      const old = rt.toNum(rt.getc(o, k, target), node);
      rt.setc(o, k, old + delta, target);
      return prefix ? old + delta : old;
    };
  }

  /** Evaluate a computed key once, validated, keeping array indexes numeric. */
  private computedKey(ref: MemberRef, env: Env, node: es.Node): string | number {
    const raw = ref.keyEx === null ? undefined : ref.keyEx(env);
    return typeof raw === 'number' ? raw : this.rt.toKey(raw, node);
  }

  private binary(op: string, node: es.Node): (l: unknown, r: unknown) => unknown {
    const rt = this.rt;
    switch (op) {
      case '+':
        return (l, r) => (typeof l === 'number' && typeof r === 'number' ? l + r : addSlow(rt, l, r, node));
      case '-':
        return (l, r) => (typeof l === 'number' && typeof r === 'number' ? l - r : arithSlow(rt, op, l, r));
      case '*':
        return (l, r) => (typeof l === 'number' && typeof r === 'number' ? l * r : arithSlow(rt, op, l, r));
      case '/':
        return (l, r) => (typeof l === 'number' && typeof r === 'number' ? l / r : arithSlow(rt, op, l, r));
      case '<':
        return (l, r) => (typeof l === 'number' && typeof r === 'number' ? l < r : arithSlow(rt, op, l, r));
      case '>':
        return (l, r) => (typeof l === 'number' && typeof r === 'number' ? l > r : arithSlow(rt, op, l, r));
      case '<=':
        return (l, r) => (typeof l === 'number' && typeof r === 'number' ? l <= r : arithSlow(rt, op, l, r));
      case '>=':
        return (l, r) => (typeof l === 'number' && typeof r === 'number' ? l >= r : arithSlow(rt, op, l, r));
      case '===':
        return (l, r) => l === r;
      case '!==':
        return (l, r) => l !== r;
      case 'in':
        return (l, r) => rt.has(l, r, node);
      case 'instanceof':
        return (l, r) => rt.instanceOf(l, r, node);
      default:
        return (l, r) => arithSlow(rt, op, l, r);
    }
  }

  private assignment(node: es.AssignmentExpression): Ex {
    const rt = this.rt;
    const op = node.operator;
    const left = node.left;
    const right = this.expr(node.right, left.type === 'Identifier' ? left.name : undefined);

    if (op === '=') {
      if (left.type === 'Identifier') {
        const set = this.setter(left.name, left);
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          const v = right(env);
          set(env, v);
          return v;
        };
      }
      if (left.type === 'MemberExpression') {
        const ref = this.memberRef(left);
        const key = ref.key;
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          const o = ref.obj(env);
          if (key !== null) {
            const v = right(env);
            rt.set(o, key, v, left);
            return v;
          }
          const k = ref.keyEx === null ? undefined : ref.keyEx(env);
          const v = right(env);
          rt.setc(o, k, v, left);
          return v;
        };
      }
      const bind = this.pattern(left, false);
      return (env) => {
        rt.node = node;
        if (++rt.steps >= rt.nextCheck) rt.check();
        const v = right(env);
        bind(env, v);
        return v;
      };
    }

    // Compound (`+=` …) and logical (`&&=` `||=` `??=`) assignment.
    const logical = op === '&&=' || op === '||=' || op === '??=';
    const apply = this.binary(op.slice(0, -1), node);
    const keeps = (cur: unknown): boolean => (op === '&&=' ? !cur : op === '||=' ? Boolean(cur) : cur !== null && cur !== undefined);

    if (left.type === 'Identifier') {
      const name = left.name;
      const r = this.resolve(name);
      if (r !== null && r.decl.kind !== 'const' && !logical) {
        const hops = r.hops;
        const index = r.decl.index;
        return (env) => {
          rt.node = node;
          if (++rt.steps >= rt.nextCheck) rt.check();
          const e = hops === 0 ? env : up(env, hops);
          const cur = e[index];
          if (cur === TDZ) throw this.uninitialized(name, node);
          const v = apply(cur, right(env));
          e[index] = v;
          return v;
        };
      }
      const get = this.getter(name, left);
      const set = this.setter(name, left);
      return (env) => {
        rt.node = node;
        if (++rt.steps >= rt.nextCheck) rt.check();
        const cur = get(env);
        if (logical && keeps(cur)) return cur;
        const v = logical ? right(env) : apply(cur, right(env));
        set(env, v);
        return v;
      };
    }
    if (left.type !== 'MemberExpression') throw this.unsupported('This assignment target is', left);
    const ref = this.memberRef(left);
    return (env) => {
      rt.node = node;
      if (++rt.steps >= rt.nextCheck) rt.check();
      const o = ref.obj(env);
      const k = ref.key ?? this.computedKey(ref, env, left);
      const cur = rt.getc(o, k, left);
      if (logical && keeps(cur)) return cur;
      const v = logical ? right(env) : apply(cur, right(env));
      rt.setc(o, k, v, left);
      return v;
    };
  }

  private chainPart(node: es.Expression | es.Super): Ex {
    if (node.type === 'MemberExpression') return this.member(node, true);
    if (node.type === 'CallExpression') return this.call(node, true);
    if (node.type === 'Super') throw this.unsupported("'super' is", node);
    return this.expr(node);
  }

  private member(node: es.MemberExpression, inChain: boolean): Ex {
    const rt = this.rt;
    if (node.object.type === 'Super') throw this.unsupported("'super' is", node.object);
    const obj = inChain ? this.chainPart(node.object) : this.expr(node.object);
    const optional = node.optional;
    if (node.computed) {
      const keyEx = this.expr(node.property as es.Expression);
      return (env) => {
        rt.node = node;
        if (++rt.steps >= rt.nextCheck) rt.check();
        const o = obj(env);
        if (inChain && (o === SHORT || (optional && (o === null || o === undefined)))) return SHORT;
        return rt.getc(o, keyEx(env), node);
      };
    }
    if (node.property.type !== 'Identifier') throw this.unsupported('Private fields are', node.property);
    const key = this.key(node.property.name, node.property);
    return (env) => {
      rt.node = node;
      if (++rt.steps >= rt.nextCheck) rt.check();
      const o = obj(env);
      if (inChain && (o === SHORT || (optional && (o === null || o === undefined)))) return SHORT;
      return rt.get(o, key, node);
    };
  }

  private call(node: es.CallExpression, inChain: boolean): Ex {
    const rt = this.rt;
    const callee = node.callee;
    const args = this.args(node.arguments);
    const text = this.text(callee);
    const optionalCall = node.optional;
    if (callee.type === 'Super') throw this.unsupported("'super' is", callee);
    if (callee.type === 'MemberExpression') {
      // Method call: the receiver becomes `this`.
      if (callee.object.type === 'Super') throw this.unsupported("'super' is", callee.object);
      const obj = inChain ? this.chainPart(callee.object) : this.expr(callee.object);
      const optionalMember = callee.optional;
      let key: string | null = null;
      let keyEx: Ex | null = null;
      if (callee.computed) keyEx = this.expr(callee.property as es.Expression);
      else if (callee.property.type === 'Identifier') key = this.key(callee.property.name, callee.property);
      else throw this.unsupported('Private fields are', callee.property);
      return (env) => {
        rt.node = node;
        if (++rt.steps >= rt.nextCheck) rt.check();
        const o = obj(env);
        if (inChain && (o === SHORT || (optionalMember && (o === null || o === undefined)))) return SHORT;
        const f = key !== null ? rt.get(o, key, callee) : rt.getc(o, keyEx === null ? undefined : keyEx(env), callee);
        if (optionalCall && (f === null || f === undefined)) return SHORT;
        return rt.call(f, o, args(env), node, text);
      };
    }
    const fn = inChain ? this.chainPart(callee) : this.expr(callee);
    return (env) => {
      rt.node = node;
      if (++rt.steps >= rt.nextCheck) rt.check();
      const f = fn(env);
      if (inChain && (f === SHORT || (optionalCall && (f === null || f === undefined)))) return SHORT;
      return rt.call(f, undefined, args(env), node, text);
    };
  }

  private args(nodes: readonly (es.Expression | es.SpreadElement)[]): (env: Env) => unknown[] {
    const rt = this.rt;
    const spread = nodes.map((a) => a.type === 'SpreadElement');
    const items = nodes.map((a) => this.expr(a.type === 'SpreadElement' ? a.argument : a));
    const n = items.length;
    if (spread.indexOf(true) !== -1) {
      return (env) => {
        const out: unknown[] = [];
        for (let i = 0; i < n; i++) {
          const v = items[i](env);
          if (spread[i]) {
            const more = rt.toArray(v, nodes[i]);
            for (let j = 0; j < more.length; j++) out.push(more[j]);
          } else out.push(v);
          if (out.length > MAX_CALL_ARGS) {
            throw rt.fail('limit', `Too many arguments in one call (more than ${MAX_CALL_ARGS}); use a loop or reduce() instead of spreading a large array`, nodes[i]);
          }
        }
        return out;
      };
    }
    if (n === 0) return () => [];
    if (n === 1) {
      const a = items[0];
      return (env) => [a(env)];
    }
    if (n === 2) {
      const a = items[0];
      const b = items[1];
      return (env) => [a(env), b(env)];
    }
    return (env) => {
      const out = new Array<unknown>(n);
      for (let i = 0; i < n; i++) out[i] = items[i](env);
      return out;
    };
  }

  // ---------------------------------------------------------------- functions

  private fn(node: FunctionNode, nameHint?: string): Ex {
    const rt = this.rt;
    if (node.async) throw this.unsupported('async functions are', node);
    if (node.generator) throw this.unsupported('Generator functions are', node);
    this.fnCount++;
    const arrow = node.type === 'ArrowFunctionExpression';
    const name = node.id ? node.id.name : (nameHint ?? '');
    const scope = this.push();
    const thisIndex = arrow ? -1 : scope.declare('this', 'var').index;
    for (const p of node.params) this.declarePattern(p, 'var', scope);
    const block = node.body.type === 'BlockStatement' ? node.body : null;
    if (block !== null) {
      this.hoistVars(block.body, scope);
      this.declareLexical(block.body, scope);
    }
    // A named function expression can refer to itself by name.
    const selfIndex = node.type === 'FunctionExpression' && node.id && !scope.names.has(node.id.name) ? scope.declare(node.id.name, 'fn').index : -1;

    const simple = node.params.every((p) => p.type === 'Identifier');
    const paramCount = node.params.length;
    const slots = simple ? node.params.map((p) => scope.names.get((p as es.Identifier).name)?.index ?? 0) : [];
    const binders = simple ? [] : node.params.map((p) => this.pattern(p.type === 'RestElement' ? p.argument : p, true));
    const restAt = node.params.findIndex((p) => p.type === 'RestElement');
    const firstOptional = node.params.findIndex((p) => p.type === 'AssignmentPattern' || p.type === 'RestElement');
    const length = firstOptional === -1 ? paramCount : firstOptional;

    const bodyStatements = block !== null ? this.statements(block.body) : null;
    const bodyExpression = block === null ? this.expr(node.body as es.Expression) : null;
    this.pop();
    const template = scope.template();
    const meta = { name, length };
    const maxDepth = rt.maxDepth;

    const run = (parent: Env, thisVal: unknown, args: unknown[], self: unknown): unknown => {
      if (rt.done) throw rt.finished();
      // Call depth is bounded here, long before the host stack is at risk.
      if (rt.depth >= maxDepth) throw rt.fail('limit', `Script exceeded the maximum call depth of ${maxDepth}`);
      rt.depth++;
      rt.stack.push(name);
      try {
        // Counts as a step even when a native method invokes the function directly.
        rt.node = node;
        if (++rt.steps >= rt.nextCheck) rt.check();
        const env = template.slice();
        env[0] = parent;
        if (thisIndex > 0) env[thisIndex] = thisVal;
        if (selfIndex > 0) env[selfIndex] = self;
        if (simple) {
          for (let i = 0; i < paramCount; i++) env[slots[i]] = args[i];
        } else {
          for (let i = 0; i < paramCount; i++) binders[i](env, i === restAt ? args.slice(i) : args[i]);
        }
        if (bodyExpression !== null) return bodyExpression(env);
        if (bodyStatements !== null && bodyStatements(env) === RETURN) {
          const v = rt.retVal;
          rt.retVal = undefined;
          return v;
        }
        return undefined;
      } finally {
        rt.depth--;
        rt.stack.pop();
      }
    };

    // Interpreted functions are real host callables so native methods (map, sort, …) and host
    // APIs can invoke them. `this` can never be the host global object: this module is strict
    // code, and a sloppy caller's global receiver is discarded explicitly as well.
    return (env) => {
      rt.node = node;
      if (++rt.steps >= rt.nextCheck) rt.check();
      const f: (...args: unknown[]) => unknown = arrow
        ? (...args: unknown[]) => run(env, undefined, args, f)
        : function (this: unknown, ...args: unknown[]) {
            return run(env, this === globalThis ? undefined : this, args, f);
          };
      rt.fnMeta.set(f, meta);
      return f;
    };
  }
}

// ------------------------------------------------------------------ entry point

function resolveLimits(partial: Partial<RunLimits> | null | undefined): RunLimits {
  const limits: RunLimits = { ...DEFAULT_LIMITS };
  if (partial) {
    for (const k of Object.keys(DEFAULT_LIMITS) as (keyof RunLimits)[]) {
      const v = partial[k];
      if (typeof v === 'number' && !Number.isNaN(v)) limits[k] = v;
    }
  }
  return limits;
}

function clip(message: string): string {
  return message.length > 1000 ? `${message.slice(0, 1000)}…` : message;
}

/** String form of an uncaught thrown value, computed without running any script code. */
function thrownMessage(rt: Runtime, value: unknown): string {
  if (value instanceof Error) return errorText(value);
  if (typeof value === 'string') return value;
  try {
    if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
      const message = Object.getOwnPropertyDescriptor(value, 'message')?.value as unknown;
      return typeof message === 'string' ? message : Object.prototype.toString.call(value);
    }
    return rt.str(value);
  } catch {
    return Object.prototype.toString.call(value);
  }
}

function toScriptError(e: unknown, rt: Runtime | null): ScriptError {
  if (e instanceof ScriptError) return e;
  if (e instanceof Thrown) {
    const message = rt === null ? String(e.value) : thrownMessage(rt, e.value);
    return new ScriptError(e.kind, clip(message), e.line, e.column, e.scriptStack);
  }
  const at = rt?.node?.loc?.start;
  if (isStackOverflow(e)) {
    return new ScriptError('limit', 'Script is nested too deeply (host stack overflow)', at?.line, at?.column);
  }
  // A raw host error from an operator or conversion (e.g. a value that cannot be stringified).
  return new ScriptError('runtime', clip(e instanceof Error ? errorText(e) : String(e)), at?.line, at?.column);
}

function syntaxError(e: unknown): ScriptError {
  const err = e as { message?: unknown; loc?: { line?: unknown; column?: unknown } };
  const message = typeof err.message === 'string' ? err.message.replace(/\s*\(\d+:\d+\)$/, '') : 'Invalid syntax';
  const line = typeof err.loc?.line === 'number' ? err.loc.line : undefined;
  const column = typeof err.loc?.column === 'number' ? err.loc.column : undefined;
  // acorn guards its own recursion ("Not enough stack space to parse input").
  if (isStackOverflow(e) || /stack space/i.test(message)) {
    return new ScriptError('limit', 'Script is nested too deeply to parse', line, column);
  }
  return new ScriptError('syntax', message, line, column);
}

/**
 * Run a script to completion. Throws `ScriptError` only.
 *
 * The result value is the argument of a top-level `return`, otherwise the value of the last
 * top-level expression statement, otherwise undefined.
 */
export function runScript(source: string, options?: RunOptions): RunResult {
  const started = Date.now();
  const globals = options?.globals ?? undefined;
  const signal = options?.signal ?? undefined;
  const limits = resolveLimits(options?.limits);
  if (typeof source !== 'string') throw new ScriptError('syntax', 'Script source must be a string');
  if (source.length > limits.maxSourceLength) {
    throw new ScriptError('limit', `Script is too long (${source.length} characters; the limit is ${limits.maxSourceLength})`);
  }
  let rt: Runtime | null = null;
  try {
    let ast: es.Program;
    try {
      // Parsed as a sloppy script so that constructs such as `with` reach the validator and get
      // a helpful message; the interpreter itself implements strict-mode semantics.
      ast = parse(source, {
        ecmaVersion: 2022,
        sourceType: 'script',
        locations: true,
        allowReturnOutsideFunction: true,
        allowAwaitOutsideFunction: true,
        allowImportExportEverywhere: true,
        allowSuperOutsideMethod: true,
      });
    } catch (e) {
      throw syntaxError(e);
    }
    rt = new Runtime(limits, signal, started, globals);
    // Compiling validates the whole program: nothing has run when this throws.
    const program = new Compiler(rt, source).compileProgram(ast);
    if (signal?.aborted) throw rt.fail('aborted', 'Script was aborted');
    const value = program();
    // An uncatchable error swallowed by host code must still end the run as a failure.
    if (rt.fatal !== null) throw rt.fatal;
    return { value, steps: rt.steps, durationMs: Date.now() - started };
  } catch (e) {
    if (rt !== null) rt.done = true;
    throw toScriptError(e, rt);
  } finally {
    if (rt !== null) rt.done = true;
  }
}
