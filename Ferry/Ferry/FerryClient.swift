import Foundation
import UIKit

protocol FerryServicing {
    func accessStatus(endpoint: ServerEndpoint) async throws -> Bool
    func join(endpoint: ServerEndpoint, password: String, name: String) async throws -> AccessClaim
    func currentDevice(endpoint: ServerEndpoint, token: String) async throws -> Device
    func messages(endpoint: ServerEndpoint, token: String, after: Int64) async throws -> MessagesPage
    func sendText(endpoint: ServerEndpoint, token: String, text: String) async throws -> MessagePayload
    func attachment(endpoint: ServerEndpoint, token: String, path: String) async throws -> Data
}

struct FerryClient: FerryServicing {
    enum ClientError: LocalizedError, Equatable {
        case unauthorized
        case rejected(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .unauthorized: "This device is no longer connected."
            case .rejected(let message): message
            case .invalidResponse: "The Ferry Server returned an invalid response."
            }
        }
    }

    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

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

    func sendText(endpoint: ServerEndpoint, token: String, text: String) async throws -> MessagePayload {
        try await json(endpoint: endpoint, path: "/api/v1/messages/text", method: "POST", token: token,
                       body: try JSONSerialization.data(withJSONObject: ["text": text]))
    }

    /// Attachment bytes, not JSON: `download_url` is a server-supplied path and
    /// the endpoint owns the origin, so a message cannot point the app at a
    /// different host.
    func attachment(endpoint: ServerEndpoint, token: String, path: String) async throws -> Data {
        var request = URLRequest(url: endpoint.url(path: path, queryItems: []))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw ClientError.unauthorized }
            throw ClientError.invalidResponse
        }
        return data
    }

    private func json<T: Decodable>(endpoint: ServerEndpoint, path: String, method: String = "GET", token: String?,
                                    query: [URLQueryItem] = [], body: Data? = nil,
                                    contentType: String = "application/json",
                                    deviceKind: String? = nil) async throws -> T {
        var request = URLRequest(url: endpoint.url(path: path, queryItems: query))
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let deviceKind { request.setValue(deviceKind, forHTTPHeaderField: "X-Ferry-Device-Kind") }
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
