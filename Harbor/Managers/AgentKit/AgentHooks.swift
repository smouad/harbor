// Licensed under GPL-3.0. See LICENSE.
//
//  AgentHooks.swift
//  Harbor
//
//  A recipe's `hooks`: JavaScript functions its `call` steps run, Browser Bridge's hooks.mjs (an
//  `export` in front of a function is dropped). They run in a JavaScriptCore context of their own,
//  away from any page and with no network, files or timers, so a hook computes from what it is
//  given ({arg, vars, input}) and returns a value. Each call gets a fresh context and 5 s.
//

import Foundation
import JavaScriptCore

enum AgentHooks {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let seconds = 5.0

    /// Throws when `source` does not parse.
    static func check(_ source: String) throws {
        let context = try makeContext(source)
        _ = context
    }

    /// The value the hook returns (a promise is awaited), as JSON-like Foundation values.
    @MainActor
    static func call(_ hook: String, source: String, arg: Any?, vars: [String: Any], input: [String: Any]) async throws -> Any {
        guard hook.range(of: #"^[A-Za-z_$][\w$]*$"#, options: .regularExpression) != nil else {
            throw Failure(message: "\(hook) is not a function name")
        }
        let args: [String: Any] = ["arg": arg ?? NSNull(), "vars": vars, "input": input]
        // Off the main thread: a slow hook must not hold the app.
        return try await Task.detached(priority: .userInitiated) { try run(hook, source: source, args: args) }.value
    }

    private nonisolated static func run(_ hook: String, source: String, args: [String: Any]) throws -> Any {
        let context = try makeContext(source)
        guard context.evaluateScript("typeof \(hook) === 'function'")?.toBool() == true else {
            throw Failure(message: "The recipe's hooks have no function \(hook)")
        }
        context.setObject(args, forKeyedSubscript: "__harborArgs" as NSString)
        // A promise settles in the microtasks JavaScriptCore runs before evaluateScript returns.
        context.evaluateScript("""
            globalThis.__harborOut = undefined;
            Promise.resolve().then(() => \(hook)(__harborArgs)).then(
                v => { __harborOut = { ok: true, value: v === undefined ? null : JSON.parse(JSON.stringify(v)) }; },
                e => { __harborOut = { ok: false, error: String((e && e.message) || e) }; });
            """)
        if let exception = context.exception {
            throw Failure(message: "\(hook): \(exception.toString() ?? "failed")")
        }
        guard let out = context.objectForKeyedSubscript("__harborOut"), !out.isUndefined,
              let result = out.toDictionary() else {
            throw Failure(message: "\(hook) did not finish within \(Int(seconds)) s (hooks have no timers or network)")
        }
        guard result["ok"] as? Bool == true else { throw Failure(message: "\(hook): \(result["error"] ?? "failed")") }
        return result["value"] ?? NSNull()
    }

    private nonisolated static func makeContext(_ source: String) throws -> JSContext {
        guard let context = JSContext() else { throw Failure(message: "JavaScriptCore is unavailable") }
        limitTime(context)
        let script = source.replacingOccurrences(of: #"(?m)^(\s*)export\s+(default\s+)?"#, with: "$1", options: .regularExpression)
        context.evaluateScript(script)
        if let exception = context.exception {
            throw Failure(message: "The recipe's hooks do not run: \(exception.toString() ?? "syntax error")")
        }
        return context
    }

    /// JavaScriptCore stops a script that runs past the limit (exported, though not in the public
    /// headers); without it a hook that never returns would keep its thread busy.
    private typealias SetTimeLimit = @convention(c) (JSContextGroupRef, Double, OpaquePointer?, UnsafeMutableRawPointer?) -> Void
    private nonisolated static let setTimeLimit: SetTimeLimit? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: SetTimeLimit.self)
    }()

    private nonisolated static func limitTime(_ context: JSContext) {
        guard let setTimeLimit, let global = context.jsGlobalContextRef else { return }
        setTimeLimit(JSContextGetGroup(global), seconds, nil, nil)
    }
}
