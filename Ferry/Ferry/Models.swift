import Foundation

struct Device: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let createdAt: String

    enum CodingKeys: String, CodingKey { case id, name, createdAt = "created_at" }
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

struct AccessClaim: Decodable, Sendable { let device: Device; let token: String }
struct SessionPayload: Decodable, Sendable { let device: Device }
struct AccessStatusPayload: Decodable, Sendable {
    let passwordRequired: Bool
    enum CodingKeys: String, CodingKey { case passwordRequired = "password_required" }
}
struct MessagesPage: Decodable, Sendable {
    let messages: [MessagePayload]
    let nextCursor: Int64
    enum CodingKeys: String, CodingKey { case messages; case nextCursor = "next_cursor" }
}

struct APIErrorEnvelope: Decodable, Sendable {
    struct Detail: Decodable, Sendable { let code: String; let message: String }
    let error: Detail
}
