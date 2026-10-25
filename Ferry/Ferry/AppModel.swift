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
    private(set) var videoDurations: [String: Double] = [:]
    private(set) var hasOlder = false
    private(set) var isLoadingOlder = false
    private(set) var isLoadingInitial = false
    private(set) var dayCounts: [String: Int] = [:]

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
    private var dayIndexStarted = false
    private var countedMessageIDs: Set<String> = []
    private static let serverKey = "ferry.server.origin"
    private static let pageSize = 50
    private static let maxHistoryPages = 40

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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestMock") {
            applyMockMessagesIfNeeded()
            return
        }
        #endif
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
            await loadInitial(generation: current)
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
        guard let file = message.file, PreviewRouter.isVideo(file) else { return }
        guard videoThumbnails[message.id] == nil, !loadingThumbnails.contains(message.id) else { return }
        if let cached = VideoThumbnailCache.cachedThumbnail(for: message.id) {
            videoThumbnails[message.id] = cached
            videoDurations[message.id] = VideoThumbnailCache.cachedDuration(for: message.id)
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
            let poster = await VideoThumbnailCache.generate(from: data, id: message.id, fileExtension: ext)
            guard current == generation else { return }
            videoThumbnails[message.id] = poster.image
            videoDurations[message.id] = poster.duration
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
        videoDurations = [:]
        loadingImages = []
        loadingThumbnails = []
        cursor = 0
        hasOlder = false
        isLoadingOlder = false
        isLoadingInitial = false
        dayCounts = [:]
        dayIndexStarted = false
        countedMessageIDs = []
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
            await loadInitial(generation: current)
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

    /// Initial (WeChat-style) load: fetch the newest page and, later, start
    /// scanning older history in the background for the date-jump calendar.
    private func loadInitial(generation current: UUID) async {
        guard current == generation, let endpoint, let token else { return }
        isLoadingInitial = true
        defer { isLoadingInitial = false }
        do {
            let page = try await client.messagesLatest(endpoint: endpoint, token: token, limit: Self.pageSize)
            guard current == generation else { return }
            applyInitial(page)
            phase = .connected
            statusMessage = nil
            buildDayIndexIfNeeded()
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch { handle(error, generation: current) }
    }

    private func applyInitial(_ page: MessagesPage) {
        let visible = page.messages.filter { !localStore.isHidden($0) }
        messages = visible.sorted { $0.sequence < $1.sequence }
        hasOlder = page.hasOlder
        cursor = max(messages.map(\.sequence).max() ?? 0, page.nextCursor)
        dayCounts = [:]
        countedMessageIDs = []
        countDays(messages)
    }

    /// Load one older page and prepend it, preserving the caller's scroll
    /// anchor (the caller scrolls back to the previous first message).
    @discardableResult
    func loadOlder() async -> Bool {
        guard !isLoadingOlder, hasOlder, let endpoint, let token,
              let oldest = messages.first?.sequence else { return false }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        let current = generation
        do {
            let page = try await client.messagesBefore(endpoint: endpoint, token: token, before: oldest, limit: Self.pageSize)
            guard current == generation else { return false }
            prepend(page.messages)
            hasOlder = page.hasOlder
            return true
        } catch is CancellationError {
            return false
        } catch let error as URLError where error.code == .cancelled {
            return false
        } catch {
            guard current == generation else { return false }
            statusMessage = error.localizedDescription
            return false
        }
    }

    private func prepend(_ incoming: [MessagePayload]) {
        let existing = Set(messages.map(\.id))
        let visible = incoming.filter { !localStore.isHidden($0) && !existing.contains($0.id) }
        guard !visible.isEmpty else { return }
        messages.insert(contentsOf: visible, at: 0)
        messages.sort { $0.sequence < $1.sequence }
        countDays(visible)
        cursor = max(cursor, visible.map(\.sequence).max() ?? cursor)
    }

    private func countDays(_ msgs: [MessagePayload]) {
        for message in msgs where !countedMessageIDs.contains(message.id) {
            countedMessageIDs.insert(message.id)
            guard let date = TimestampFormat.date(from: message.createdAt) else { continue }
            let key = DayKey.string(from: Calendar.current.startOfDay(for: date))
            dayCounts[key, default: 0] += 1
        }
    }

    /// Background history scan so the calendar dots reflect more than the
    /// currently-visible window. It only accumulates per-day counts and never
    /// touches `messages`, so the timeline does not jump. Bounded to
    /// `maxHistoryPages` pages (≈2000 messages).
    private func buildDayIndexIfNeeded() {
        guard !dayIndexStarted else { return }
        dayIndexStarted = true
        let startBefore = messages.first?.sequence ?? 0
        guard startBefore > 0 else { return }
        Task { [weak self] in
            await self?.scanHistory(from: startBefore)
        }
    }

    private func scanHistory(from startBefore: Int64) async {
        var before = startBefore
        var pages = 0
        while pages < Self.maxHistoryPages, !Task.isCancelled {
            guard let endpoint, let token else { return }
            let current = generation
            do {
                let page = try await client.messagesBefore(endpoint: endpoint, token: token, before: before, limit: Self.pageSize)
                guard current == generation else { return }
                let visible = page.messages.filter { !localStore.isHidden($0) }
                countDays(visible)
                guard let oldest = page.messages.map(\.sequence).min() else { return }
                before = oldest
                pages += 1
                if !page.hasOlder { return }
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                return
            }
        }
    }

    enum DateJumpResult: Equatable {
        case found(String)
        case empty
        case cancelled
    }

    /// Find the first message on a local calendar day, paging older until it is
    /// loaded (or history is exhausted / cancelled). Purely client-side: there
    /// is no by-date server endpoint.
    func locateDay(_ day: Date) async -> DateJumpResult {
        let target = Calendar.current.startOfDay(for: day)
        let targetKey = DayKey.string(from: target)

        if let hit = messages.first(where: { Self.messageDayKey($0) == targetKey }) {
            return .found(hit.id)
        }
        // A day newer than the newest loaded message cannot exist in history.
        if let latest = messages.last,
           let latestDate = TimestampFormat.date(from: latest.createdAt),
           Calendar.current.startOfDay(for: latestDate) < target {
            return .empty
        }

        var pages = 0
        while hasOlder, !Task.isCancelled, pages < Self.maxHistoryPages {
            guard await loadOlder() else { break }
            pages += 1
            if let hit = messages.first(where: { Self.messageDayKey($0) == targetKey }) {
                return .found(hit.id)
            }
        }
        if Task.isCancelled { return .cancelled }
        if let hit = messages.first(where: { Self.messageDayKey($0) == targetKey }) {
            return .found(hit.id)
        }
        return .empty
    }

    private static func messageDayKey(_ message: MessagePayload) -> String? {
        guard let date = TimestampFormat.date(from: message.createdAt) else { return nil }
        return DayKey.string(from: Calendar.current.startOfDay(for: date))
    }

    /// Copy the ≈90 s temporary download link for a file message to the
    /// pasteboard. Returns nil on success or a Chinese error message.
    @discardableResult
    func copyTemporaryLink(for message: MessagePayload) async -> String? {
        guard let endpoint, let token else { return "尚未连接服务器" }
        do {
            let link = try await client.downloadLink(endpoint: endpoint, token: token, messageID: message.id)
            UIPasteboard.general.string = endpoint.url(path: link.url).absoluteString
            return nil
        } catch {
            if let clientError = error as? FerryClient.ClientError {
                return clientError.errorDescription ?? "获取链接失败"
            }
            return "获取链接失败"
        }
    }

    private func append(_ message: MessagePayload) {
        guard !localStore.isHidden(message) else { return }
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        messages.append(message)
        messages.sort { $0.sequence < $1.sequence }
        cursor = max(cursor, message.sequence)
        countDays([message])
    }

    private func handleUnauthorized() {
        guard let endpoint else { phase = .setup; return }
        try? credentials.removeToken(for: endpoint.origin)
        _ = resetSession(endpoint: endpoint, token: nil)
        phase = .setup
        statusMessage = "当前设备已断开连接，请重新连接。"
    }

    #if DEBUG
    /// UI-test stub: with "-uiTestMock" the app skips pairing/network entirely
    /// and injects one text, one image and one video message so the timeline
    /// and its bubble context menus can be exercised deterministically.
    private func applyMockMessagesIfNeeded() {
        phase = .connected
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let text = MessagePayload(id: "mock-text", sequence: 1, kind: .text,
                                  senderName: "测试", senderKind: "iphone",
                                  isCurrentDevice: true, createdAt: createdAt,
                                  text: "测试文本消息", file: nil)
        let imageFile = FileInfo(name: "mock.jpg", mediaType: "image/jpeg", size: 1,
                                 downloadURL: "/api/v1/files/mock-image")
        let image = MessagePayload(id: "mock-image", sequence: 2, kind: .file,
                                   senderName: "测试", senderKind: "iphone",
                                   isCurrentDevice: false, createdAt: createdAt,
                                   text: nil, file: imageFile)
        let videoFile = FileInfo(name: "mock.mp4", mediaType: "video/mp4", size: 1,
                                 downloadURL: "/api/v1/files/mock-video")
        let video = MessagePayload(id: "mock-video", sequence: 3, kind: .file,
                                   senderName: "测试", senderKind: "iphone",
                                   isCurrentDevice: false, createdAt: createdAt,
                                   text: nil, file: videoFile)
        messages = [text, image, video]
        images["mock-image"] = makeMockImage()
        videoThumbnails["mock-video"] = makeMockImage()
        videoDurations["mock-video"] = 5.0
        countDays([text, image, video])
    }

    private func makeMockImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 90))
        return renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 90))
        }
    }
    #endif

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
