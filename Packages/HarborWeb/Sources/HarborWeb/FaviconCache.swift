// Licensed under GPL-3.0. See LICENSE.
//
//  FaviconCache.swift
//  Harbor
//
//  Global favicon cache, shared across profiles by design to raise the hit rate and avoid
//  duplicate downloads. Memory LRU of 200 entries plus a disk cache at
//  ~/Library/Caches/FaviconCache/{host}.png that survives relaunch. Disk I/O runs on a
//  background queue.
//

import Foundation
import SwiftUI
import FaviconFinder

public final class FaviconCache: @unchecked Sendable {
    public static let shared = FaviconCache()

    public static let maxMemoryEntries = 200

    private struct Entry {
        let nsImage: PlatformImage
        let image: SwiftUI.Image
    }

    private var memory: [String: Entry] = [:]
    /// Insertion order for LRU eviction.
    private var order: [String] = []
    private let lock = NSLock()
    /// Hosts being fetched without a page, so a long tab list asks once per host.
    private var fetching: [String: Task<PlatformImage?, Never>] = [:]
    /// When a host's last page-less fetch failed; it is not asked again for ten minutes.
    private var failedAt: [String: Date] = [:]
    private let queue = DispatchQueue(label: "favicon.cache", attributes: .concurrent)

    public let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("FaviconCache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {}

    // MARK: - Lookup

    /// Memory cache only, synchronous.
    public func image(for key: String) -> PlatformImage? {
        lock.withLock { memory[key]?.nsImage }
    }

    /// Memory cache only, as a SwiftUI image.
    public func swiftUIImage(for key: String) -> SwiftUI.Image? {
        lock.withLock { memory[key]?.image }
    }

    /// Memory first, then disk off the main thread. A disk hit is promoted to memory.
    public func cachedImage(for key: String) async -> PlatformImage? {
        if let hit = image(for: key) { return hit }
        return await withCheckedContinuation { continuation in
            queue.async {
                let image = self.readFromDisk(key)
                if let image { self.insert(Entry(nsImage: image, image: SwiftUI.Image(platformImage: image)), for: key) }
                continuation.resume(returning: image)
            }
        }
    }

    /// Synchronous disk read with promotion to memory. For startup restore of a few visible rows.
    public func imageFromDiskSync(for key: String) -> PlatformImage? {
        guard let image = readFromDisk(key) else { return nil }
        insert(Entry(nsImage: image, image: SwiftUI.Image(platformImage: image)), for: key)
        return image
    }

    /// How long a stored favicon is trusted before a visit fetches it again.
    public static let maxAge: TimeInterval = 24 * 60 * 60

    /// True when the disk copy is older than `maxAge`. Memory-only entries (private pages) are never stale.
    public func isStale(_ key: String) async -> Bool {
        let url = fileURL(key)
        return await withCheckedContinuation { continuation in
            queue.async {
                let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                continuation.resume(returning: modified.map { -$0.timeIntervalSinceNow > Self.maxAge } ?? false)
            }
        }
    }

    /// The cached icon for `host`, else one fetched now from the site itself, with no page open:
    /// a tab that has never been opened (a restored or imported one) still shows its site's icon.
    /// A failure is remembered for ten minutes, and `localhost` and bare IP hosts are skipped.
    public func loadOrFetch(host: String) async -> PlatformImage? {
        if let hit = await cachedImage(for: host) { return hit }
        guard host.contains("."), !host.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        if let failed = lock.withLock({ failedAt[host] }), -failed.timeIntervalSinceNow < 600 { return nil }
        let task: Task<PlatformImage?, Never> = lock.withLock {
            if let running = fetching[host] { return running }
            let started = Task<PlatformImage?, Never> { await Self.download(host: host) }
            fetching[host] = started
            return started
        }
        let image = await task.value
        lock.withLock {
            fetching[host] = nil
            if image == nil { failedAt[host] = Date() }
        }
        if let image { store(image, for: host) }
        return image
    }

    /// The page's own icon through its <link> tags, else `/favicon.ico`.
    private static func download(host: String) async -> PlatformImage? {
        guard let root = URL(string: "https://\(host)/") else { return nil }
        if let favicon = try? await FaviconFinder(url: root).fetchFaviconURLs().download().largest(),
           let image = favicon.image?.image {
            return image
        }
        guard let icon = URL(string: "/favicon.ico", relativeTo: root)?.absoluteURL,
              let (data, response) = try? await URLSession.shared.data(from: icon),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return PlatformImage(data: data)
    }

    // MARK: - Store

    /// Stores in memory and writes a PNG to disk.
    public func store(_ image: PlatformImage, for key: String) {
        store(image, for: key, toDisk: true)
    }

    func store(_ image: PlatformImage, for key: String, toDisk: Bool) {
        insert(Entry(nsImage: image, image: SwiftUI.Image(platformImage: image)), for: key)
        guard toDisk else { return }
        // PNG encoding is CPU work, not I/O; do it on the caller.
        guard let png = image.pngData() else { return }
        let url = fileURL(key)
        queue.async(flags: .barrier) {
            try? png.write(to: url)
        }
    }

    // MARK: - Maintenance

    public func clear() {
        lock.withLock {
            memory.removeAll()
            order.removeAll()
        }
        let dir = directory
        queue.async(flags: .barrier) {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Entry counts in memory and on disk.
    public func stats() -> (memory: Int, disk: Int) {
        let memoryCount = lock.withLock { memory.count }
        let diskCount = (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0
        return (memoryCount, diskCount)
    }

    /// Keys currently in memory.
    public var memoryKeys: [String] {
        lock.withLock { Array(memory.keys) }
    }

    // MARK: - Private

    private func insert(_ entry: Entry, for key: String) {
        var evicted: [String] = []
        lock.withLock {
            memory[key] = entry
            order.removeAll { $0 == key }
            order.append(key)
            if memory.count > Self.maxMemoryEntries {
                let count = memory.count - Self.maxMemoryEntries + 20
                evicted = Array(order.prefix(count))
                for old in evicted { memory.removeValue(forKey: old) }
                order.removeFirst(min(count, order.count))
            }
        }
        guard !evicted.isEmpty else { return }
        let urls = evicted.map(fileURL)
        queue.async(flags: .barrier) {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func fileURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).png")
    }

    private func readFromDisk(_ key: String) -> PlatformImage? {
        guard let data = try? Data(contentsOf: fileURL(key)) else { return nil }
        return PlatformImage(data: data)
    }
}
