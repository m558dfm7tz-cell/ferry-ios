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
    let createdAt: String
    let text: String?
    let file: FileInfo?

    enum CodingKeys: String, CodingKey {
        case id, sequence, kind, text, file
        case senderName = "sender_name"
        case createdAt = "created_at"
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
