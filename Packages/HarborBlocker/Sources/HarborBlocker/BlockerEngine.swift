// Licensed under GPL-3.0. See LICENSE.
//
//  BlockerEngine.swift
//  Harbor
//
//  One adblock-rust Engine (MPL-2.0) for per-URL cosmetic lookup. Replaces
//  AdGuard's FilterEngine/WebExtension, which is GPL-3.0, and the second engine
//  RequestStatsEngine used to build from the same rules. It is built
//  cosmetic-only (cosmetic filters plus `$generichide`): WebKit does the network
//  blocking from the compiled rule lists, and the network filters were three
//  quarters of the engine's memory.
//
//  The engine pointer is Send but not Sync: it holds a RefCell regex cache.
//  It is therefore confined to the main actor, and only `build` steps off to
//  construct a fresh one, which is the same arrangement the AdGuard-era
//  WebExtension used. Lookups stay synchronous on purpose, because the
//  main-frame config script has to be installed before navigation commits.
//
//  Foundation only; nothing here is AppKit-specific.
//

import CryptoKit
import Foundation
import HarborAdblockFFI
import OSLog

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Harbor", category: "AdvancedRules")

@MainActor
public final class BlockerEngine {

    private var engine: UnsafeMutableRawPointer?

    public var isLoaded: Bool { engine != nil }

    /// Build or rebuild from the filter lists, replacing any previous engine.
    /// Per list rather than one blob: `ParseOptions.permissions` is applied at
    /// parse time and is what gates `trusted-*` scriptlets.
    /// Construction runs off the main actor; only the finished pointer crosses back.
    func build(sources: [FilterListManager.Source]) async {
        guard !sources.isEmpty else {
            clear()
            log.info("No filter rules; blocker engine cleared")
            return
        }
        let start = CFAbsoluteTimeGetCurrent()
        let resources = ScriptletResources.json()
        let (built, restored) = await Task.detached(priority: .userInitiated) { () -> (UnsafeMutableRawPointer?, Bool) in
            let key = Self.cacheKey(for: sources)
            var engine = Self.restore(matching: key)
            let restored = engine != nil
            if engine == nil {
                engine = Self.parse(sources, cosmeticOnly: true)
                if let engine { Self.save(engine, key: key) }
            }
            // Resources are not part of the saved bytes, so both paths install them.
            if let engine, var resources {
                let ok = resources.withUTF8 { buf in
                    harbor_adblock_engine_use_resources(
                        engine, UnsafeRawPointer(buf.baseAddress)?.assumingMemoryBound(to: CChar.self), buf.count)
                }
                if !ok { log.error("Scriptlet resource set rejected by the engine") }
            }
            return (engine, restored)
        }.value

        clear()
        engine = built
        guard built != nil else {
            log.error("Failed to build the blocker engine")
            return
        }
        let trusted = sources.filter(\.isTrusted).count
        log.info("Engine sources: \(sources.count, privacy: .public) list(s), \(trusted, privacy: .public) trusted, resources: \(resources != nil ? "yes" : "no", privacy: .public)")
        log.info("Blocker engine \(restored ? "restored" : "built", privacy: .public) in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start), privacy: .public)s")
    }

    nonisolated private static func parse(_ sources: [FilterListManager.Source], cosmeticOnly: Bool) -> UnsafeMutableRawPointer? {
        let payload = sources.map {
            ["rules": $0.rules, "trusted": $0.isTrusted, "cosmetic_only": cosmeticOnly] as [String: Any]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var text = String(data: data, encoding: .utf8) else {
            log.error("Could not encode filter lists for the engine")
            return nil
        }
        // Pass the byte count, not strlen: a NUL in one list would otherwise
        // cut off every list after it.
        return text.withUTF8 { buf in
            harbor_adblock_engine_from_lists(
                UnsafeRawPointer(buf.baseAddress)?.assumingMemoryBound(to: CChar.self), buf.count)
        }
    }

    // MARK: - Saved engine

    /// The parsed engine, saved so a launch with unchanged lists skips the parse (0.3 s).
    /// One file: a 32-byte key, then `Engine::serialize` bytes.
    nonisolated private static var cacheFile: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "Harbor")/ContentBlocker/Cache/engine.dat")
    }

    /// Everything the parse depends on: each list's text and trust, and the build, since a new
    /// build can carry a new parser. Bump the leading tag if the Rust side changes without one.
    nonisolated private static func cacheKey(for sources: [FilterListManager.Source]) -> Data {
        var hasher = SHA256()
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        hasher.update(data: Data("engine-v2 \(build)".utf8))
        for source in sources {
            // The length keeps two lists from hashing like one list split elsewhere.
            hasher.update(data: Data("\n\(source.isTrusted) \(source.rules.utf8.count)\n".utf8))
            var rules = source.rules
            rules.withUTF8 { hasher.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        }
        return Data(hasher.finalize())
    }

    nonisolated private static func restore(matching key: Data) -> UnsafeMutableRawPointer? {
        guard let saved = try? Data(contentsOf: cacheFile, options: .mappedIfSafe),
              saved.count > key.count, saved.prefix(key.count) == key else { return nil }
        // A file the Rust side cannot read comes back nil, and the caller parses.
        return saved.dropFirst(key.count).withUnsafeBytes { bytes in
            harbor_adblock_engine_deserialize(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
    }

    nonisolated private static func save(_ engine: UnsafeMutableRawPointer, key: Data) {
        var length = 0
        guard let bytes = harbor_adblock_engine_serialize(engine, &length) else { return }
        defer { harbor_adblock_buffer_free(bytes, length) }
        var file = key
        file.append(bytes, count: length)
        do {
            try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.write(to: cacheFile, options: .atomic)
        } catch {
            log.error("Could not save the engine: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clear() {
        if let engine { harbor_adblock_engine_free(engine) }
        engine = nil
    }

    /// Cosmetic configuration for a frame, or nil when nothing applies.
    ///
    /// `topUrl` is accepted for call-site compatibility and deliberately unused:
    /// adblock-rust keys cosmetic lookups on the frame's own URL, so a subframe
    /// gets its own rules rather than the top document's.
    ///
    /// Plain cosmetic filters do not come back here. They become
    /// `css-display-none` entries during conversion and are applied by WebKit
    /// from the compiled rule list. What returns is what the rule list cannot
    /// express, chiefly procedural filters.
    func configuration(for pageUrl: URL, topUrl: URL?) -> [String: Any]? {
        guard let engine else { return nil }
        let raw: String? = pageUrl.absoluteString.withCString { urlPtr in
            guard let p = harbor_adblock_cosmetic_for_url(engine, urlPtr) else { return nil }
            defer { harbor_adblock_string_free(p) }
            return String(cString: p)
        }
        guard let raw,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // `hide_selectors` is deliberately dropped. Every cosmetic filter with a
        // plain CSS selector already compiled into the WKContentRuleList as a
        // css-display-none entry, which WebKit applies natively and out of
        // process. Re-sending them here injected 21KB of JSON into every page on
        // every navigation (496 selectors on reuters.com), which fed the
        // renderer until jetsam killed the app.
        //
        // Known gap: a cosmetic filter the converter rejected for a reason other
        // than being procedural is in neither place. That is entity rules
        // (`google.*##.x`) and non-ASCII selectors. Small, and worth fixing by
        // teaching the converter those cases rather than by shipping 21KB a page.
        //
        // Each procedural entry is itself a JSON document, so it needs a second decode.
        let procedural = (object["procedural_actions"] as? [String] ?? []).compactMap { entry -> [String: Any]? in
            guard let d = entry.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }

        let scriptlets = object["injected_script"] as? String ?? ""
        if !scriptlets.isEmpty {
            log.info("Scriptlets for \(pageUrl.host ?? "?", privacy: .public): \(scriptlets.count, privacy: .public) bytes")
        }

        if procedural.isEmpty && scriptlets.isEmpty { return nil }
        var config: [String: Any] = [:]
        if !procedural.isEmpty { config["extendedCss"] = procedural }
        if !scriptlets.isEmpty { config["scriptlets"] = scriptlets }
        return config
    }

    /// Whether each request would be blocked. Used by the dev MCP `check_urls`
    /// tool; nothing in the browsing path calls this, because WebKit does the
    /// blocking itself from the compiled rule lists. The live engine has no
    /// network filters, so this parses a full engine for the call and frees it.
    nonisolated static func matches(
        urls: [String], sourceURL: String, type: String, sources: [FilterListManager.Source]
    ) -> [String: Bool] {
        guard let engine = parse(sources, cosmeticOnly: false) else { return [:] }
        defer { harbor_adblock_engine_free(engine) }
        var out: [String: Bool] = [:]
        for url in urls {
            out[url] = url.withCString { u in
                sourceURL.withCString { s in
                    type.withCString { t in
                        harbor_adblock_engine_matches(engine, u, s, t)
                    }
                }
            }
        }
        return out
    }
}
