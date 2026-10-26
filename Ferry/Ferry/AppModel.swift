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

    /// The assistant currently being filtered on (nil = 全部, no filter).
    var selectedAssistantID: String?
    private(set) var unreadAssistantIDs: Set<String> = []

    /// Route requested by a tapped notification; consumed by the timeline once
    /// it is on screen (a cold start applies it as soon as it connects).
    private(set) var pendingRoute: NotificationRoute?

    /// Number of messages that arrived while their conversation was not on
    /// screen — the app icon badge value.
    var unreadCount: Int { unreadMessageIDs.count }

    let uploader = Uploader()
    let localStore: LocalDataStore
    let catalog = CommandCatalogStore()
    let assistantStore = AssistantStore()
    let avatarStore = AssistantAvatarStore()
    let notificationSettings = NotificationSettings.shared

    private let notifier = MessageNotifier.shared
    private let client: any FerryServicing
    private let credentials: CredentialStoring
    private let defaults: UserDefaults
    private(set) var endpoint: ServerEndpoint?
    private(set) var token: String?
    private var cursor: Int64 = 0
    private var generation = UUID()
    private var loadingImages: Set<String> = []
    private var loadingThumbnails: Set<String> = []
    private var pollTask: Task<Void, Never>?
    private var isActive = true
    private var dayIndexStarted = false
    private var countedMessageIDs: Set<String> = []
    /// Message ids counted as unread (badge). Cleared as the user reads them.
    private var unreadMessageIDs: Set<String> = []
    private var lastBadgeCount = 0
    /// Background grace window that keeps polling alive after leaving the app.
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
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
        notifier.onRoute = { [weak self] route in self?.apply(notificationRoute: route) }
    }

    var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var imageMessages: [MessagePayload] {
        messages.filter { $0.file?.mediaType.hasPrefix("image/") == true }
    }

    /// Every loaded image + video message (non-hidden), for the media gallery.
    var mediaMessages: [MessagePayload] {
        messages.filter {
            guard let file = $0.file else { return false }
            return PreviewRouter.isImage(file.mediaType) || PreviewRouter.isVideo(file)
        }
    }

    /// Messages shown in the timeline, after applying the active assistant
    /// filter (nil = 全部, everything).
    var visibleMessages: [MessagePayload] {
        guard let selectedAssistantID else { return messages }
        return messages.filter { assistantStore.assistant(for: $0)?.id == selectedAssistantID }
    }

    var daySections: [DaySection] {
        var sections: [DaySection] = []
        var current: [MessagePayload] = []
        var currentDay: String?
        for message in visibleMessages {
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
            refreshCommandCatalog()
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

    /// Select an assistant filter (nil = 全部). Selecting an assistant marks
    /// its unseen messages as seen; selecting 全部 marks everything as seen.
    func selectAssistant(_ id: String?) {
        selectedAssistantID = id
        if let id {
            unreadAssistantIDs.remove(id)
            clearUnread(forAssistant: id)
        } else {
            unreadAssistantIDs.removeAll()
            clearAllUnread()
        }
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active {
            endBackgroundGrace()
            refreshCommandCatalog()
            // Returning to the app counts as reading whatever is on screen.
            markVisibleAsRead()
            if phase == .connected || phase == .offline { startPolling() }
            else { Task { await start() } }
        } else {
            // Keep the existing poll loop alive for the short background grace
            // window iOS grants, so messages that arrive right after leaving
            // Ferry can still raise a local notification. When the window
            // expires the app is suspended and nothing can wake it (no APNs),
            // which is the limitation documented in the T8 report.
            beginBackgroundGrace()
        }
    }

    // MARK: - Notifications

    /// Called after the user flips the 通知 switch in 设置.
    func notificationSettingsDidChange() {
        if notificationSettings.isEnabled {
            Task { await notifier.requestAuthorization() }
            updateBadge()
        } else {
            unreadMessageIDs.removeAll()
            lastBadgeCount = 0
            Task { await notifier.clearAll() }
        }
    }

    /// Drop the pending notification route once the timeline has applied it.
    func consumeNotificationRoute() { pendingRoute = nil }

    private func apply(notificationRoute route: NotificationRoute) { pendingRoute = route }

    /// Trigger a (throttled) FerryHelper command-catalog fetch for the current
    /// server host. Silently no-ops when there is no endpoint yet (and never
    /// fetches in `-uiTestMock` mode because the endpoint is nil there).
    func refreshCommandCatalog() {
        catalog.refresh(host: endpoint?.baseURL.host)
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
            let url = try await client.attachmentFile(endpoint: endpoint, token: token, path: file.downloadURL, filename: file.name)
            guard current == generation else { return }
            let poster = await VideoThumbnailCache.generate(fromFileURL: url, id: message.id)
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

    /// Enqueue an image produced by the editor as a new outgoing message.
    /// Returns a Chinese error message on failure, or nil on success. The
    /// original message (when there was one) is left untouched.
    @discardableResult
    func sendEditedImage(_ image: UIImage, originalName: String?) -> String? {
        let ext = ((originalName ?? "") as NSString).pathExtension.lowercased()
        let mediaType = ext == "png" ? "image/png" : "image/jpeg"
        guard let encoded = EditedImageExport.encode(image, originalMediaType: mediaType) else {
            return "编辑后的图片无法导出。"
        }
        let name = EditedImageExport.name(for: originalName ?? "编辑", mime: encoded.mime)
        return uploader.enqueue(data: encoded.data, name: name, mediaType: encoded.mime)
    }

    func fileData(for message: MessagePayload) async -> Data? {
        guard let url = await fileURL(for: message) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Download an attachment to a local file URL (streamed to disk, never
    /// buffered in memory). Callers that can use a file URL (video player,
    /// QuickLook) should prefer this over `fileData`.
    func fileURL(for message: MessagePayload) async -> URL? {
        guard let file = message.file, let endpoint, let token else { return nil }
        let current = generation
        do {
            let url = try await client.attachmentFile(endpoint: endpoint, token: token, path: file.downloadURL, filename: file.name)
            guard current == generation else { return nil }
            return url
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
        selectedAssistantID = nil
        unreadAssistantIDs = []
        unreadMessageIDs = []
        draft = ""
        isSending = false
        statusMessage = nil
        credentialWarning = nil
        endBackgroundGrace()
        uploader.teardown()
        // Force the badge to be republished: iOS keeps showing the previous
        // session's count until something writes a new one.
        lastBadgeCount = -1
        updateBadge()
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
            refreshCommandCatalog()
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

    /// Client-side keyword search over loaded messages, paging older history in
    /// the background up to `maxPages` (≈2000 messages) — the same paging used
    /// by the date-jump feature. The query matches the text body or file name
    /// (case-insensitive, Chinese OK). `messages` already excludes locally
    /// hidden/cleared messages, so results respect those too.
    func searchMessages(query: String, filter: SearchFilter, maxPages: Int = 40) async -> [MessagePayload] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // File-type filters (图片/视频/文件) may list their whole category
        // without a keyword; text/link still require a search term.
        guard !query.isEmpty || filter.isTypeOnly else { return [] }
        var results: [MessagePayload] = []
        var seen: Set<String> = []

        func scan(_ batch: [MessagePayload]) {
            for message in batch where !seen.contains(message.id) {
                seen.insert(message.id)
                if SearchFilter.matches(message, query: query, filter: filter) {
                    results.append(message)
                }
            }
        }

        scan(messages)
        var pages = 0
        while pages < maxPages, !Task.isCancelled, hasOlder {
            guard await loadOlder() else { break }
            pages += 1
            scan(messages)
        }
        // Newest first.
        return results.sorted { $0.sequence > $1.sequence }
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
        markUnreadIfNeeded(message)
        registerIncoming(message)
    }

    /// A newly arrived assistant message is "unseen" only while a *different*
    /// assistant is being filtered. Viewing 全部 or that assistant itself
    /// counts as seen, so no red dot is raised in those cases.
    private func markUnreadIfNeeded(_ message: MessagePayload) {
        guard let assistantID = assistantStore.assistant(for: message)?.id else { return }
        if let selectedAssistantID, selectedAssistantID != assistantID {
            unreadAssistantIDs.insert(assistantID)
        }
    }

    /// Count + announce a message that just arrived. Only messages whose
    /// conversation the user is *not* looking at produce a notification, so
    /// the current conversation never pops a duplicate banner.
    private func registerIncoming(_ message: MessagePayload) {
        guard !message.isCurrentDevice else { return }
        guard notificationSettings.isEnabled else { return }
        let assistant = assistantStore.assistant(for: message)
        guard !isConversationVisible(assistant) else { return }
        guard message.sequence > notificationSettings.lastNotifiedSequence else { return }
        notificationSettings.lastNotifiedSequence = message.sequence
        unreadMessageIDs.insert(message.id)
        updateBadge()
        Task { await notifier.notify(message: message, assistant: assistant) }
    }

    /// Whether the message's conversation is on screen right now.
    private func isConversationVisible(_ assistant: Assistant?) -> Bool {
        // `.offline` counts as visible too: a message that arrives while a
        // transient error is being repaired is still on screen.
        guard isActive, phase == .connected || phase == .offline else { return false }
        guard let selectedAssistantID else { return true } // 全部 shows everything
        return assistant?.id == selectedAssistantID
    }

    private func markVisibleAsRead() {
        if let selectedAssistantID { clearUnread(forAssistant: selectedAssistantID) }
        else { clearAllUnread() }
    }

    private func clearUnread(forAssistant id: String) {
        guard !unreadMessageIDs.isEmpty else { return }
        unreadMessageIDs = unreadMessageIDs.filter { messageID in
            guard let message = messages.first(where: { $0.id == messageID }) else { return true }
            return assistantStore.assistant(for: message)?.id != id
        }
        updateBadge()
    }

    private func clearAllUnread() {
        guard !unreadMessageIDs.isEmpty else { return }
        unreadMessageIDs.removeAll()
        updateBadge()
    }

    private func updateBadge() {
        let count = unreadMessageIDs.count
        guard count != lastBadgeCount else { return }
        lastBadgeCount = count
        Task { await notifier.setBadge(count) }
    }

    /// Ask iOS for a little extra background time when Ferry leaves the
    /// foreground so the existing poll loop can keep running briefly.
    private func beginBackgroundGrace() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Ferry.backgroundPoll") { [weak self] in
            Task { @MainActor in self?.endBackgroundGrace() }
        }
    }

    private func endBackgroundGrace() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
        pollTask?.cancel()
        pollTask = nil
    }

    private func handleUnauthorized() {
        guard let endpoint else { phase = .setup; return }
        try? credentials.removeToken(for: endpoint.origin)
        _ = resetSession(endpoint: endpoint, token: nil)
        phase = .setup
        statusMessage = "当前设备已断开连接，请重新连接。"
    }

    /// The current device was revoked from the device-management page (or its
    /// token invalidated); clear the local credential and return to pairing.
    func deviceWasRevoked() {
        handleUnauthorized()
        statusMessage = "当前设备已被移除，请重新连接。"
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
        currentDevice = Device(id: "mock-self", name: "我的 iPhone", kind: "iphone", createdAt: createdAt)
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
