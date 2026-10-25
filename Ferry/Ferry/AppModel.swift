import Foundation
import Observation
import UIKit

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable { case setup, connecting, connected, offline }

    var serverAddress: String
    var deviceName: String
    var accessPassword = ""
    var draft = ""
    private(set) var phase: Phase = .setup
    private(set) var currentDevice: Device?
    private(set) var messages: [MessagePayload] = []
    private(set) var statusMessage: String?
    private(set) var credentialWarning: String?
    private(set) var isSending = false
    private(set) var isDiscovering = false
    private(set) var discovered: [DiscoveredServer] = []
    private(set) var discoveryMessage: String?
    private(set) var images: [String: UIImage?] = [:]
    private(set) var videoThumbnails: [String: UIImage?] = [:]

    let uploader = Uploader()
    let localStore: LocalDataStore

    private let client: any FerryServicing
    private let credentials: CredentialStoring
    private let defaults: UserDefaults
    private var endpoint: ServerEndpoint?
    private var token: String?
    private var cursor: Int64 = 0
    private var generation = UUID()
    private var loadingImages: Set<String> = []
    private var loadingThumbnails: Set<String> = []
    private var pollTask: Task<Void, Never>?
    private var isActive = true
    private static let serverKey = "ferry.server.origin"

    init(client: any FerryServicing = FerryClient(), credentials: CredentialStoring = KeychainCredentialStore(),
         defaults: UserDefaults = .standard) {
        self.client = client
        self.credentials = credentials
        self.defaults = defaults
        serverAddress = defaults.string(forKey: Self.serverKey) ?? ""
        deviceName = UIDevice.current.name
        localStore = LocalDataStore(defaults: defaults)
        uploader.onCreated = { [weak self] message in self?.append(message) }
        uploader.onUnauthorized = { [weak self] in self?.handleUnauthorized() }
    }

    var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var imageMessages: [MessagePayload] {
        messages.filter { $0.file?.mediaType.hasPrefix("image/") == true }
    }

    var daySections: [DaySection] {
        var sections: [DaySection] = []
        var current: [MessagePayload] = []
        var currentDay: String?
        for message in messages {
            let day = TimestampFormat.dayLabel(from: message.createdAt)
            if day != currentDay {
                if !current.isEmpty { sections.append(DaySection(dayLabel: currentDay ?? "", messages: current)) }
                current = []
                currentDay = day
            }
            current.append(message)
        }
        if !current.isEmpty { sections.append(DaySection(dayLabel: currentDay ?? "", messages: current)) }
        return sections
    }

    var lastServerOrigin: String? {
        let value = defaults.string(forKey: Self.serverKey)
        return (value?.isEmpty == false) ? value : nil
    }

    func start() async {
        guard phase == .setup else { return }
        guard let endpoint = try? ServerEndpoint(serverAddress) else { return }
        do {
            guard let stored = try credentials.token(for: endpoint.origin) else { return }
            let current = resetSession(endpoint: endpoint, token: stored)
            phase = .connecting
            await authenticate(generation: current)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func connect() async {
        let requestedAddress = serverAddress
        let current: UUID
        let endpoint: ServerEndpoint
        do {
            endpoint = try ServerEndpoint(serverAddress)
            current = resetSession(endpoint: endpoint, token: nil)
        } catch { statusMessage = error.localizedDescription; return }
        phase = .connecting
        statusMessage = nil
        do {
            // `/api/v1/access` reports whether the server enforces a password.
            let required = try await client.accessStatus(endpoint: endpoint)
            if required && accessPassword.isEmpty {
                statusMessage = "该 Ferry 服务器需要访问密码，请在电脑上查看后输入。"
                phase = .setup
                return
            }
            let claim = try await client.join(endpoint: endpoint, password: accessPassword, name: deviceName)
            guard current == generation, serverAddress == requestedAddress else { return }
            token = claim.token
            currentDevice = claim.device
            defaults.set(endpoint.origin, forKey: Self.serverKey)
            serverAddress = endpoint.origin
            do { try credentials.save(token: claim.token, for: endpoint.origin) }
            catch { credentialWarning = error.localizedDescription }
            accessPassword = ""
            phase = .connected
            uploader.configure(endpoint: endpoint, token: claim.token)
            await refreshMessages(generation: current)
            startPolling()
        } catch { handle(error, generation: current) }
    }

    func discover() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        defer { isDiscovering = false }
        await LANDiscovery.warmUp()
        discovered = await LANDiscovery.scan()
        discoveryMessage = discovered.isEmpty
            ? "未找到电脑。请确认 iPhone 与电脑在同一 Wi-Fi，且已在 设置 → 隐私与安全性 → 本地网络 中允许 Ferry。也可使用“扫描二维码”或上次连接的地址。"
            : nil
    }

    func selectDiscovered(_ server: DiscoveredServer) {
        accessPassword = ""
        serverAddress = server.origin
        discoveryMessage = nil
    }

    func applyScannedAddress(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = try? ServerEndpoint(trimmed) else {
            statusMessage = "二维码不是有效的 Ferry 服务器地址。"
            return
        }
        accessPassword = ""
        serverAddress = endpoint.origin
        statusMessage = nil
        discoveryMessage = nil
    }

    func send() async {
        guard let endpoint, let token, canSend else { return }
        let current = generation
        let sentDraft = draft
        isSending = true
        defer {
            if current == generation { isSending = false }
        }
        do {
            let message = try await client.sendText(endpoint: endpoint, token: token, text: sentDraft)
            guard current == generation else { return }
            append(message)
            if draft == sentDraft { draft = "" }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            guard current == generation else { return }
            if error as? FerryClient.ClientError == .unauthorized {
                handle(error, generation: current)
            } else {
                statusMessage = error.localizedDescription
                if error is URLError || error as? FerryClient.ClientError == .invalidResponse { phase = .offline }
            }
        }
    }

    func disconnect() {
        guard let endpoint else { phase = .setup; return }
        let removalError: String?
        do {
            try credentials.removeToken(for: endpoint.origin)
            removalError = nil
        } catch {
            removalError = error.localizedDescription
        }
        _ = resetSession(endpoint: endpoint, token: nil)
        phase = .setup
        statusMessage = removalError
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active {
            if phase == .connected || phase == .offline { startPolling() }
            else { Task { await start() } }
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    func loadImage(for message: MessagePayload) async {
        guard let file = message.file, file.mediaType.hasPrefix("image/") else { return }
        guard images[message.id] == nil, !loadingImages.contains(message.id) else { return }
        guard let endpoint, let token else { return }
        let current = generation
        loadingImages.insert(message.id)
        defer { loadingImages.remove(message.id) }
        do {
            let data = try await client.attachment(endpoint: endpoint, token: token, path: file.downloadURL)
            guard current == generation else { return }
            images[message.id] = UIImage(data: data)
        } catch {
            guard current == generation else { return }
            images[message.id] = UIImage?.none
        }
    }

    func loadVideoThumbnail(for message: MessagePayload) async {
        guard let file = message.file, file.mediaType.hasPrefix("video/") else { return }
        guard videoThumbnails[message.id] == nil, !loadingThumbnails.contains(message.id) else { return }
        if let cached = VideoThumbnailCache.cachedThumbnail(for: message.id) {
            videoThumbnails[message.id] = cached
            return
        }
        guard let endpoint, let token else { return }
        let current = generation
        loadingThumbnails.insert(message.id)
        defer { loadingThumbnails.remove(message.id) }
        do {
            let data = try await client.attachment(endpoint: endpoint, token: token, path: file.downloadURL)
            guard current == generation else { return }
            let ext = PreviewRouter.fileExtension(name: file.name, mediaType: file.mediaType)
            let thumbnail = await VideoThumbnailCache.generate(from: data, id: message.id, fileExtension: ext)
            guard current == generation else { return }
            videoThumbnails[message.id] = thumbnail
        } catch {
            guard current == generation else { return }
            videoThumbnails[message.id] = UIImage?.none
        }
    }

    func deleteSelected(_ ids: Set<String>) {
        localStore.hide(ids)
        messages.removeAll { ids.contains($0.id) }
    }

    func clearAllMessages() {
        let maxSequence = messages.map(\.sequence).max() ?? 0
        localStore.clearAll(upTo: maxSequence)
        messages.removeAll()
    }

    func toggleFavorite(_ message: MessagePayload) async {
        if localStore.isFavorite(message.id) {
            localStore.removeFavorite(message.id)
        } else {
            var data: Data?
            if message.file != nil { data = await fileData(for: message) }
            localStore.addFavorite(message, fileData: data)
        }
    }

    func fileData(for message: MessagePayload) async -> Data? {
        guard let file = message.file, let endpoint, let token else { return nil }
        let current = generation
        do {
            let data = try await client.attachment(endpoint: endpoint, token: token, path: file.downloadURL)
            guard current == generation else { return nil }
            return data
        } catch {
            guard current == generation else { return nil }
            if error as? FerryClient.ClientError == .unauthorized {
                handle(error, generation: current)
            } else {
                statusMessage = error.localizedDescription
            }
            return nil
        }
    }

    private func resetSession(endpoint: ServerEndpoint, token: String?) -> UUID {
        pollTask?.cancel()
        pollTask = nil
        generation = UUID()
        self.endpoint = endpoint
        self.token = token
        currentDevice = nil
        messages = []
        images = [:]
        videoThumbnails = [:]
        loadingImages = []
        loadingThumbnails = []
        cursor = 0
        draft = ""
        isSending = false
        statusMessage = nil
        credentialWarning = nil
        uploader.teardown()
        return generation
    }

    private func authenticate(generation current: UUID) async {
        guard let endpoint, let token else { return }
        do {
            let device = try await client.currentDevice(endpoint: endpoint, token: token)
            guard current == generation else { return }
            currentDevice = device
            phase = .connected
            statusMessage = nil
            uploader.configure(endpoint: endpoint, token: token)
            await refreshMessages(generation: current)
            startPolling()
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch { handle(error, generation: current) }
    }

    private func startPolling() {
        guard isActive, pollTask == nil, token != nil else { return }
        let current = generation
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshMessages(generation: current)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refreshMessages(generation current: UUID) async {
        guard current == generation, let endpoint, let token else { return }
        do {
            let page = try await client.messages(endpoint: endpoint, token: token, after: cursor)
            guard current == generation else { return }
            page.messages.forEach(append)
            cursor = page.nextCursor
            phase = .connected
            statusMessage = nil
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch { handle(error, generation: current) }
    }

    private func append(_ message: MessagePayload) {
        guard !localStore.isHidden(message) else { return }
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        messages.append(message)
        messages.sort { $0.sequence < $1.sequence }
        cursor = max(cursor, message.sequence)
    }

    private func handleUnauthorized() {
        guard let endpoint else { phase = .setup; return }
        try? credentials.removeToken(for: endpoint.origin)
        _ = resetSession(endpoint: endpoint, token: nil)
        phase = .setup
        statusMessage = "当前设备已断开连接，请重新连接。"
    }

    private func handle(_ error: Error, generation current: UUID) {
        guard current == generation else { return }
        statusMessage = error.localizedDescription
        if error as? FerryClient.ClientError == .unauthorized {
            guard let endpoint else { phase = .setup; return }
            try? credentials.removeToken(for: endpoint.origin)
            _ = resetSession(endpoint: endpoint, token: nil)
            phase = .setup
        } else {
            phase = token == nil ? .setup : .offline
        }
    }
}
