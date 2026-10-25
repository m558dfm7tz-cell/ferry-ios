import Foundation
import Observation

/// A favorited message: a full metadata snapshot plus (for media/files) the
/// leaf name of a local byte copy stored under Application Support/Favorites/.
/// Text favorites store no file (the text lives in `message.text`).
struct FavoriteMessage: Codable, Identifiable, Equatable {
    let message: MessagePayload
    let localFileName: String?

    var id: String { message.id }
}

/// Phone-local persistence for two purely-local features:
///   1. hidden messages ("delete" = hide on THIS device only),
///   2. favorites (metadata snapshot + local file bytes).
/// Nothing in this type ever talks to the server.
@MainActor @Observable
final class LocalDataStore {
    private let defaults: UserDefaults
    private(set) var hiddenIDs: Set<String>
    private(set) var clearedBeforeSequence: Int64?
    private(set) var favorites: [FavoriteMessage]

    static let favoritesFolderName = "Favorites"

    var favoritesFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(Self.favoritesFolderName, isDirectory: true)
    }

    private enum Keys {
        static let hiddenIDs = "ferry.local.hiddenIDs"
        static let clearedBefore = "ferry.local.clearedBeforeSequence"
        static let favorites = "ferry.local.favorites"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hiddenIDs = Set(defaults.stringArray(forKey: Keys.hiddenIDs) ?? [])
        if let number = defaults.object(forKey: Keys.clearedBefore) as? NSNumber {
            self.clearedBeforeSequence = number.int64Value
        } else {
            self.clearedBeforeSequence = nil
        }
        if let data = defaults.data(forKey: Keys.favorites),
           let decoded = try? JSONDecoder().decode([FavoriteMessage].self, from: data) {
            self.favorites = decoded
        } else {
            self.favorites = []
        }
    }

    // MARK: - Hidden messages

    func isHidden(_ message: MessagePayload) -> Bool {
        if hiddenIDs.contains(message.id) { return true }
        if let cleared = clearedBeforeSequence, message.sequence <= cleared { return true }
        return false
    }

    func hide(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        hiddenIDs.formUnion(ids)
        persistHidden()
    }

    /// "清空全部": hide every message whose sequence is <= the current maximum.
    /// Newly arriving messages (higher sequence) are still shown.
    func clearAll(upTo sequence: Int64) {
        clearedBeforeSequence = max(clearedBeforeSequence ?? 0, sequence)
        persistHidden()
    }

    private func persistHidden() {
        defaults.set(Array(hiddenIDs), forKey: Keys.hiddenIDs)
        if let cleared = clearedBeforeSequence {
            defaults.set(NSNumber(value: cleared), forKey: Keys.clearedBefore)
        } else {
            defaults.removeObject(forKey: Keys.clearedBefore)
        }
    }

    // MARK: - Favorites

    func isFavorite(_ id: String) -> Bool {
        favorites.contains { $0.id == id }
    }

    func favoriteFileURL(for fileName: String) -> URL {
        favoritesFolder.appendingPathComponent(fileName)
    }

    func addFavorite(_ message: MessagePayload, fileData: Data?) {
        guard !isFavorite(message.id) else { return }
        var localFileName: String?
        if let data = fileData, message.file != nil {
            localFileName = Self.writeToFavorites(data: data, message: message, folder: favoritesFolder)
        }
        favorites.append(FavoriteMessage(message: message, localFileName: localFileName))
        persistFavorites()
    }

    func removeFavorite(_ id: String) {
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        if let localFileName = favorites[index].localFileName {
            try? FileManager.default.removeItem(at: favoriteFileURL(for: localFileName))
        }
        favorites.remove(at: index)
        persistFavorites()
    }

    private func persistFavorites() {
        if let data = try? JSONEncoder().encode(favorites) {
            defaults.set(data, forKey: Keys.favorites)
        }
    }

    private static func writeToFavorites(data: Data, message: MessagePayload, folder: URL) -> String? {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let ext = fileExtension(message: message)
        let leaf = sanitizedID(message.id) + (ext.isEmpty ? "" : ".\(ext)")
        let url = folder.appendingPathComponent(leaf)
        do {
            try data.write(to: url, options: .atomic)
            return leaf
        } catch {
            return nil
        }
    }

    private static func sanitizedID(_ id: String) -> String {
        let result = id.map { char -> String in
            (char.isLetter || char.isNumber) ? String(char) : "_"
        }.joined()
        return result.isEmpty ? UUID().uuidString : result
    }

    private static func fileExtension(message: MessagePayload) -> String {
        guard let file = message.file else { return "" }
        let nameExt = (file.name as NSString).pathExtension.lowercased()
        if !nameExt.isEmpty { return nameExt }
        return mimeExtension(file.mediaType)
    }

    private static func mimeExtension(_ mime: String) -> String {
        switch mime {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/heic", "image/heif": return "heic"
        case "image/gif": return "gif"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "audio/mpeg": return "mp3"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/wav", "audio/x-wav": return "wav"
        case "application/pdf": return "pdf"
        case "text/plain": return "txt"
        default: return ""
        }
    }
}
