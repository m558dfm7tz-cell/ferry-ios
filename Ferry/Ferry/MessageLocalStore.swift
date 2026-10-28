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
    /// The space this store is currently pointed at; nil until `activate` runs.
    private(set) var spaceKey: SpaceKey?
    private(set) var hiddenIDs: Set<String>
    private(set) var clearedBeforeSequence: Int64?
    private(set) var favorites: [FavoriteMessage]

    static let favoritesFolderName = "Favorites"

    /// Favorites live under `Application Support/Ferry/Spaces/<space>/Favorites`
    /// once a space is active, so different servers never share favorite files.
    var favoritesFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        if let spaceKey {
            return base.appendingPathComponent("Ferry", isDirectory: true)
                .appendingPathComponent("Spaces", isDirectory: true)
                .appendingPathComponent(spaceKey.folderName, isDirectory: true)
                .appendingPathComponent(Self.favoritesFolderName, isDirectory: true)
        }
        return base.appendingPathComponent(Self.favoritesFolderName, isDirectory: true)
    }

    /// Pre-space (unscoped) keys: migrated into the first space ever activated.
    private enum LegacyKeys {
        static let hiddenIDs = "ferry.local.hiddenIDs"
        static let clearedBefore = "ferry.local.clearedBeforeSequence"
        static let favorites = "ferry.local.favorites"
    }

    private var hiddenKey: String { "ferry.local.hiddenIDs." + (spaceKey?.value ?? "") }
    private var clearedKey: String { "ferry.local.clearedBeforeSequence." + (spaceKey?.value ?? "") }
    private var favoritesKey: String { "ferry.local.favorites." + (spaceKey?.value ?? "") }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hiddenIDs = []
        self.clearedBeforeSequence = nil
        self.favorites = []
    }

    /// Point the store at one Ferry space and load its persisted state. The
    /// first space ever activated absorbs any legacy (unscoped) data, so an
    /// upgrade from the pre-space build never loses favorites or hidden ids.
    func activate(space: SpaceKey) {
        guard space != spaceKey else { return }
        spaceKey = space
        if Self.hasLegacy(defaults: defaults) {
            migrateLegacy()
        }
        load()
    }

    private func load() {
        hiddenIDs = Set(defaults.stringArray(forKey: hiddenKey) ?? [])
        if let number = defaults.object(forKey: clearedKey) as? NSNumber {
            clearedBeforeSequence = number.int64Value
        } else {
            clearedBeforeSequence = nil
        }
        if let data = defaults.data(forKey: favoritesKey),
           let decoded = try? JSONDecoder().decode([FavoriteMessage].self, from: data) {
            favorites = decoded
        } else {
            favorites = []
        }
    }

    private static func hasLegacy(defaults: UserDefaults) -> Bool {
        defaults.stringArray(forKey: LegacyKeys.hiddenIDs) != nil
            || defaults.object(forKey: LegacyKeys.clearedBefore) != nil
            || defaults.data(forKey: LegacyKeys.favorites) != nil
    }

    /// Move legacy unscoped data (UserDefaults values + favorite files) into the
    /// current space, then clear the legacy keys.
    private func migrateLegacy() {
        let legacyFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Self.favoritesFolderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: legacyFolder.path) {
            try? FileManager.default.createDirectory(at: favoritesFolder, withIntermediateDirectories: true)
            if let items = try? FileManager.default.contentsOfDirectory(atPath: legacyFolder.path) {
                for item in items {
                    let source = legacyFolder.appendingPathComponent(item)
                    let destination = favoritesFolder.appendingPathComponent(item)
                    try? FileManager.default.moveItem(at: source, to: destination)
                }
            }
            try? FileManager.default.removeItem(at: legacyFolder)
        }
        if let array = defaults.stringArray(forKey: LegacyKeys.hiddenIDs) {
            defaults.set(array, forKey: hiddenKey)
            defaults.removeObject(forKey: LegacyKeys.hiddenIDs)
        }
        if let number = defaults.object(forKey: LegacyKeys.clearedBefore) as? NSNumber {
            defaults.set(number, forKey: clearedKey)
            defaults.removeObject(forKey: LegacyKeys.clearedBefore)
        }
        if let data = defaults.data(forKey: LegacyKeys.favorites) {
            defaults.set(data, forKey: favoritesKey)
            defaults.removeObject(forKey: LegacyKeys.favorites)
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
        defaults.set(Array(hiddenIDs), forKey: hiddenKey)
        if let cleared = clearedBeforeSequence {
            defaults.set(NSNumber(value: cleared), forKey: clearedKey)
        } else {
            defaults.removeObject(forKey: clearedKey)
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

    /// Local offline copy may finish downloading after its favorite was already
    /// added/sent. Attach the bytes without changing the favorite or its ID.
    func attachFavoriteFile(_ id: String, data: Data) {
        guard let index = favorites.firstIndex(where: { $0.id == id }),
              favorites[index].localFileName == nil,
              favorites[index].message.file != nil else { return }
        let message = favorites[index].message
        guard let filename = Self.writeToFavorites(data: data, message: message,
                                                   folder: favoritesFolder) else { return }
        favorites[index] = FavoriteMessage(message: message, localFileName: filename)
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
            defaults.set(data, forKey: favoritesKey)
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
