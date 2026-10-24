// Licensed under GPL-3.0. See LICENSE.
//
//  AgentUploads.swift
//  Harbor
//
//  Files an agent hands a page. A path is relative to the Browser Control folder or any file the
//  person has outside the places `AgentUploadPaths` refuses. Each is copied into Harbor's own
//  folder off the main thread before the page gets it: handing WebKit a file in Downloads,
//  Documents or Desktop makes it ask macOS for access on the main thread, which waits on the
//  privacy prompt, and a copy made elsewhere can wait there instead, within a deadline.
//

import Foundation
import UniformTypeIdentifiers

enum AgentUploads {
    /// Copies kept for pages still reading them, removed after a day.
    nonisolated static let folder = AgentHub.directory.appendingPathComponent("Uploads", isDirectory: true)
    /// A drop hands the page the bytes through script, so it stays small.
    static let maxDropBytes = 25 << 20

    /// The file `path` names, or why it may not be uploaded.
    static func source(_ path: String) throws -> URL {
        if !path.hasPrefix("/"), !path.hasPrefix("~") {
            guard let url = DevMCPFiles.resolve(path) else {
                throw AgentError.invalid("\(path) climbs out of \(DevMCPFiles.root.path); give an absolute path instead")
            }
            return url
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        if let why = AgentUploadPaths.refusal(url.path, home: NSHomeDirectory()) {
            throw AgentError.invalid("Harbor does not upload \(path): \(why)")
        }
        return url
    }

    /// Copies of `sources` in Harbor's folder, in order.
    @MainActor
    static func stage(_ sources: [URL]) async throws -> [URL] {
        do {
            return try await AgentDeadline.throwing(20) {
                try await Task.detached(priority: .userInitiated) { try copy(sources) }.value
            }
        } catch is AgentDeadline.Expired {
            throw AgentError.invalid("Reading the files took too long; macOS may be asking whether Harbor can open that folder. Answer the prompt and try again.")
        }
    }

    private nonisolated static func copy(_ sources: [URL]) throws -> [URL] {
        let fm = FileManager.default
        prune()
        let batch = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return try sources.enumerated().map { index, source in
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw AgentError.invalid("\(source.path) is not a file")
            }
            // One folder per file keeps two files of the same name apart.
            let into = batch.appendingPathComponent(String(index), isDirectory: true)
            try fm.createDirectory(at: into, withIntermediateDirectories: true)
            let copy = into.appendingPathComponent(source.lastPathComponent)
            try fm.copyItem(at: source, to: copy)
            return copy
        }
    }

    private nonisolated static func prune() {
        let fm = FileManager.default
        let old = Date().addingTimeInterval(-86_400)
        let batches = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for batch in batches where ((try? batch.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) < old {
            try? fm.removeItem(at: batch)
        }
    }

    /// The staged files as the page's drop script takes them: name, type and base64 bytes.
    @MainActor
    static func dropPayload(_ staged: [URL]) async throws -> [[String: String]] {
        try await Task.detached(priority: .userInitiated) {
            let sizes = staged.map { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
            guard sizes.reduce(0, +) <= maxDropBytes else {
                throw AgentError.invalid("A drop takes at most \(maxDropBytes >> 20) MB; use the page's file input for larger files")
            }
            return try staged.map { url in
                ["name": url.lastPathComponent, "type": mimeType(url.pathExtension),
                 "data": try Data(contentsOf: url).base64EncodedString()]
            }
        }.value
    }

    private nonisolated static func mimeType(_ ext: String) -> String {
        UTType(filenameExtension: ext)?.preferredMIMEType ?? ""
    }
}
