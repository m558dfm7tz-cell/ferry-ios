import Foundation

struct ServerEndpoint: Equatable, Sendable {
    enum ValidationError: LocalizedError {
        case invalid
        var errorDescription: String? { "请输入 HTTP 或 HTTPS 服务器地址，例如 http://192.168.1.20:42819。" }
    }

    let baseURL: URL
    var origin: String { baseURL.absoluteString }

    init(_ input: String) throws {
        guard var parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else {
            throw ValidationError.invalid
        }
        parts.scheme = scheme
        parts.host = host.lowercased()
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) { parts.port = nil }
        parts.path = ""
        guard let normalized = parts.url else { throw ValidationError.invalid }
        baseURL = normalized
    }

    func url(path: String, queryItems: [URLQueryItem] = []) -> URL {
        var parts = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        parts.queryItems = queryItems.isEmpty ? nil : queryItems
        return parts.url!
    }
}
