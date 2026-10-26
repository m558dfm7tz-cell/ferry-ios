import CryptoKit
import Foundation

struct Device: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let kind: String
    let createdAt: String

    enum CodingKeys: String, CodingKey { case id, name, kind, createdAt = "created_at" }

    init(id: String, name: String, kind: String, createdAt: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "unknown"
        createdAt = try container.decode(String.self, forKey: .createdAt)
    }
}

struct FileInfo: Codable, Equatable, Sendable {
    let name: String
    let mediaType: String
    let size: Int64
    let downloadURL: String

    enum CodingKeys: String, CodingKey {
        case name, size
        case mediaType = "media_type"
        case downloadURL = "download_url"
    }
}

struct MessagePayload: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case text, file }

    let id: String
    let sequence: Int64
    let kind: Kind
    let senderName: String
    let senderKind: String
    let isCurrentDevice: Bool
    let createdAt: String
    let text: String?
    let file: FileInfo?

    enum CodingKeys: String, CodingKey {
        case id, sequence, kind, text, file
        case senderName = "sender_name"
        case senderKind = "sender_kind"
        case isCurrentDevice = "is_current_device"
        case createdAt = "created_at"
    }

    /// `created_at` is canonical UTC RFC 3339 from the Go server (with or
    /// without fractional seconds, since Go's RFC3339Nano trims trailing
    /// zeros); render it as a local short time for the timeline.
    var timeText: String {
        guard let date = TimestampFormat.date(from: createdAt) else { return "" }
        return TimestampFormat.time.string(from: date)
    }
}

enum TimestampFormat {
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let withoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func date(from string: String) -> Date? {
        withFraction.date(from: string) ?? withoutFraction.date(from: string)
    }

    /// WeChat-style day label for the centered date separator.
    static func dayLabel(from string: String) -> String {
        guard let date = date(from: string) else { return "" }
        if Calendar.current.isDateInToday(date) { return "今天" }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }
}

/// A contiguous run of messages sharing one calendar day, rendered under a
/// single centered date separator.
struct DaySection: Identifiable {
    let dayLabel: String
    let messages: [MessagePayload]
    var id: String { messages.first?.id ?? dayLabel }
}

extension MessagePayload {
    /// SF Symbol for the sender's device kind.
    var deviceIcon: String {
        switch senderKind {
        case "iphone", "android": return "iphone"
        case "ipad": return "ipad"
        case "mac": return "laptopcomputer"
        case "windows": return "desktopcomputer"
        default: return "globe"
        }
    }

    /// The device's display name, with the web client's " Web"/"网站" suffix
    /// stripped so the literal "Web" is never shown.
    var displayDeviceName: String {
        let name = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = name.range(of: #"\s+(网站|Web)$"#, options: [.regularExpression, .caseInsensitive]) {
            let stripped = String(name[..<range.lowerBound])
            return stripped.isEmpty ? Self.fallbackName(for: senderKind) : stripped
        }
        if name.isEmpty { return Self.fallbackName(for: senderKind) }
        return name
    }

    static func fallbackName(for kind: String) -> String {
        switch kind {
        case "iphone": return "iPhone"
        case "ipad": return "iPad"
        case "android": return "Android"
        case "mac": return "Mac"
        case "windows": return "Windows"
        default: return "浏览器"
        }
    }
}

extension Device {
    /// SF Symbol for the device kind as shown in the device-management list.
    var iconName: String {
        switch kind {
        case "iphone": return "iphone"
        case "ipad": return "ipad"
        case "mac": return "laptopcomputer"
        case "android": return "candybarphone"
        case "windows": return "pc"
        case "browser": return "globe"
        default: return "questionmark.circle"
        }
    }

    /// Client-side heuristic only: the server has no "assistant" device kind,
    /// so a device is shown with an 助手 badge when its name hints at it.
    var isHelper: Bool {
        name.localizedCaseInsensitiveContains("助手")
            || name.localizedCaseInsensitiveContains("Helper")
            || name.localizedCaseInsensitiveContains("AI")
    }

    /// 加入于 … — the server exposes only `created_at`, not a last-active time.
    var joinedText: String {
        guard let date = TimestampFormat.date(from: createdAt) else { return "时间未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

struct AccessClaim: Decodable, Sendable { let device: Device; let token: String }
struct DevicesPayload: Decodable, Sendable { let devices: [Device] }
struct SessionPayload: Decodable, Sendable { let device: Device }
struct AccessStatusPayload: Decodable, Sendable {
    let passwordRequired: Bool
    enum CodingKeys: String, CodingKey { case passwordRequired = "password_required" }
}
struct MessagesPage: Decodable, Sendable {
    let messages: [MessagePayload]
    let nextCursor: Int64
    let hasOlder: Bool
    let revision: Int64

    enum CodingKeys: String, CodingKey {
        case messages, revision
        case nextCursor = "next_cursor"
        case hasOlder = "has_older"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = try container.decode([MessagePayload].self, forKey: .messages)
        nextCursor = try container.decodeIfPresent(Int64.self, forKey: .nextCursor) ?? 0
        hasOlder = try container.decodeIfPresent(Bool.self, forKey: .hasOlder) ?? false
        revision = try container.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
    }
}

/// Response of `POST /api/v1/files/{id}/download-link` (status 201).
struct DownloadLinkPayload: Decodable, Sendable {
    let url: String
    let expiresInSeconds: Int

    enum CodingKeys: String, CodingKey {
        case url
        case expiresInSeconds = "expires_in_seconds"
    }
}

/// Stable local-calendar day key ("yyyy-MM-dd") used for the date-jump index.
/// Built from a local `startOfDay` date so it matches the timeline's WeChat
/// day separators, which also render in the device's local time zone.
enum DayKey {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}

struct APIErrorEnvelope: Decodable, Sendable {
    struct Detail: Decodable, Sendable { let code: String; let message: String }
    let error: Detail
}

/// Identifies one Ferry "space": a server address plus, when the server enforces
/// an access password, a SHA-256 hash of that password. The password itself is
/// never stored or logged. Keying phone-local caches (favorites, custom
/// assistants, avatars, thumbnails) by this value keeps different servers — and
/// different passwords on one server — from leaking into each other.
struct SpaceKey: Hashable, Sendable {
    /// Stable value used as a UserDefaults key suffix.
    let value: String

    /// Reconstruct a previously persisted space (its `value` is stable).
    init(value: String) {
        self.value = value
    }

    init(origin: String, password: String) {
        let normalized = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        if password.isEmpty {
            value = normalized
        } else {
            let digest = SHA256.hash(data: Data(password.utf8))
            let hex = digest.map { String(format: "%02x", Int($0)) }.joined()
            value = normalized + "#" + hex
        }
    }

    /// Filesystem-safe folder name: the origin may contain `://` and the value
    /// may be long, so it is hashed again into a fixed hex string.
    var folderName: String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", Int($0)) }.joined()
    }
}

// MARK: - Multi-device sync (server-authoritative) payloads

/// One deletion event from `GET /api/v1/changes`. `kind` is "message" or
/// "favorite"; `itemID` is the 32-hex message id, or "*" for a clear-all.
struct Change: Decodable, Sendable {
    let seq: Int64
    let kind: String
    let itemID: String
    enum CodingKeys: String, CodingKey { case seq, kind, itemID = "item_id" }
}

struct ChangesPage: Decodable, Sendable {
    let changes: [Change]
    let revision: Int64
}

/// One custom assistant in the shared assistant bar (`assistant-state.custom`).
struct ServerCustomAssistant: Codable, Sendable {
    let name: String
    let avatarText: String?
    let colorIndex: Int?
    enum CodingKeys: String, CodingKey { case name, avatarText, colorIndex }
}

/// `GET/PUT /api/v1/assistant-state`: the server-authoritative assistant bar
/// (selected filter, per-assistant read cursors, custom assistant list).
struct AssistantStatePayload: Codable, Sendable {
    let selected: String?
    let reads: [String: Int64]
    let custom: [ServerCustomAssistant]
}

/// `{"deleted": N}` returned by the message/favorite delete endpoints.
struct DeletedCount: Decodable, Sendable {
    let deleted: Int
}

/// One shared favorite from `GET /api/v1/favorites` (a metadata snapshot; the
/// server marks `missing` when the underlying message was deleted).
struct ServerFavorite: Decodable, Sendable {
    let id: String
    let kind: String
    let fileKind: String
    let fileName: String
    let text: String
    let sender: String
    let senderKind: String
    let createdAt: String
    let favoritedAt: Int64
    let missing: Bool
}

struct FavoritesPayload: Decodable, Sendable {
    let favorites: [ServerFavorite]
}

/// Body of `PUT /api/v1/favorites/{id}` (a favorite snapshot to star on).
struct FavoriteRecord: Encodable, Sendable {
    let id: String
    let kind: String
    let fileKind: String
    let fileName: String
    let text: String
    let sender: String
    let senderKind: String
    let createdAt: String
    let favoritedAt: Int64
}

struct PutFavoriteResponse: Decodable, Sendable {
    let applied: Bool
    let favorite: ServerFavorite
}

/// One deletion made on this phone that still needs to reach the server.
/// Persisted per space and flushed in order when the phone is back online.
struct PendingDeletion: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case messages, clearAll, favorite, assistant }
    let id: UUID
    let kind: Kind
    /// For `.messages` (ids to delete) and `.favorite` (one message id).
    let ids: [String]
    /// For `.assistant`: the assistant name to remove.
    let name: String

    init(id: UUID = UUID(), kind: Kind, ids: [String] = [], name: String = "") {
        self.id = id
        self.kind = kind
        self.ids = ids
        self.name = name
    }
}
