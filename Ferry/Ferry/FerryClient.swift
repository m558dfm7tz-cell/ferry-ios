import Foundation
import UIKit

protocol FerryServicing {
    func accessStatus(endpoint: ServerEndpoint) async throws -> Bool
    func join(endpoint: ServerEndpoint, password: String, name: String) async throws -> AccessClaim
    func currentDevice(endpoint: ServerEndpoint, token: String) async throws -> Device
    func messages(endpoint: ServerEndpoint, token: String, after: Int64) async throws -> MessagesPage
    func messagesLatest(endpoint: ServerEndpoint, token: String, limit: Int) async throws -> MessagesPage
    func messagesBefore(endpoint: ServerEndpoint, token: String, before: Int64, limit: Int) async throws -> MessagesPage
    func sendText(endpoint: ServerEndpoint, token: String, text: String) async throws -> MessagePayload
    func sendText(endpoint: ServerEndpoint, token: String, text: String,
                  destination: MessageDestination) async throws -> MessagePayload
    func attachment(endpoint: ServerEndpoint, token: String, path: String) async throws -> Data
    func attachmentFile(endpoint: ServerEndpoint, token: String, path: String, filename: String?) async throws -> URL
    func downloadLink(endpoint: ServerEndpoint, token: String, messageID: String) async throws -> DownloadLinkPayload
    func changes(endpoint: ServerEndpoint, token: String, since: Int64) async throws -> ChangesPage
    func assistantState(endpoint: ServerEndpoint, token: String) async throws -> AssistantStatePayload
    func putAssistantState(endpoint: ServerEndpoint, token: String, state: AssistantStatePayload) async throws -> AssistantStatePayload
    func favorites(endpoint: ServerEndpoint, token: String) async throws -> FavoritesPayload
    func putFavorite(endpoint: ServerEndpoint, token: String, messageID: String, record: FavoriteRecord) async throws -> PutFavoriteResponse
    func deleteMessages(endpoint: ServerEndpoint, token: String, ids: [String]) async throws -> DeletedCount
    func deleteAllMessages(endpoint: ServerEndpoint, token: String) async throws -> DeletedCount
    func deleteFavorite(endpoint: ServerEndpoint, token: String, messageID: String, opAt: Int64) async throws -> DeletedCount
}

// Test mocks and legacy adapters may implement only the original API.
// Routing is never silently dropped when an unsupported adapter is used.
extension FerryServicing {
    func sendText(endpoint: ServerEndpoint, token: String, text: String,
                  destination: MessageDestination) async throws -> MessagePayload {
        throw URLError(.unsupportedURL)
    }
}

struct FerryClient: FerryServicing {
    enum ClientError: LocalizedError, Equatable {
        case unauthorized
        case rejected(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .unauthorized: "当前设备已断开连接。"
            case .rejected(let message): message
            case .invalidResponse: "Ferry 服务器返回了无效响应。"
            }
        }
    }

    let session: URLSession
    let transferSession: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        // Transfers get generous timeouts; JSON API calls keep the defaults.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 24 * 3600
        self.transferSession = URLSession(configuration: config)
    }

    func accessStatus(endpoint: ServerEndpoint) async throws -> Bool {
        let payload: AccessStatusPayload = try await json(endpoint: endpoint, path: "/api/v1/access", token: nil)
        return payload.passwordRequired
    }

    func join(endpoint: ServerEndpoint, password: String, name: String) async throws -> AccessClaim {
        try await json(endpoint: endpoint, path: "/api/v1/access/join", method: "POST", token: nil,
                       body: try JSONSerialization.data(withJSONObject: ["password": password, "device_name": name]),
                       deviceKind: nativeDeviceKind)
    }

    func currentDevice(endpoint: ServerEndpoint, token: String) async throws -> Device {
        let payload: SessionPayload = try await json(endpoint: endpoint, path: "/api/v1/session", token: token)
        return payload.device
    }

    func messages(endpoint: ServerEndpoint, token: String, after: Int64) async throws -> MessagesPage {
        try await json(endpoint: endpoint, path: "/api/v1/messages", token: token,
                       query: [URLQueryItem(name: "after", value: String(after)), URLQueryItem(name: "limit", value: "200")])
    }

    func messagesLatest(endpoint: ServerEndpoint, token: String, limit: Int) async throws -> MessagesPage {
        try await json(endpoint: endpoint, path: "/api/v1/messages", token: token,
                       query: [URLQueryItem(name: "latest", value: "1"), URLQueryItem(name: "limit", value: String(limit))])
    }

    func messagesBefore(endpoint: ServerEndpoint, token: String, before: Int64, limit: Int) async throws -> MessagesPage {
        try await json(endpoint: endpoint, path: "/api/v1/messages", token: token,
                       query: [URLQueryItem(name: "before", value: String(before)), URLQueryItem(name: "limit", value: String(limit))])
    }

    func sendText(endpoint: ServerEndpoint, token: String, text: String) async throws -> MessagePayload {
        try await json(endpoint: endpoint, path: "/api/v1/messages/text", method: "POST", token: token,
                       body: try JSONSerialization.data(withJSONObject: ["text": text]))
    }

    func sendText(endpoint: ServerEndpoint, token: String, text: String,
                  destination: MessageDestination) async throws -> MessagePayload {
        var body = destination.fields
        body["text"] = text
        return try await json(endpoint: endpoint, path: "/api/v1/messages/text",
                              method: "POST", token: token,
                              body: try JSONSerialization.data(withJSONObject: body))
    }

    /// `POST /api/v1/files/{id}/download-link`: returns a short-lived (≈90 s)
    /// unauthenticated download URL. The empty body is accepted by the server.
    func downloadLink(endpoint: ServerEndpoint, token: String, messageID: String) async throws -> DownloadLinkPayload {
        try await json(endpoint: endpoint, path: "/api/v1/files/\(messageID)/download-link",
                       method: "POST", token: token, body: nil)
    }

    /// Deletion change log (`GET /api/v1/changes`): recent message/favorite
    /// removals from other devices, ordered ascending by sequence.
    func changes(endpoint: ServerEndpoint, token: String, since: Int64) async throws -> ChangesPage {
        try await json(endpoint: endpoint, path: "/api/v1/changes", token: token,
                       query: [URLQueryItem(name: "since", value: String(since))])
    }

    /// Server-authoritative assistant bar state (custom assistants list).
    func assistantState(endpoint: ServerEndpoint, token: String) async throws -> AssistantStatePayload {
        try await json(endpoint: endpoint, path: "/api/v1/assistant-state", token: token)
    }

    func putAssistantState(endpoint: ServerEndpoint, token: String, state: AssistantStatePayload) async throws -> AssistantStatePayload {
        try await json(endpoint: endpoint, path: "/api/v1/assistant-state", method: "PUT", token: token,
                       body: try JSONEncoder().encode(state))
    }

    /// Shared favorites list (`GET /api/v1/favorites`).
    func favorites(endpoint: ServerEndpoint, token: String) async throws -> FavoritesPayload {
        try await json(endpoint: endpoint, path: "/api/v1/favorites", token: token)
    }

    func putFavorite(endpoint: ServerEndpoint, token: String, messageID: String, record: FavoriteRecord) async throws -> PutFavoriteResponse {
        try await json(endpoint: endpoint, path: "/api/v1/favorites/\(messageID)", method: "PUT", token: token,
                       body: try JSONEncoder().encode(record))
    }

    func deleteMessages(endpoint: ServerEndpoint, token: String, ids: [String]) async throws -> DeletedCount {
        try await json(endpoint: endpoint, path: "/api/v1/messages/delete", method: "POST", token: token,
                       body: try JSONSerialization.data(withJSONObject: ["ids": ids]))
    }

    func deleteAllMessages(endpoint: ServerEndpoint, token: String) async throws -> DeletedCount {
        try await json(endpoint: endpoint, path: "/api/v1/messages/all", method: "DELETE", token: token,
                       extraHeaders: ["X-Ferry-Confirm-Clear": "CLEAR_ALL"])
    }

    func deleteFavorite(endpoint: ServerEndpoint, token: String, messageID: String, opAt: Int64) async throws -> DeletedCount {
        try await json(endpoint: endpoint, path: "/api/v1/favorites/\(messageID)", method: "DELETE", token: token,
                       query: [URLQueryItem(name: "op_at", value: String(opAt))])
    }

    /// Attachment bytes, not JSON: `download_url` is a server-supplied path and
    /// the endpoint owns the origin, so a message cannot point the app at a
    /// different host. Streams to a cache file first so large files do not
    /// buffer in memory during download.
    func attachmentFile(endpoint: ServerEndpoint, token: String, path: String, filename: String?) async throws -> URL {
        var request = URLRequest(url: endpoint.url(path: path, queryItems: []))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (temporaryURL, response) = try await transferSession.download(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw ClientError.unauthorized }
            throw ClientError.invalidResponse
        }
        let destination = Self.cacheURL(for: path, filename: filename)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    /// Convenience Data wrapper for small payloads (image decoding).
    func attachment(endpoint: ServerEndpoint, token: String, path: String) async throws -> Data {
        let url = try await attachmentFile(endpoint: endpoint, token: token, path: path, filename: nil)
        return try Data(contentsOf: url)
    }

    private static func cacheURL(for path: String, filename: String?) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FerryAttachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var leaf = path.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        if leaf.isEmpty { leaf = "attachment" }
        let ext = (filename as NSString?)?.pathExtension.lowercased()
        if let ext, !ext.isEmpty { leaf += ".\(ext)" }
        return base.appendingPathComponent(leaf)
    }

    func json<T: Decodable>(endpoint: ServerEndpoint, path: String, method: String = "GET", token: String?,
                                    query: [URLQueryItem] = [], body: Data? = nil,
                                    contentType: String = "application/json",
                                    deviceKind: String? = nil,
                                    extraHeaders: [String: String] = [:]) async throws -> T {
        var request = URLRequest(url: endpoint.url(path: path, queryItems: query))
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let deviceKind { request.setValue(deviceKind, forHTTPHeaderField: "X-Ferry-Device-Kind") }
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401, token != nil { throw ClientError.unauthorized }
            if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) { throw ClientError.rejected(envelope.error.message) }
            throw ClientError.invalidResponse
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ClientError.invalidResponse }
    }

    private var nativeDeviceKind: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }
}
