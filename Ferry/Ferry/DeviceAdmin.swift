import Foundation
import Observation

/// The narrow slice of the Ferry API used by the device-management page:
/// listing paired devices, revoking one, and reading/setting the access
/// password. Kept separate from `FerryServicing` so a UI-test mock only has
/// to implement these four calls.
protocol DeviceAdminServicing {
    func devices(endpoint: ServerEndpoint, token: String) async throws -> [Device]
    func revokeDevice(endpoint: ServerEndpoint, token: String, deviceID: String) async throws
    func settingsAccessStatus(endpoint: ServerEndpoint, token: String) async throws -> Bool
    func setAccessPassword(endpoint: ServerEndpoint, token: String, password: String) async throws -> Bool
}

extension FerryClient: DeviceAdminServicing {
    /// `GET /api/v1/devices` -> `{"devices":[{id,name,kind,created_at}]}`.
    func devices(endpoint: ServerEndpoint, token: String) async throws -> [Device] {
        let payload: DevicesPayload = try await json(endpoint: endpoint, path: "/api/v1/devices", token: token)
        return payload.devices
    }

    /// `DELETE /api/v1/devices/{id}` -> 204; 409 cannot_revoke_device; 404
    /// not_found; 401 if the requester was revoked. Success has no body, so it
    /// is handled separately from `json`.
    func revokeDevice(endpoint: ServerEndpoint, token: String, deviceID: String) async throws {
        var request = URLRequest(url: endpoint.url(path: "/api/v1/devices/\(deviceID)"))
        request.httpMethod = "DELETE"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw ClientError.unauthorized }
            if http.statusCode == 409 { throw DeviceAdminError.cannotRevoke }
            if http.statusCode == 404 { throw DeviceAdminError.deviceNotFound }
            if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
                throw ClientError.rejected(envelope.error.message)
            }
            throw ClientError.invalidResponse
        }
    }

    /// `GET /api/v1/settings/access` -> `{"password_required":bool}`.
    func settingsAccessStatus(endpoint: ServerEndpoint, token: String) async throws -> Bool {
        let payload: AccessStatusPayload = try await json(endpoint: endpoint, path: "/api/v1/settings/access", token: token)
        return payload.passwordRequired
    }

    /// `PUT /api/v1/settings/access` with `{"password":"..."}`. A non-empty
    /// password sets or changes it; `""` disables the requirement. There is no
    /// old-password check on the server. Existing paired devices are unaffected.
    func setAccessPassword(endpoint: ServerEndpoint, token: String, password: String) async throws -> Bool {
        let payload: AccessStatusPayload = try await json(endpoint: endpoint, path: "/api/v1/settings/access",
                                                          method: "PUT", token: token,
                                                          body: try JSONSerialization.data(withJSONObject: ["password": password]))
        return payload.passwordRequired
    }
}

enum DeviceAdminError: LocalizedError, Equatable {
    case cannotRevoke
    case deviceNotFound
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .cannotRevoke: return "无法移除该设备：服务器不允许移除当前设备或最后一台设备。"
        case .deviceNotFound: return "设备不存在或已被移除。"
        case .invalidResponse: return "Ferry 服务器返回了无效响应。"
        }
    }
}

/// Client-side validation for a new access password. The server only
/// distinguishes empty (disable) from non-empty (set/change); the client adds
/// a safety length cap and a confirm-match check so the UI can catch typos
/// before issuing the PUT.
enum AccessPasswordValidator {
    static let maxLength = 256

    static func validate(_ password: String, confirm: String) -> String? {
        if password.isEmpty { return "请输入密码。" }
        if password.count > maxLength { return "密码过长，请控制在 \(maxLength) 个字符以内。" }
        if password != confirm { return "两次输入的密码不一致。" }
        return nil
    }
}

@MainActor @Observable
final class DeviceAdminModel {
    private let service: any DeviceAdminServicing
    private var endpoint: ServerEndpoint?
    private var token: String?
    private let isMock: Bool

    private(set) var devices: [Device] = []
    private(set) var currentDeviceID: String?
    private(set) var passwordRequired = false
    private(set) var isLoading = false
    private(set) var isApplyingPassword = false
    private(set) var errorMessage: String?
    private(set) var shouldReturnToPairing = false

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestMock") {
            isMock = true
            service = MockDeviceAdminService()
        } else {
            isMock = false
            service = FerryClient()
        }
        #else
        isMock = false
        service = FerryClient()
        #endif
    }

    /// Wire the model to the active connection. In `-uiTestMock` mode the
    /// endpoint/token are placeholders and the in-memory mock is used instead.
    func configure(endpoint: ServerEndpoint?, token: String?, currentDeviceID: String?) {
        if isMock {
            self.endpoint = try? ServerEndpoint("http://ui-test-mock.local:42819")
            self.token = "ui-test-mock-token"
            self.currentDeviceID = currentDeviceID ?? "mock-self"
        } else {
            self.endpoint = endpoint
            self.token = token
            self.currentDeviceID = currentDeviceID
        }
    }

    /// Current device first, then the rest alphabetically (stable sort).
    var sortedDevices: [Device] {
        devices.sorted { lhs, rhs in
            let leftRank = lhs.id == currentDeviceID ? 0 : 1
            let rightRank = rhs.id == currentDeviceID ? 0 : 1
            if leftRank != rightRank { return leftRank < rightRank }
            return lhs.name < rhs.name
        }
    }

    func load() async {
        guard let endpoint, let token else {
            errorMessage = "尚未连接服务器。"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            devices = try await service.devices(endpoint: endpoint, token: token)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            handle(error)
            return
        }
        // Password state is best-effort so a transient failure there does not
        // blank out the device list.
        if let required = try? await service.settingsAccessStatus(endpoint: endpoint, token: token) {
            passwordRequired = required
        }
    }

    func remove(_ device: Device) async {
        guard let endpoint, let token else {
            errorMessage = "尚未连接服务器。"
            return
        }
        do {
            try await service.revokeDevice(endpoint: endpoint, token: token, deviceID: device.id)
            devices.removeAll { $0.id == device.id }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            handle(error)
        }
    }

    func setPassword(_ password: String) async {
        guard let endpoint, let token else {
            errorMessage = "尚未连接服务器。"
            return
        }
        isApplyingPassword = true
        defer { isApplyingPassword = false }
        do {
            passwordRequired = try await service.setAccessPassword(endpoint: endpoint, token: token, password: password)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            handle(error)
        }
    }

    private func handle(_ error: Error) {
        if let clientError = error as? FerryClient.ClientError, clientError == .unauthorized {
            shouldReturnToPairing = true
            errorMessage = nil
            return
        }
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

#if DEBUG
/// In-memory stand-in for UI tests. With `-uiTestMock` the device/password
/// calls hit this mock and never the network, so a UI test can exercise the
/// removal and password flows deterministically without a server.
@MainActor
final class MockDeviceAdminService: DeviceAdminServicing {
    private var devices: [Device] = [
        Device(id: "mock-self", name: "我的 iPhone", kind: "iphone", createdAt: "2026-10-01T08:00:00Z"),
        Device(id: "mock-pc", name: "Windows PC", kind: "windows", createdAt: "2026-10-02T09:30:00Z"),
        Device(id: "mock-helper", name: "助手 FerryHelper", kind: "browser", createdAt: "2026-10-03T10:00:00Z"),
        Device(id: "mock-ipad", name: "客厅 iPad", kind: "ipad", createdAt: "2026-10-04T11:00:00Z"),
    ]
    private var passwordRequired = false
    private let currentDeviceID = "mock-self"

    func devices(endpoint: ServerEndpoint, token: String) async throws -> [Device] {
        devices
    }

    func revokeDevice(endpoint: ServerEndpoint, token: String, deviceID: String) async throws {
        if deviceID == currentDeviceID || devices.count <= 1 {
            throw DeviceAdminError.cannotRevoke
        }
        devices.removeAll { $0.id == deviceID }
    }

    func settingsAccessStatus(endpoint: ServerEndpoint, token: String) async throws -> Bool {
        passwordRequired
    }

    func setAccessPassword(endpoint: ServerEndpoint, token: String, password: String) async throws -> Bool {
        passwordRequired = !password.isEmpty
        return passwordRequired
    }
}
#endif
