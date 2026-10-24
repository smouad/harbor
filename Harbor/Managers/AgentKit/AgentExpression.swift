// Licensed under GPL-3.0. See LICENSE.
//
//  AgentExpression.swift
//  Harbor
//
//  The expressions in a recipe's `when` and `set expr`, Browser Bridge's small safe language:
//  numbers, strings, true/false/null, dotted paths into the run's scopes (`vars.count`,
//  `item.name`, `vars.rows.length`, `vars.rows.0`), + - * /, comparisons, && ||, ! and
//  parentheses. It reads values and nothing else: no calls, no assignment, no page access. A field
//  an object lacks reads null, as in JavaScript; a name that is not a scope is an error.
//  Foundation only, so scripts/tests/AgentPolicyCheck.swift compiles it directly.
//

import Foundation

enum AgentExpression {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The value of `expression` against `scopes`; NSNull for null.
    static func evaluate(_ expression: String, scopes: [String: Any]) throws -> Any {
        guard expression.count <= 2000 else { throw Failure(message: "An expression is at most 2000 characters") }
        var parser = Parser(tokens: try tokenize(expression), scopes: scopes, source: expression)
        let value = try parser.or()
        guard parser.index == parser.tokens.count else { throw Failure(message: "Unexpected text after the expression: \(expression)") }
        return value
    }

    /// JavaScript's truthiness: false, 0, NaN, "", null and a missing value are false.
    static func truthy(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull: return false
        case let text as String: return !text.isEmpty
        case let number as NSNumber:
            if isBool(number) { return number.boolValue }
            let d = number.doubleValue
            return d != 0 && !d.isNaN
        case let flag as Bool: return flag
        default: return true
        }
    }

    /// A value at `path` (dots; a number indexes a list; `length` counts a list or text).
    static func lookup(_ path: [String], in scopes: [String: Any]) -> Any? {
        var current: Any? = scopes
        for part in path {
            if let dict = current as? [String: Any] {
                current = dict[part]
            } else if let list = current as? [Any] {
                if part == "length" { current = list.count }
                else if let index = Int(part), list.indices.contains(index) { current = list[index] }
                else { return nil }
            } else if let text = current as? String, part == "length" {
                current = text.count
            } else {
                return nil
            }
        }
        return current
    }

    // MARK: - Tokens

    private enum Token: Equatable {
        case number(Double), string(String), bool(Bool), null, name(String), op(String), open, close, dot
    }

    private static func tokenize(_ expression: String) throws -> [Token] {
        let chars = Array(expression)
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            switch c {
            case "(": tokens.append(.open); i += 1; continue
            case ")": tokens.append(.close); i += 1; continue
            case ".": tokens.append(.dot); i += 1; continue
            default: break
            }
            if c == "\"" || c == "'" {
                var j = i + 1, out = ""
                while j < chars.count, chars[j] != c {
                    if chars[j] == "\\", j + 1 < chars.count { out.append(chars[j + 1]); j += 2; continue }
                    out.append(chars[j]); j += 1
                }
                guard j < chars.count else { throw Failure(message: "Unterminated text in: \(expression)") }
                tokens.append(.string(out)); i = j + 1; continue
            }
            // A minus starts a number only where a value is expected, so `a-1` is a subtraction.
            let expectsValue = tokens.last.map { if case .op = $0 { true } else { $0 == .open } } ?? true
            if c.isNumber || (c == "-" && expectsValue && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i + 1
                // After a dot this is a list index, so it stops at the next dot.
                let afterDot = tokens.last == .dot
                while j < chars.count, chars[j].isNumber || (!afterDot && chars[j] == ".") { j += 1 }
                let text = String(chars[i..<j])
                if afterDot { tokens.append(.name(text)) }
                else {
                    guard let value = Double(text) else { throw Failure(message: "Bad number \(text) in: \(expression)") }
                    tokens.append(.number(value))
                }
                i = j; continue
            }
            if i + 1 < chars.count, ["==", "!=", "<=", ">=", "&&", "||"].contains(String(chars[i...i + 1])) {
                tokens.append(.op(String(chars[i...i + 1]))); i += 2; continue
            }
            if "+-*/<>!".contains(c) { tokens.append(.op(String(c))); i += 1; continue }
            if c.isLetter || c == "_" {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let word = String(chars[i..<j])
                switch word {
                case "true": tokens.append(.bool(true))
                case "false": tokens.append(.bool(false))
                case "null": tokens.append(.null)
                default: tokens.append(.name(word))
                }
                i = j; continue
            }
            throw Failure(message: "Unexpected \"\(c)\" in: \(expression)")
        }
        return tokens
    }

    // MARK: - Parser

    private struct Parser {
        let tokens: [Token]
        let scopes: [String: Any]
        let source: String
        var index = 0
        /// Nesting so far: parentheses and ! or - in a row recurse, and the stack is not endless.
        var depth = 0

        init(tokens: [Token], scopes: [String: Any], source: String) {
            self.tokens = tokens
            self.scopes = scopes
            self.source = source
        }

        private func peekOp(_ ops: Set<String>) -> String? {
            guard index < tokens.count, case .op(let op) = tokens[index], ops.contains(op) else { return nil }
            return op
        }

        mutating func or() throws -> Any {
            var left = try and()
            while peekOp(["||"]) != nil {
                index += 1
                let right = try and()
                // As in JavaScript, the operand itself: `vars.n || 0` is a number.
                left = AgentExpression.truthy(left) ? left : right
            }
            return left
        }

        mutating func and() throws -> Any {
            var left = try compare()
            while peekOp(["&&"]) != nil {
                index += 1
                let right = try compare()
                left = AgentExpression.truthy(left) ? right : left
            }
            return left
        }

        mutating func compare() throws -> Any {
            var left = try add()
            while let op = peekOp(["==", "!=", "<", ">", "<=", ">="]) {
                index += 1
                let right = try add()
                switch op {
                case "==": left = AgentExpression.same(left, right)
                case "!=": left = !AgentExpression.same(left, right)
                case "<": left = number(left) < number(right)
                case ">": left = number(left) > number(right)
                case "<=": left = number(left) <= number(right)
                default: left = number(left) >= number(right)
                }
            }
            return left
        }

        mutating func add() throws -> Any {
            var left = try multiply()
            while let op = peekOp(["+", "-"]) {
                index += 1
                let right = try multiply()
                if op == "+", left is String || right is String {
                    left = AgentExpression.text(left) + AgentExpression.text(right)
                } else {
                    left = op == "+" ? number(left) + number(right) : number(left) - number(right)
                }
            }
            return left
        }

        mutating func multiply() throws -> Any {
            var left = try primary()
            while let op = peekOp(["*", "/"]) {
                index += 1
                let right = try primary()
                left = op == "*" ? number(left) * number(right) : number(left) / number(right)
            }
            return left
        }

        mutating func primary() throws -> Any {
            depth += 1
            defer { depth -= 1 }
            guard depth <= 64 else { throw Failure(message: "The expression nests too deep") }
            guard index < tokens.count else { throw Failure(message: "The expression ends early: \(source)") }
            let token = tokens[index]
            index += 1
            switch token {
            case .number(let value): return value
            case .string(let value): return value
            case .bool(let value): return value
            case .null: return NSNull()
            case .open:
                let value = try or()
                guard index < tokens.count, tokens[index] == .close else { throw Failure(message: "Missing ) in: \(source)") }
                index += 1
                return value
            case .op("!"): return !AgentExpression.truthy(try primary())
            case .op("-"): return -number(try primary())
            case .name(let first):
                var path = [first]
                while index < tokens.count, tokens[index] == .dot {
                    index += 1
                    guard index < tokens.count, case .name(let part) = tokens[index] else {
                        throw Failure(message: "Expected a name after . in: \(source)")
                    }
                    path.append(part)
                    index += 1
                }
                if let value = AgentExpression.lookup(path, in: scopes) { return value }
                // As in JavaScript, an object without the field reads null; an unknown name is a mistake.
                if path.count > 1, AgentExpression.lookup(Array(path.dropLast()), in: scopes) is [String: Any] { return NSNull() }
                throw Failure(message: "\(path.joined(separator: ".")) is not set")
            default:
                throw Failure(message: "Unexpected token in: \(source)")
            }
        }

        private func number(_ value: Any) -> Double {
            switch value {
            case let n as NSNumber: return n.doubleValue
            case let d as Double: return d
            case let i as Int: return Double(i)
            case let b as Bool: return b ? 1 : 0
            case let s as String: return s.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : Double(s) ?? .nan
            case is NSNull: return 0
            default: return .nan
            }
        }
    }

    // MARK: - Values

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// Strict equality, as `===`: a number never equals text. Lists and objects compare by value.
    static func same(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case (is NSNull, is NSNull): return true
        case (let x as String, let y as String): return x == y
        case (let x as Bool, let y as Bool): return x == y
        case (let x as NSNumber, let y as NSNumber):
            guard isBool(x) == isBool(y) else { return false }
            return x == y
        case (is String, _), (_, is String), (is NSNull, _), (_, is NSNull): return false
        default: return (a as AnyObject).isEqual(b)
        }
    }

    static func text(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case is NSNull: return "null"
        case let n as NSNumber:
            if isBool(n) { return n.boolValue ? "true" : "false" }
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        default:
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "\(value)" }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
