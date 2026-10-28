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
    static let appGroup = "group.com.ferry.test.shared"
    private static let folder = "IncomingShares"

    static func root() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(folder, isDirectory: true)
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
