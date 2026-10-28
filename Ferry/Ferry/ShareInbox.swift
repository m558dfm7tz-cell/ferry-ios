import Foundation
import UniformTypeIdentifiers

/// The share extension has no server credentials. It stores a copy of each
/// incoming item in the App Group; Ferry asks for a destination on next open.
struct FerrySharedEntry: Codable, Identifiable {
    enum Kind: String, Codable { case file, text }
    let id: String
    let kind: Kind
    let name: String
    let mediaType: String
    let filename: String?
    let text: String?
}

struct FerrySharedBatch: Codable, Identifiable {
    let id: String
    let createdAt: Date
    var entries: [FerrySharedEntry]
}

enum FerryShareInbox {
    // Personal-Team / Sideloadly compatible: iOS copies "Open In" documents
    // to this app's own Documents/Inbox. Do NOT request an App Group.
    private static let folder = "IncomingShares"

    private static var documents: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    static func root() -> URL? {
        documents?.appendingPathComponent(folder, isDirectory: true)
    }

    /// Copy a document delivered by iOS Open In / Copy to Ferry into a durable
    /// pending batch. Never upload or change the selected conversation here.
    @discardableResult
    static func importDocument(_ source: URL) throws -> Bool {
        guard source.isFileURL, source.hasDirectoryPath == false,
              let root = root() else { return false }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let folderURL = root.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        do {
            let original = source.lastPathComponent
            let fallbackName = original.isEmpty ? "分享文件" : original
            let ext = source.pathExtension
            let destFilename = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
            let mime = UTType(filenameExtension: ext)?.preferredMIMEType ??
                "application/octet-stream"
            try fm.copyItem(at: source, to: folderURL.appendingPathComponent(destFilename))
            let entry = FerrySharedEntry(id: UUID().uuidString, kind: .file,
                                         name: fallbackName, mediaType: mime,
                                         filename: destFilename, text: nil)
            let batch = FerrySharedBatch(id: id, createdAt: Date(), entries: [entry])
            let data = try JSONEncoder().encode(batch)
            try data.write(to: folderURL.appendingPathComponent("request.json"), options: .atomic)
            return true
        } catch {
            try? fm.removeItem(at: folderURL)
            throw error
        }
    }

    /// Legacy document handoff may populate Documents/Inbox without invoking
    /// onOpenURL. Import on app foreground; delete ONLY the local Inbox copy
    /// after a successful durable copy into the pending queue.
    static func collectSystemInbox() {
        guard let documents else { return }
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true)
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return }
        for url in children {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { continue }
            if (try? importDocument(url)) == true {
                try? fm.removeItem(at: url)
            }
        }
    }

    static func readPending() -> FerrySharedBatch? {
        guard let root = root(),
              let directories = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return nil
        }
        for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let manifest = directory.appendingPathComponent("request.json")
            guard let data = try? Data(contentsOf: manifest),
                  let batch = try? JSONDecoder().decode(FerrySharedBatch.self, from: data),
                  batch.id == directory.lastPathComponent,
                  !batch.entries.isEmpty else { continue }
            return batch
        }
        return nil
    }

    static func fileURL(batch: FerrySharedBatch, entry: FerrySharedEntry) -> URL? {
        guard let root = root(), entry.kind == .file, let file = entry.filename,
              (file as NSString).lastPathComponent == file,
              !file.contains(".."), !file.isEmpty else { return nil }
        let url = root.appendingPathComponent(batch.id, isDirectory: true)
            .appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func markQueued(_ entry: FerrySharedEntry, from batch: inout FerrySharedBatch) {
        batch.entries.removeAll(where: { $0.id == entry.id })
        guard let root = root() else { return }
        let directory = root.appendingPathComponent(batch.id, isDirectory: true)
        if let data = try? JSONEncoder().encode(batch) {
            try? data.write(to: directory.appendingPathComponent("request.json"), options: .atomic)
        }
    }

    static func remove(_ batch: FerrySharedBatch) {
        guard let root = root() else { return }
        try? FileManager.default.removeItem(
            at: root.appendingPathComponent(batch.id, isDirectory: true))
    }
}
