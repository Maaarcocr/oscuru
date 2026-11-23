import Foundation
import JavaScriptCore
import OscuruCore

/// Runs edit scripts in JavaScriptCore.
///
/// One runtime belongs to one open photo and keeps one JavaScript context alive between scripts,
/// so the agent can work as in a REPL. The context contains standard JavaScript and two globals,
/// `photo` and `console`; it has no way to reach the network, files or the rest of the app.
///
/// Scripts are not given a time limit. They stop when they end, or when the caller cancels:
/// every API call then throws, and a script that never calls the API (a bare endless loop) is
/// abandoned along with its context, so the app carries on with a fresh one.
public final class ScriptRuntime: @unchecked Sendable {
    private weak var host: ScriptHost?
    private let lock = NSLock()
    private var engine: Engine?

    /// How long a cancelled script gets to notice before its context is abandoned.
    public var abandonAfter: TimeInterval = 2

    public init(host: ScriptHost) {
        self.host = host
    }

    /// One JavaScript context and the thread it runs on.
    private final class Engine {
        let queue = DispatchQueue(label: "app.oscuru.script", qos: .userInitiated)
        let context: JSContext
        var session: ScriptSession?
        var abandoned = false

        init() {
            context = JSContext()!
            context.name = "Oscuru edit scripts"
            let native: @convention(block) (String, String) -> String = { [weak self] name, argumentsJSON in
                self?.dispatch(name, argumentsJSON) ?? #"{"error":{"name":"Error","message":"The script environment has gone away."}}"#
            }
            context.setObject(native, forKeyedSubscript: "__oscuruNative" as NSString)
            context.evaluateScript(ScriptRuntime.prelude)?.call(withArguments: [context.objectForKeyedSubscript("__oscuruNative") as Any])
            context.evaluateScript("delete globalThis.__oscuruNative")
        }

        /// The single bridge function: a name and JSON arguments in, JSON out.
        func dispatch(_ name: String, _ argumentsJSON: String) -> String {
            func failure(_ name: String, _ message: String) -> String {
                JSONValue.object(["error": ["name": .string(name), "message": .string(message)]]).text()
            }
            guard let session, !abandoned else { return failure("Cancelled", "The script was stopped.") }
            let arguments = JSONValue(text: argumentsJSON)?.arrayValue ?? []
            do {
                return JSONValue.object(["ok": try session.call(name, arguments)]).text()
            } catch let error as StateError {
                return failure("RangeError", error.message)
            } catch is ScriptSession.Cancelled {
                return failure("Cancelled", "The script was stopped.")
            } catch let error as ScriptSession.Failure {
                return failure("Error", error.message)
            } catch {
                return failure("Error", String(describing: error))
            }
        }

        func run(_ request: ScriptRequest, host: ScriptHost, isCancelled: @escaping () -> Bool) -> ScriptOutcome {
            let started = Date()
            let session = ScriptSession(request: request, host: host, isCancelled: isCancelled)
            self.session = session
            defer { self.session = nil }

            var thrown: JSValue?
            context.exceptionHandler = { _, exception in thrown = exception }
            // A block keeps `let` and `const` to this call, so a script can declare the same names
            // again next time, while `var` and functions stay in the context.
            let lineOffset = 1
            var result = context.evaluateScript("{\n\(request.code)\n}")
            if let exception = thrown, exception.forProperty("name")?.toString() == "SyntaxError",
                (exception.forProperty("message")?.toString() ?? "").contains("Return statements are only valid inside functions")
            {
                // Written as a function body, with `return`: run it as one.
                thrown = nil
                result = context.evaluateScript("(function () {\n\(request.code)\n}).call(undefined)")
            }
            context.exceptionHandler = nil

            var outcome = ScriptOutcome(
                error: nil, state: session.draft, changes: [], logs: session.logs, returnValue: nil, shown: session.shown,
                durationMs: Int(Date().timeIntervalSince(started) * 1000))
            if let exception = thrown {
                let line = exception.forProperty("line").flatMap { $0.isNumber ? Int($0.toInt32()) - lineOffset : nil }
                let column = exception.forProperty("column").flatMap { $0.isNumber ? Int($0.toInt32()) : nil }
                var name = exception.isObject ? (exception.forProperty("name")?.toString() ?? "Error") : "Error"
                var message = exception.isObject ? (exception.forProperty("message")?.toString() ?? exception.toString() ?? "") : (exception.toString() ?? "")
                if isCancelled() {
                    name = "Cancelled"
                    message = "The script was stopped."
                }
                outcome.error = ScriptFailure(name: name, message: message, line: line.flatMap { $0 > 0 ? $0 : nil }, column: column)
                outcome.state = request.state
                return outcome
            }
            outcome.changes = session.draft.changes(from: request.state)
            if let result, !result.isUndefined {
                var text: String?
                if let stringify = context.objectForKeyedSubscript("JSON")?.forProperty("stringify"), let json = stringify.call(withArguments: [result]), json.isString {
                    text = json.toString()
                }
                context.exception = nil
                let described = text ?? result.toString() ?? ""
                outcome.returnValue = described.count > ScriptRuntime.maxReturnLength ? String(described.prefix(ScriptRuntime.maxReturnLength)) + "…" : described
            }
            return outcome
        }
    }

    static let maxReturnLength = 20000

    private func currentEngine() -> Engine {
        lock.lock()
        defer { lock.unlock() }
        if let engine, !engine.abandoned { return engine }
        let fresh = Engine()
        engine = fresh
        return fresh
    }

    /// Runs one script as a transaction. Returns when the script has ended, or shortly after
    /// `isCancelled` starts returning true.
    public func run(_ request: ScriptRequest, isCancelled: @escaping @Sendable () -> Bool) async -> ScriptOutcome {
        guard let host else {
            return ScriptOutcome(
                error: ScriptFailure(name: "Error", message: "The photo is no longer open."), state: request.state, changes: [], logs: [], returnValue: nil,
                shown: [], durationMs: 0)
        }
        let engine = currentEngine()
        let abandonAfter = abandonAfter
        return await withCheckedContinuation { (continuation: CheckedContinuation<ScriptOutcome, Never>) in
            let finish = Finish(continuation)
            engine.queue.async {
                let outcome = engine.run(request, host: host, isCancelled: isCancelled)
                finish.resume(outcome)
            }
            // Watches for a cancelled script that does not come back.
            DispatchQueue.global(qos: .utility).async {
                var cancelledAt: Date?
                while !finish.isDone {
                    Thread.sleep(forTimeInterval: 0.1)
                    guard isCancelled() else { continue }
                    if cancelledAt == nil { cancelledAt = Date() }
                    if let cancelledAt, Date().timeIntervalSince(cancelledAt) >= abandonAfter {
                        engine.abandoned = true
                        finish.resume(
                            ScriptOutcome(
                                error: ScriptFailure(name: "Cancelled", message: "The script was stopped."), state: request.state, changes: [], logs: [],
                                returnValue: nil, shown: [], durationMs: 0))
                    }
                }
            }
        }
    }

    /// Resumes a continuation once, whichever of two threads gets there first.
    private final class Finish: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ScriptOutcome, Never>?

        init(_ continuation: CheckedContinuation<ScriptOutcome, Never>) {
            self.continuation = continuation
        }

        var isDone: Bool {
            lock.lock()
            defer { lock.unlock() }
            return continuation == nil
        }

        func resume(_ outcome: ScriptOutcome) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: outcome)
        }
    }

    /// Defines `photo` and `console` from the one native function, then hides that function.
    static let prelude = #"""
        (function (native) {
          "use strict";
          const call = (name, ...args) => {
            const reply = JSON.parse(native(name, JSON.stringify(args)));
            if (reply.error) {
              const error = reply.error.name === "RangeError" ? new RangeError(reply.error.message) : new Error(reply.error.message);
              if (reply.error.name === "Cancelled") error.name = "Cancelled";
              throw error;
            }
            return reply.ok;
          };
          const bind = (name) => (...args) => call(name, ...args);
          const group = (prefix, names) => Object.freeze(Object.fromEntries(names.map((name) => [name, bind(prefix + "." + name)])));
          const current = Object.freeze({
            getState: bind("getState"),
            getMetadata: bind("getMetadata"),
            getHistogram: bind("getHistogram"),
            getStatistics: bind("getStatistics"),
            adjust: bind("adjust"),
            curves: group("curves", ["set", "get", "reset"]),
            hsl: group("hsl", ["adjust", "get", "reset"]),
            grading: group("grading", ["set", "get", "configure", "reset"]),
            detail: group("detail", ["set", "get"]),
            crop: bind("crop"),
            reset: bind("reset"),
            revert: bind("revert"),
            commit: bind("commit"),
          });
          const photo = Object.freeze({ current, show: bind("show"), filters: group("filters", ["list", "apply", "save", "delete"]) });
          const describe = (value) => {
            if (typeof value === "string") return value;
            if (value instanceof Error) return value.name + ": " + value.message;
            try {
              const text = JSON.stringify(value);
              return text === undefined ? String(value) : text;
            } catch (error) {
              return String(value);
            }
          };
          const log = (...values) => { call("log", values.map(describe).join(" ")); };
          const define = (name, value) => Object.defineProperty(globalThis, name, { value, writable: false, configurable: false, enumerable: true });
          define("photo", photo);
          define("console", Object.freeze({ log, info: log, warn: log, error: log, debug: log }));
        })
        """#
}
