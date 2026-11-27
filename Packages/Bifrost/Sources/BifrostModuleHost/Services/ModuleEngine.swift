import BifrostModuleHostCore
import Foundation
import JavaScriptCore

// The module's JavaScript context, which lives on the main actor because JavaScriptCore runs a
// context's work on the thread that calls into it. The context starts when the code arrives: the
// host adds its few globals, runs the module, and from then on timers and events call back into
// the same context.
@MainActor
final class ModuleEngine {
    private var context: JSContext?
    // The prelude's two hooks: fire(id) runs a timer and event(handler, json) hands an event to
    // the module.
    private var hooks: JSValue?

    func handle(_ message: HostMessage) {
        switch message {
        case .code(let source): run(source)
        case .ping(let id): HostOutput.send(.pong(id))
        case .event(let handler, let value): deliver(value, to: handler)
        }
    }

    private func run(_ source: String) {
        guard let context = JSContext() else {
            HostOutput.send(.log("JavaScriptCore didn't start, so the module can't run"))
            return
        }
        self.context = context
        context.exceptionHandler = { _, exception in
            HostOutput.send(.log("Uncaught " + Self.describe(exception)))
        }
        // The timers run on the main queue, which is the main actor's, so a timer can't fire in
        // the middle of other JavaScript.
        let startTimer: @convention(block) (Int, Double) -> Void = { [weak self] id, delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000) { self?.fire(id) }
        }
        // The ops come as JSON text and go out re-encoded, so whatever the module passes, the
        // batch line is plain JSON in the protocol's shape.
        let sendBatch: @convention(block) (String) -> Bool = { json in
            guard let ops = try? JSONDecoder().decode([JSONValue].self, from: Data(json.utf8))
            else { return false }
            HostOutput.send(.batch(ops))
            return true
        }
        let sendLog: @convention(block) (String) -> Void = { text in
            HostOutput.send(.log(text))
        }
        hooks = context.evaluateScript(Self.prelude)?
            .call(withArguments: [startTimer, sendBatch, sendLog])
        context.evaluateScript(source, withSourceURL: URL(string: "bifrost-module:///module.js"))
    }

    private func fire(_ id: Int) {
        hooks?.invokeMethod("fire", withArguments: [id])
    }

    // An event before the code has run has no module to go to, so it's dropped.
    private func deliver(_ value: JSONValue, to handler: Int) {
        guard let hooks, let json = try? JSONEncoder().encode(value) else { return }
        hooks.invokeMethod("event", withArguments: [handler, String(decoding: json, as: UTF8.self)])
    }

    private static func describe(_ exception: JSValue?) -> String {
        guard let exception, let text = exception.toString() else { return "exception" }
        guard let line = exception.objectForKeyedSubscript("line"), line.isNumber else {
            return text
        }
        return "\(text) (line \(line.toInt32()))"
    }

    // The globals the host adds, and nothing else: setTimeout, clearTimeout, queueMicrotask, a
    // console that sends log lines and __bifrostSend for the batches. The module sets
    // __bifrostOnEvent itself, and the host calls it with the handler and value of each event.
    // The native functions come in as arguments, so the module can't reach them directly.
    private static let prelude = """
        (function (startTimer, sendBatch, sendLog) {
          'use strict';
          const timers = new Map();
          let nextTimer = 1;
          globalThis.setTimeout = function (callback, delay, ...args) {
            if (typeof callback !== 'function') throw new TypeError('setTimeout needs a function');
            const id = nextTimer++;
            timers.set(id, () => callback(...args));
            startTimer(id, Math.min(Math.max(Number(delay) || 0, 0), 2147483647));
            return id;
          };
          globalThis.clearTimeout = function (id) {
            timers.delete(id);
          };
          const text = (value) => {
            if (typeof value === 'string' || value instanceof Error) return String(value);
            try {
              const json = JSON.stringify(value);
              return json === undefined ? String(value) : json;
            } catch {
              return String(value);
            }
          };
          const log = (...values) => sendLog(values.map(text).join(' '));
          globalThis.console = { log, info: log, warn: log, error: log, debug: log };
          globalThis.queueMicrotask = function (callback) {
            if (typeof callback !== 'function') throw new TypeError('queueMicrotask needs one');
            Promise.resolve().then(callback).catch((error) => log('Uncaught', error));
          };
          globalThis.__bifrostSend = function (ops) {
            if (!Array.isArray(ops)) throw new TypeError('__bifrostSend needs an array');
            if (!sendBatch(JSON.stringify(ops))) throw new TypeError('__bifrostSend needs JSON');
          };
          return {
            fire(id) {
              const run = timers.get(id);
              if (run) {
                timers.delete(id);
                run();
              }
            },
            event(handler, json) {
              const onEvent = globalThis.__bifrostOnEvent;
              if (typeof onEvent === 'function') onEvent(handler, JSON.parse(json));
            },
          };
        })
        """
}
