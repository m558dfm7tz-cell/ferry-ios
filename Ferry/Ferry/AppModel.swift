import Foundation
import Observation
import UIKit
import CryptoKit

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
    private var dayCountsByConversation: [String: [String: Int]] = [:]

    /// Nil means the transfer tab once new routing is verified.
    var selectedAssistantID: String?
    /// Fail closed. Do not enable until the actual Go + running FerryHelper
    /// capability contract has been implemented and verified together.
    private(set) var routeIsolationEnabled = false
    /// Stable server profile identities, to be supplied by future verified
    /// assistant-profiles API. Never manufacture custom server identifiers.
    private var verifiedRouteNamesByID: [String: String] = [:]
    private var lastProfileRefresh: Date?

    /// The selection is captured before sending. Unknown profile IDs must
    /// fail closed rather than being sent as a normal transfer.
    private func destinationForMessage(_ message: MessagePayload) -> MessageDestination? {
        guard routeIsolationEnabled else { return nil }
        guard let id = assistantStore.conversationID(for: message) else { return .transfer }
        if let base = AssistantStore.builtIn.first(where: { $0.id == id }) {
            return .assistant(name: base.name, id: base.id)
        }
        guard let name = verifiedRouteNamesByID[id] else { return nil }
        return .assistant(name: name, id: id)
    }

    /// External shares must choose an explicit, validated conversation. A
    /// legacy server without verified route isolation cannot accept shared
    /// files, because silent fallback could deliver to the wrong assistant.
    func destinationForExternalShare(_ assistantID: String?) -> MessageDestination? {
        guard routeIsolationEnabled else { return nil }
        guard let assistantID else { return .transfer }
        guard let assistant = assistantStore.assistants.first(where: { $0.id == assistantID }) else {
            return nil
        }
        if assistant.isBuiltIn,
           let base = AssistantStore.builtIn.first(where: { $0.id == assistant.id }) {
            return .assistant(name: base.name, id: base.id)
        }
        guard let name = verifiedRouteNamesByID[assistantID], !name.isEmpty else { return nil }
        return .assistant(name: name, id: assistantID)
    }

    private func destinationForSelection() -> MessageDestination? {
        guard routeIsolationEnabled else { return nil }
        guard let selectedAssistantID else { return .transfer }
        guard let assistant = assistantStore.assistants.first(where: { $0.id == selectedAssistantID }) else {
            return nil
        }
        if assistant.isBuiltIn,
           let base = AssistantStore.builtIn.first(where: { $0.id == assistant.id }) {
            return .assistant(name: base.name, id: base.id)
        }
        guard let routeName = verifiedRouteNamesByID[assistant.id], !routeName.isEmpty else {
            return nil
        }
        return .assistant(name: routeName, id: assistant.id)
    }
    /// V2 stays disabled unless both the Go server and *running* helper
    /// positively confirm the guard, and their profile list is consistent.
    private func configureVerifiedRouting(generation current: UUID) async {
        guard current == generation, let endpoint, let token else { return }
        guard let capabilities = try? await client.capabilities(endpoint: endpoint, token: token),
              capabilities.permitsIsolatedTransfer,
              let snapshot = try? await client.assistantProfiles(endpoint: endpoint, token: token),
              !snapshot.profiles.isEmpty else { return }

        // Never activate with missing/contradictory built-in identities.
        let ids = Set(snapshot.profiles.map(\.id))
        guard ids.count == snapshot.profiles.count,
              AssistantStore.builtIn.allSatisfy({ expected in
                  snapshot.profiles.contains(where: {
                      $0.id == expected.id && $0.routeName == expected.name && !$0.deleted
                  })
              }), current == generation else { return }

        assistantStore.adoptServerProfiles(snapshot.profiles)
        verifiedRouteNamesByID = Dictionary(uniqueKeysWithValues:
            snapshot.profiles.map { ($0.id, $0.routeName) })
        lastProfileRefresh = Date()
        routeIsolationEnabled = true
    }

    private func refreshServerProfiles(force: Bool = false) async {
        guard routeIsolationEnabled, let endpoint, let token else { return }
        if !force, let lastProfileRefresh,
           Date().timeIntervalSince(lastProfileRefresh) < 12 { return }
        lastProfileRefresh = Date()
        guard let snapshot = try? await client.assistantProfiles(endpoint: endpoint, token: token) else { return }
        guard routeIsolationEnabled else { return }
        let ids = Set(snapshot.profiles.map(\.id))
        guard ids.count == snapshot.profiles.count else { return }
        assistantStore.adoptServerProfiles(snapshot.profiles)
        verifiedRouteNamesByID = Dictionary(uniqueKeysWithValues:
            snapshot.profiles.map { ($0.id, $0.routeName) })
        if let selected = selectedAssistantID,
           assistantStore.serverProfile(id: selected)?.deleted == true {
            selectAssistant(nil)
        }
    }

    static let unclassifiedHistoryID = "unresolved-assistants"

    private func isKnownConversation(_ id: String) -> Bool {
        assistantStore.assistants.contains(where: { $0.id == id }) ||
            verifiedRouteNamesByID[id] != nil
    }

    private func visibleIdentity(for message: MessagePayload) -> String? {
        guard let id = assistantStore.conversationID(for: message) else { return nil }
        if id == "legacy-unclassified" || id.hasPrefix("unresolved:") ||
           !isKnownConversation(id) {
            return Self.unclassifiedHistoryID
        }
        return id
    }

    var hasUnclassifiedHistory: Bool {
        routeIsolationEnabled &&
            messages.contains { visibleIdentity(for: $0) == Self.unclassifiedHistoryID }
    }

    func conversationIDForJump(_ message: MessagePayload) -> String? {
        visibleIdentity(for: message)
    }
    private(set) var unreadAssistantIDs: Set<String> = []

    /// Route requested by a tapped notification; consumed by the timeline once
    /// it is on screen (a cold start applies it as soon as it connects).
    private(set) var pendingRoute: NotificationRoute?

    /// Re-anchor token bumped whenever something wants the timeline to scroll to
    /// the newest message (e.g. the album picker finishing a send). The timeline
    /// observes changes and re-anchors to the bottom, so the newest message is
    /// shown even when the user had scrolled up before sending.
    private(set) var scrollToBottomToken = UUID()
    func requestScrollToBottom() { scrollToBottomToken = UUID() }

    /// Number of messages that arrived while their conversation was not on
    /// screen — the app icon badge value.
    var unreadCount: Int { unreadMessageIDs.count }

    let uploader = Uploader()
    let localStore: LocalDataStore
    let catalog = CommandCatalogStore()
    let assistantStore = AssistantStore()
    let avatarStore = AssistantAvatarStore()
    let notificationSettings = NotificationSettings.shared
    /// 待查看 (T9): items parsed out of incoming messages + local 已看 state.
    let reviewStore: ReviewStore

    private let notifier = MessageNotifier.shared
    private let client: any FerryServicing
    private let credentials: CredentialStoring
    private let defaults: UserDefaults
    private(set) var endpoint: ServerEndpoint?
    private(set) var token: String?
    /// The Ferry space the phone-local caches are currently pointed at.
    private(set) var spaceKey: SpaceKey?
    private var cursor: Int64 = 0
    /// Deletion-change-log cursor (GET /api/v1/changes?since=…).
    private var changeCursor: Int64 = 0
    /// Custom-assistant names seen in the last server assistant-state snapshot,
    /// used to detect assistants deleted on another device.
    private var knownServerAssistantNames: Set<String> = []
    /// Deletions made on this phone while offline, awaiting a server flush.
    private var outbox: [PendingDeletion] = []
    private var isFlushingOutbox = false
    private static let outboxPrefix = "ferry.outbox."
    /// Dedicated per-space action log for both starring and unstarring.
    private var favoriteActions: [PendingFavoriteAction] = []
    private var isFlushingFavoriteActions = false
    private var isRefreshingFavorites = false
    private var lastFavoritesFetch: Date?
    private static let favoritesQueuePrefix = "ferry.pendingFavorites."
    private static let favoritesMigrationPrefix = "ferry.favoritesMigrationV2."
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
    /// origin → space-key value mapping, persisted at join time so a reconnect
    /// (which has a token but not the password) can restore the same space.
    private static let spaceKeysKey = "ferry.spaceKeys"
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
        reviewStore = ReviewStore(defaults: defaults)
        uploader.destinationProvider = { [weak self] in self?.destinationForSelection() }
        uploader.routingEnabled = { [weak self] in self?.routeIsolationEnabled == true }
        uploader.onCreated = { [weak self] message in self?.append(message) }
        uploader.onUnauthorized = { [weak self] in self?.handleUnauthorized() }
        notifier.onRoute = { [weak self] route in self?.apply(notificationRoute: route) }
    }

    var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var imageMessages: [MessagePayload] {
        let pool = routeIsolationEnabled ? visibleMessages : messages
        return pool.filter { $0.file.map { PreviewRouter.isImage($0) } ?? false }
    }

    /// Every loaded image + video message (non-hidden), for the media gallery.
    var mediaMessages: [MessagePayload] {
        let pool = routeIsolationEnabled ? visibleMessages : messages
        return pool.filter {
            guard let file = $0.file else { return false }
            return PreviewRouter.isImage(file) || PreviewRouter.isVideo(file)
        }
    }

    /// Messages shown in the timeline, after applying the active assistant
    /// filter (nil = 全部, everything).
    var visibleMessages: [MessagePayload] {
        if routeIsolationEnabled {
            return messages.filter { visibleIdentity(for: $0) == selectedAssistantID }
        }
        guard let selectedAssistantID else { return messages }
        return messages.filter { assistantStore.assistant(for: $0)?.id == selectedAssistantID }
    }

    /// The pinned 待查看 row belongs to the 总管 page and disappears once
    /// everything in it has been marked 已看.
    var showsReviewEntry: Bool {
        selectedAssistantID == ReviewPlacement.chiefAssistantID && reviewStore.unseenCount > 0
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
            let space = SpaceKey(origin: endpoint.origin, password: accessPassword)
            rememberSpace(space, for: endpoint.origin)
            activate(space: space)
            accessPassword = ""
            phase = .connected
            uploader.configure(endpoint: endpoint, token: claim.token)
            await configureVerifiedRouting(generation: current)
            await loadInitial(generation: current)
            await reconcile(generation: current)
            startPolling()
            refreshCommandCatalog()
        } catch { handle(error, generation: current) }
    }

    /// Point all phone-local caches (favorites, hidden ids, custom assistants,
    /// avatars, video thumbnails) at one Ferry space, isolating data from
    /// different servers / access passwords. The chat transcript itself is
    /// already server-authoritative: it is held in memory and re-fetched on
    /// every launch.
    private func activate(space: SpaceKey) {
        spaceKey = space
        localStore.activate(space: space)
        assistantStore.activate(space: space)
        avatarStore.activate(space: space)
        VideoThumbnailCache.setSpace(space)
        loadOutbox()
        loadFavoriteActions()
        lastFavoritesFetch = nil
    }

    /// Resolve the space for an origin on reconnect (token-only, no password).
    private func space(for origin: String) -> SpaceKey {
        if let stored = storedSpaceValue(for: origin), !stored.isEmpty {
            return SpaceKey(value: stored)
        }
        return SpaceKey(origin: origin, password: "")
    }

    private func rememberSpace(_ space: SpaceKey, for origin: String) {
        var mapping = storedSpaceValues()
        mapping[origin] = space.value
        defaults.set(mapping, forKey: Self.spaceKeysKey)
    }

    private func storedSpaceValues() -> [String: String] {
        defaults.dictionary(forKey: Self.spaceKeysKey) as? [String: String] ?? [:]
    }

    private func storedSpaceValue(for origin: String) -> String? {
        storedSpaceValues()[origin]
    }

    // MARK: - Offline deletion outbox

    private var outboxKey: String { Self.outboxPrefix + (spaceKey?.value ?? "") }

    private func loadOutbox() {
        if let data = defaults.data(forKey: outboxKey),
           let decoded = try? JSONDecoder().decode([PendingDeletion].self, from: data) {
            outbox = decoded
        } else {
            outbox = []
        }
    }

    private func persistOutbox() {
        if let data = try? JSONEncoder().encode(outbox) {
            defaults.set(data, forKey: outboxKey)
        } else {
            defaults.removeObject(forKey: outboxKey)
        }
    }

    private var favoriteQueueKey: String {
        Self.favoritesQueuePrefix + (spaceKey?.value ?? "")
    }

    private func loadFavoriteActions() {
        if let data = defaults.data(forKey: favoriteQueueKey),
           let decoded = try? JSONDecoder().decode([PendingFavoriteAction].self, from: data) {
            favoriteActions = decoded
        } else {
            favoriteActions = []
        }
    }

    private func persistFavoriteActions() {
        if let data = try? JSONEncoder().encode(favoriteActions) {
            defaults.set(data, forKey: favoriteQueueKey)
        }
    }

    /// Pre-existing phone-only stars are imported just once, at a deliberately
    /// OLD timestamp. Newer server tombstones always win, so upgrading the
    /// app cannot resurrect a favorite removed earlier on Windows.
    private func migratePhoneFavoritesOnce() {
        guard let spaceKey else { return }
        let key = Self.favoritesMigrationPrefix + spaceKey.value
        guard !defaults.bool(forKey: key) else { return }
        for favorite in localStore.favorites
            where favorite.id.count == 32 &&
                favorite.id.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) ||
                                             ($0 >= 97 && $0 <= 102) ||
                                             ($0 >= 65 && $0 <= 70) }) {
            let record = favoriteRecord(from: favorite, at: 1)
            queueFavoriteAction(PendingFavoriteAction(kind: .add,
                messageID: favorite.id, opAt: 1, record: record), flush: false)
        }
        // Queue is persisted before declaring migration complete.
        defaults.set(true, forKey: key)
    }

    private func queueFavoriteAction(_ action: PendingFavoriteAction, flush: Bool = true) {
        // Keep at most the most recent locally queued action per message.
        // An already in-flight earlier action is safe: the Go server compares
        // timestamps, and a later action eventually wins.
        favoriteActions.removeAll { $0.messageID == action.messageID }
        favoriteActions.append(action)
        persistFavoriteActions()
        if flush { Task { await flushFavoriteActions() } }
    }

    private func flushFavoriteActions() async {
        guard !isFlushingFavoriteActions, !favoriteActions.isEmpty,
              let endpoint, let token else { return }
        isFlushingFavoriteActions = true
        let current = generation
        defer { isFlushingFavoriteActions = false }
        while current == generation, !favoriteActions.isEmpty, !Task.isCancelled {
            let action = favoriteActions[0]
            do {
                switch action.kind {
                case .add:
                    guard let record = action.record else { return }
                    _ = try await client.putFavorite(endpoint: endpoint, token: token,
                                                     messageID: action.messageID, record: record)
                case .remove:
                    _ = try await client.deleteFavorite(endpoint: endpoint, token: token,
                                                        messageID: action.messageID, opAt: action.opAt)
                }
                guard current == generation else { return }
                favoriteActions.removeAll { $0.id == action.id }
                persistFavoriteActions()
                lastFavoritesFetch = nil
            } catch {
                // Retain the timestamped action for a later retry.
                return
            }
        }
    }

    /// Queue a deletion made on this phone and try to push it right away.
    private func enqueueDeletion(_ item: PendingDeletion) {
        guard !outbox.contains(where: { $0.id == item.id }) else { return }
        outbox.append(item)
        persistOutbox()
        Task { await flushOutbox() }
    }

    /// Push queued deletions to the server in order. Stops at the first failure
    /// (offline or a server error) so items are retried on the next poll tick;
    /// successful items are dequeued as they are acknowledged.
    private func flushOutbox() async {
        guard !outbox.isEmpty, !isFlushingOutbox, let endpoint, token != nil else { return }
        isFlushingOutbox = true
        defer { isFlushingOutbox = false }
        for item in outbox {
            do {
                try await perform(item)
                outbox.removeAll { $0.id == item.id }
                persistOutbox()
            } catch is CancellationError {
                return
            } catch {
                return // offline / rejected: retry later
            }
        }
    }

    private func perform(_ item: PendingDeletion) async throws {
        guard let endpoint, let token else { throw FerryClient.ClientError.invalidResponse }
        switch item.kind {
        case .messages:
            _ = try await client.deleteMessages(endpoint: endpoint, token: token, ids: item.ids)
        case .clearAll:
            _ = try await client.deleteAllMessages(endpoint: endpoint, token: token)
        case .favorite:
            if let id = item.ids.first {
                // Legacy pre-upgrade outbox entries have no tap timestamp.
                // Treat them as old, not as newly issued cancels that could
                // overwrite a more recent favorite created on Windows.
                _ = try await client.deleteFavorite(endpoint: endpoint, token: token,
                                                    messageID: id, opAt: 1)
            }
        case .assistant:
            // Read-modify-write so the phone's PUT never clobbers the shared
            // selected/reads state another device changed in the meantime.
            let state = try await client.assistantState(endpoint: endpoint, token: token)
            let updated = AssistantStatePayload(selected: state.selected,
                                                reads: state.reads,
                                                custom: state.custom.filter { $0.name != item.name })
            _ = try await client.putAssistantState(endpoint: endpoint, token: token, state: updated)
        }
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
        let sentDraft = draft
        guard await sendText(outgoingText(sentDraft)) else { return }
        if draft == sentDraft { draft = "" }
    }

    /// The text actually sent for a composer draft.
    ///
    /// On an assistant's page the assistant's wake tag is prepended — exactly
    /// what typing `@总管` does. That is the whole "wake" contract: FerryHelper
    /// matches a configured `wakeTag` at the very start of a **text** message
    /// body and forwards it to that assistant, and the web timeline attributes
    /// a message starting with "@name" to that assistant. A draft that already
    /// starts with an "@…" mention is left alone, so an explicit mention (or
    /// the mention picker's own insertion) is never double-tagged.
    func outgoingText(_ draftText: String) -> String {
        // Once route is verified, preserve the user's text verbatim; the
        // assistant target is represented by explicit request fields.
        if routeIsolationEnabled { return draftText }
        guard let selectedAssistantID,
              let assistant = assistantStore.assistants.first(where: { $0.id == selectedAssistantID }) else {
            return draftText
        }
        let body = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return draftText }
        // An explicit leading mention already says where the message should go.
        if body.hasPrefix("@") || body.hasPrefix("＠") { return draftText }
        // Display-only renaming must never alter the Windows helper wake tag.
        let wakeName = assistant.isBuiltIn
            ? (AssistantStore.builtIn.first(where: { $0.id == assistant.id })?.name ?? assistant.name)
            : assistant.name
        return catalog.wakeTag(forAssistantName: wakeName) + " " + body
    }

    /// Send `text` as an ordinary outgoing message; true when the server
    /// accepted it. Shared by the composer (which then clears the draft) and by
    /// the 待查看 reply sheet. On failure `statusMessage` is set, as before.
    @discardableResult
    func sendText(_ text: String, destinationOverride: MessageDestination? = nil) async -> Bool {
        guard let endpoint, let token, !isSending else { return false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let destination = destinationOverride ?? destinationForSelection()
        if routeIsolationEnabled && destination == nil {
            statusMessage = "助手身份尚未同步，取消发送以防消息误归类。"
            return false
        }
        let current = generation
        isSending = true
        defer {
            if current == generation { isSending = false }
        }
        do {
            let message: MessagePayload
            if let destination {
                message = try await client.sendText(endpoint: endpoint, token: token,
                                                    text: text, destination: destination)
            } else {
                message = try await client.sendText(endpoint: endpoint, token: token, text: text)
            }
            guard current == generation else { return false }
            append(message)
            return true
        } catch is CancellationError {
            return false
        } catch let error as URLError where error.code == .cancelled {
            return false
        } catch {
            guard current == generation else { return false }
            if error as? FerryClient.ClientError == .unauthorized {
                handle(error, generation: current)
            } else {
                statusMessage = error.localizedDescription
                if error is URLError || error as? FerryClient.ClientError == .invalidResponse { phase = .offline }
            }
            return false
        }
    }

    /// Run a structured action only in the built-in Helper conversation.
    /// Directory navigation stays out of messages/history; the existing Go
    /// device token is used without prompting the user again.
    func helperOperation(action: String, path: String = "") async throws -> [HelperDirectoryEntry] {
        guard selectedAssistantID == "helper", routeIsolationEnabled,
              let endpoint, let token else {
            throw FerryClient.ClientError.rejected("请先连接支持助手操作的 Ferry Windows 服务。")
        }
        let request = try await client.requestHelperOperation(
            endpoint: endpoint, token: token, action: action, path: path)
        for _ in 0..<90 {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(750))
            let result = try await client.pollHelperOperation(
                endpoint: endpoint, token: token, id: request.id)
            if result.status == "done" { return result.entries ?? [] }
            if result.status == "failed" {
                throw FerryClient.ClientError.rejected(result.error ?? "电脑未完成操作")
            }
        }
        throw FerryClient.ClientError.rejected("电脑助手未响应，请检查 FerryHelper 是否在运行。")
    }

    /// Reply to a 待查看 item: an ordinary message quoting it (see
    /// `ReviewReplyFormatter`). A delivered reply implies the item was read,
    /// so it is marked 已看 here.
    @discardableResult
    func sendReviewReply(_ text: String, for item: ReviewItem) async -> Bool {
        let body = ReviewReplyFormatter.body(for: item, text: text)
        guard await sendText(body) else { return false }
        reviewStore.markSeen(item.id)
        return true
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
        } else if routeIsolationEnabled {
            clearUnreadForVisibleConversation()
        } else {
            unreadAssistantIDs.removeAll()
            clearAllUnread()
        }
    }

    /// Delete a custom assistant (long-press menu on its avatar).
    ///
    /// Only the local grouping goes away — messages are never deleted, they
    /// simply show under 全部 again. Its unread dot and badge count are dropped
    /// while the assistant still resolves, and its custom avatar media is
    /// removed from disk. Falls back to 全部 when it was the active filter.
    func deleteAssistant(id: String) {
        guard !AssistantStore.protectedAssistantIDs.contains(id) else { return }
        if routeIsolationEnabled {
            mutateServerProfile(id: id, changes: ["deleted": "true"])
            return
        }
        if AssistantStore.builtIn.contains(where: { $0.id == id }) {
            assistantStore.deleteBuiltIn(id: id)
            avatarStore.reset(for: id)
            clearUnread(forAssistant: id)
            unreadAssistantIDs.remove(id)
            if selectedAssistantID == id { selectAssistant(nil) }
            return
        }
        let name = assistantStore.custom.first(where: { $0.id == id })?.name
        removeAssistantLocally(id: id)
        if let name {
            enqueueDeletion(PendingDeletion(kind: .assistant, name: name))
        }
    }

    func restoreBuiltInAssistants() {
        if routeIsolationEnabled {
            Task {
                for profile in assistantStore.serverProfiles ?? []
                    where profile.hidden && !profile.deleted {
                    await mutateServerProfileNow(id: profile.id, changes: ["hidden": "false"])
                }
            }
            return
        }
        assistantStore.restoreBuiltIns()
    }

    func hideBuiltInAssistant(id: String) {
        guard !AssistantStore.protectedAssistantIDs.contains(id) else { return }
        if routeIsolationEnabled {
            mutateServerProfile(id: id, changes: ["hidden": "true"])
            return
        }
        assistantStore.hideBuiltIn(id: id)
        if selectedAssistantID == id { selectAssistant(nil) }
    }

    func resetDeletedBuiltInAssistants() {
        if routeIsolationEnabled {
            Task {
                guard let endpoint, let token else { return }
                for profile in assistantStore.serverProfiles ?? [] where profile.deleted {
                    do {
                        _ = try await client.restoreAssistantProfile(endpoint: endpoint, token: token,
                                                                      id: profile.id, revision: profile.revision)
                    } catch {
                        statusMessage = "恢复助手失败：\(error.localizedDescription)"
                    }
                }
                await refreshServerProfiles(force: true)
            }
            return
        }
        assistantStore.resetDeletedBuiltIns()
    }

    func addAssistant(name: String, avatarText: String, colorIndex: Int) {
        if !routeIsolationEnabled {
            _ = assistantStore.addCustom(name: name, avatarText: avatarText, colorIndex: colorIndex)
            return
        }
        Task {
            guard let endpoint, let token else { return }
            do {
                _ = try await client.createAssistantProfile(endpoint: endpoint, token: token,
                                                             displayName: name, avatarText: avatarText,
                                                             colorIndex: colorIndex)
                await refreshServerProfiles(force: true)
            } catch {
                statusMessage = "新建助手失败：\(error.localizedDescription)"
            }
        }
    }

    func updateAssistant(_ assistant: Assistant) {
        if !routeIsolationEnabled {
            assistantStore.update(assistant)
            return
        }
        mutateServerProfile(id: assistant.id, changes: [
            "display_name": assistant.name,
            "avatar_text": assistant.avatarText,
            "color_index": String(assistant.colorIndex)
        ])
    }

    private func mutateServerProfile(id: String, changes: [String: String]) {
        Task { await mutateServerProfileNow(id: id, changes: changes) }
    }

    private func mutateServerProfileNow(id: String, changes: [String: String]) async {
        guard routeIsolationEnabled,
              let profile = assistantStore.serverProfile(id: id),
              let endpoint, let token else { return }
        do {
            _ = try await client.patchAssistantProfile(endpoint: endpoint, token: token,
                                                       id: id, revision: profile.revision,
                                                       changes: changes)
            await refreshServerProfiles(force: true)
            if changes["deleted"] == "true" || changes["hidden"] == "true",
               selectedAssistantID == id { selectAssistant(nil) }
        } catch {
            statusMessage = "助手资料更新失败：\(error.localizedDescription)"
            await refreshServerProfiles(force: true)
        }
    }

    /// Remove one assistant's grouping and avatar from this phone (used both by
    /// the user's own delete action and by server-driven deletions from another
    /// device). Messages are never deleted — they fall back to 全部.
    private func removeAssistantLocally(id: String) {
        clearUnread(forAssistant: id)
        unreadAssistantIDs.remove(id)
        avatarStore.reset(for: id)
        assistantStore.removeCustom(id: id)
        if selectedAssistantID == id { selectAssistant(nil) }
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
        catalog.refresh(endpoint: endpoint, token: token)
    }

    /// Disk cache is separated by Ferry space so identical message IDs from
    /// different server/password pairs never reuse each other's photos.
    private func mediaCacheURL(for message: MessagePayload, ext: String = "img") -> URL? {
        guard let space = spaceKey?.value,
              let root = FileManager.default.urls(for: .cachesDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let key = space + ":" + message.id + ":" + (message.file?.downloadURL ?? "")
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("ferry-media", isDirectory: true)
                   .appendingPathComponent(digest + "." + ext)
    }

    func retryImage(for message: MessagePayload) async {
        images.removeValue(forKey: message.id)
        await loadImage(for: message)
    }

    func loadImage(for message: MessagePayload) async {
        guard let file = message.file, PreviewRouter.isImage(file) else { return }
        guard images[message.id] == nil, !loadingImages.contains(message.id) else { return }
        // Reuse the same original-extension cache for image decoding and sharing.
        let ext = (file.name as NSString).pathExtension.lowercased()
        let cacheURL = mediaCacheURL(for: message, ext: ext.isEmpty ? "jpg" : ext)
        if let cacheURL, let cached = try? Data(contentsOf: cacheURL),
           let image = UIImage(data: cached) {
            images[message.id] = image
            return
        }
        guard let endpoint, let token else { return }
        let current = generation
        loadingImages.insert(message.id)
        defer { loadingImages.remove(message.id) }
        do {
            let data = try await client.attachment(endpoint: endpoint, token: token,
                                                    path: file.downloadURL)
            guard current == generation else { return }
            guard let decoded = UIImage(data: data) else {
                images[message.id] = UIImage?.none
                return
            }
            images[message.id] = decoded
            // Do not cache failed responses or huge files; a valid successful
            // image is kept across ordinary app relaunches.
            if let cacheURL, data.count <= 12_000_000 {
                let directory = cacheURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: directory,
                                                          withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
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
        reviewStore.rebuild(from: messages)
        enqueueDeletion(PendingDeletion(kind: .messages, ids: Array(ids)))
    }

    func clearAllMessages() {
        // The existing API is global, not "clear this transfer thread".
        guard !routeIsolationEnabled else {
            statusMessage = "尚不支持仅清空互传。为防误删其他助手的历史消息，已取消操作。"
            return
        }
        let maxSequence = messages.map(\.sequence).max() ?? 0
        localStore.clearAll(upTo: maxSequence)
        messages.removeAll()
        reviewStore.rebuild(from: messages)
        enqueueDeletion(PendingDeletion(kind: .clearAll))
    }

    func toggleFavorite(_ message: MessagePayload) async {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if localStore.isFavorite(message.id) {
            localStore.removeFavorite(message.id)
            queueFavoriteAction(PendingFavoriteAction(kind: .remove,
                                                      messageID: message.id, opAt: now))
        } else {
            // Show the star and submit the immutable operation immediately.
            // Large attachment downloads must not block server synchronization.
            localStore.addFavorite(message, fileData: nil)
            queueFavoriteAction(PendingFavoriteAction(kind: .add,
                messageID: message.id, opAt: now,
                record: favoriteRecord(from: FavoriteMessage(message: message,
                                                             localFileName: nil), at: now)))
            if message.file != nil {
                let current = generation
                if let data = await fileData(for: message), current == generation {
                    localStore.attachFavoriteFile(message.id, data: data)
                }
            }
        }
    }

    /// Enqueue an image produced by the editor as a new outgoing message.
    /// Returns a Chinese error message on failure, or nil on success. The
    /// original message (when there was one) is left untouched.
    @discardableResult
    func sendEditedImage(_ image: UIImage, originalName: String?,
                         sourceMessage: MessagePayload? = nil) -> String? {
        let ext = ((originalName ?? "") as NSString).pathExtension.lowercased()
        let mediaType = ext == "png" ? "image/png" : "image/jpeg"
        guard let encoded = EditedImageExport.encode(image, originalMediaType: mediaType) else {
            return "编辑后的图片无法导出。"
        }
        let name = EditedImageExport.name(for: originalName ?? "编辑", mime: encoded.mime)
        let originalTarget: MessageDestination?
        if let sourceMessage, routeIsolationEnabled {
            guard let target = destinationForMessage(sourceMessage) else {
                return "原消息所属助手未同步，已取消编辑后发送。"
            }
            originalTarget = target
        } else {
            originalTarget = nil
        }
        return uploader.enqueue(data: encoded.data, name: name, mediaType: encoded.mime,
                                destinationOverride: originalTarget)
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
            // Reuse a downloaded attachment for share/save/preview so opening
            // the system share sheet never downloads the same file twice.
            let ext = (file.name as NSString).pathExtension.lowercased()
            let suffix = ext.isEmpty ? "dat" : ext
            let cacheURL = mediaCacheURL(for: message,
                ext: PreviewRouter.isImage(file) ? suffix : "share." + suffix)
            if let cacheURL, FileManager.default.fileExists(atPath: cacheURL.path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
               (attrs[.size] as? NSNumber)?.int64Value == file.size {
                return cacheURL
            }
            let url = try await client.attachmentFile(endpoint: endpoint, token: token,
                                                      path: file.downloadURL, filename: file.name)
            guard current == generation else { return nil }
            if let cacheURL {
                try? FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: cacheURL)
                try? FileManager.default.copyItem(at: url, to: cacheURL)
                if FileManager.default.fileExists(atPath: cacheURL.path) { return cacheURL }
            }
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
        changeCursor = 0
        knownServerAssistantNames = []
        hasOlder = false
        isLoadingOlder = false
        isLoadingInitial = false
        dayCounts = [:]
        dayCountsByConversation = [:]
        dayIndexStarted = false
        countedMessageIDs = []
        selectedAssistantID = nil
        routeIsolationEnabled = false
        verifiedRouteNamesByID = [:]
        assistantStore.adoptServerProfiles(nil)
        lastProfileRefresh = nil
        lastFavoritesFetch = nil
        favoriteActions = []
        isFlushingFavoriteActions = false
        isRefreshingFavorites = false
        unreadAssistantIDs = []
        unreadMessageIDs = []
        // 已看 state is phone-local and keyed by item id, so it survives a
        // reconnect; only the derived list is dropped.
        reviewStore.rebuild(from: [])
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
            activate(space: space(for: endpoint.origin))
            uploader.configure(endpoint: endpoint, token: token)
            await configureVerifiedRouting(generation: current)
            await loadInitial(generation: current)
            await reconcile(generation: current)
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
                await self?.refreshChanges(generation: current)
                await self?.flushFavoriteActions()
                await self?.refreshFavorites(generation: current)
                await self?.flushOutbox()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refreshMessages(generation current: UUID) async {
        guard current == generation, let endpoint, let token else { return }
        do {
            let page = try await client.messages(endpoint: endpoint, token: token, after: cursor)
            guard current == generation else { return }
            appendBatch(page.messages)
            cursor = page.nextCursor
            phase = .connected
            statusMessage = nil
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch { handle(error, generation: current) }
    }

    /// Poll the server's deletion change log + assistant bar state and apply
    /// deletions made on other devices to the local caches and UI. Best-effort:
    /// a failure here never flips the app offline (the message poll surfaces
    /// connectivity problems), so a transient error just retries next tick.
    private func refreshChanges(generation current: UUID) async {
        guard current == generation, let endpoint, let token else { return }
        do {
            let page = try await client.changes(endpoint: endpoint, token: token, since: changeCursor)
            guard current == generation else { return }
            for change in page.changes { applyChange(change) }
            changeCursor = max(changeCursor, page.revision)
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            // Best-effort: retried on the next poll tick.
        }
        if routeIsolationEnabled {
            await refreshServerProfiles()
            return
        }
        do {
            let state = try await client.assistantState(endpoint: endpoint, token: token)
            guard current == generation else { return }
            applyAssistantState(state)
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            // Best-effort.
        }
    }

    private func applyChange(_ change: Change) {
        switch change.kind {
        case "message":
            if change.itemID == "*" {
                // Clear-all: the server dropped the whole history.
                let maxSequence = messages.map(\.sequence).max() ?? 0
                localStore.clearAll(upTo: maxSequence)
                messages.removeAll()
                images = [:]
                videoThumbnails = [:]
                videoDurations = [:]
                unreadMessageIDs.removeAll()
                reviewStore.rebuild(from: [])
            } else {
                removeMessageLocally(id: change.itemID)
            }
        case "favorite":
            // Change events may have arrived late, after a more recent add.
            // Fetch the current server snapshot instead of blindly clearing
            // a star and its offline file using a stale delete notification.
            lastFavoritesFetch = nil
        default:
            break
        }
    }

    /// Drop one message and every local artifact attached to it (image cache,
    /// video poster, unread badge), so a message deleted on another device
    /// disappears from the timeline and the media gallery.
    private func removeMessageLocally(id: String) {
        messages.removeAll { $0.id == id }
        images.removeValue(forKey: id)
        videoThumbnails.removeValue(forKey: id)
        videoDurations.removeValue(forKey: id)
        unreadMessageIDs.remove(id)
        localStore.hide([id])
        reviewStore.rebuild(from: messages)
    }

    /// Detect custom assistants removed on another device and drop them locally.
    /// Compared against the previous snapshot so assistants that only exist on
    /// this phone (and were never synced) are never deleted by accident.
    private func applyAssistantState(_ state: AssistantStatePayload) {
        let currentNames = Set(state.custom.map(\.name))
        let removed = knownServerAssistantNames.subtracting(currentNames)
        if !removed.isEmpty {
            for name in removed {
                if let assistant = assistantStore.custom.first(where: { $0.name == name }) {
                    removeAssistantLocally(id: assistant.id)
                }
            }
        }
        knownServerAssistantNames = currentNames
    }

    /// One-time reconcile after launch/reconnect: pull the authoritative lists
    /// (favorites, assistants) and prune local caches for anything another
    /// device removed, then advance the deletion-log cursor past history.
    private func reconcile(generation current: UUID) async {
        guard current == generation, let endpoint, let token else { return }
        migratePhoneFavoritesOnce()
        await flushFavoriteActions()
        await refreshFavorites(generation: current, force: true)
        if routeIsolationEnabled {
            await refreshServerProfiles(force: true)
        } else if let state = try? await client.assistantState(endpoint: endpoint, token: token) {
            await adoptServerAssistants(state)
        }
        if let page = try? await client.changes(endpoint: endpoint, token: token, since: 0) {
            changeCursor = max(changeCursor, page.revision)
        }
    }

    /// The server is authoritative. Local queued actions alone are exempt
    /// until the corresponding PUT/DELETE has completed successfully.
    private func refreshFavorites(generation current: UUID, force: Bool = false) async {
        guard current == generation, let endpoint, let token, !isRefreshingFavorites else { return }
        if !force, let previous = lastFavoritesFetch,
           Date().timeIntervalSince(previous) < 3 { return }
        isRefreshingFavorites = true
        defer { isRefreshingFavorites = false }
        do {
            let payload = try await client.favorites(endpoint: endpoint, token: token)
            guard current == generation else { return }
            let serverIDs = Set(payload.favorites.map(\.id))
            let pendingIDs = Set(favoriteActions.map(\.messageID))
            for local in localStore.favorites
                where !serverIDs.contains(local.id) && !pendingIDs.contains(local.id) {
                localStore.removeFavorite(local.id)
            }
            for server in payload.favorites
                where !pendingIDs.contains(server.id) && !localStore.isFavorite(server.id) {
                localStore.addFavorite(messagePayload(from: server), fileData: nil)
            }
            lastFavoritesFetch = Date()
        } catch {
            // Keep the last visible snapshot, and retry on the next poll.
        }
    }

    private func favoriteRecord(from local: FavoriteMessage, at opAt: Int64) -> FavoriteRecord {
        let message = local.message
        let isFile = message.kind == .file
        return FavoriteRecord(id: message.id,
                              kind: isFile ? "file" : "text",
                              fileKind: Self.fileKind(forMediaType: message.file?.mediaType ?? ""),
                              fileName: message.file?.name ?? "",
                              text: message.text ?? "",
                              sender: message.senderName,
                              senderKind: message.senderKind,
                              createdAt: message.createdAt,
                              favoritedAt: opAt)
    }

    private func messagePayload(from server: ServerFavorite) -> MessagePayload {
        let file: FileInfo?
        if server.kind == "file" {
            file = FileInfo(name: server.fileName,
                            mediaType: Self.mediaType(forFileKind: server.fileKind),
                            size: 0,
                            downloadURL: "/api/v1/files/\(server.id)")
        } else {
            file = nil
        }
        return MessagePayload(id: server.id,
                              sequence: 0,
                              kind: server.kind == "file" ? .file : .text,
                              senderName: server.sender,
                              senderKind: server.senderKind,
                              isCurrentDevice: false,
                              createdAt: server.createdAt,
                              text: server.kind == "text" ? server.text : nil,
                              file: file)
    }

    private static func fileKind(forMediaType mediaType: String) -> String {
        if mediaType.hasPrefix("image/") { return "image" }
        if mediaType.hasPrefix("video/") { return "video" }
        if mediaType == "application/pdf" { return "pdf" }
        if mediaType.hasPrefix("text/") { return "text" }
        return "file"
    }

    private static func mediaType(forFileKind kind: String) -> String {
        switch kind {
        case "image": return "image/jpeg"
        case "video": return "video/mp4"
        case "pdf": return "application/pdf"
        case "text": return "text/plain"
        default: return "application/octet-stream"
        }
    }

    /// Make the phone's custom assistants server-authoritative: merge any
    /// local-only assistant onto the server (so nothing is lost), then adopt
    /// the server list — which drops assistants deleted on another device.
    private func adoptServerAssistants(_ state: AssistantStatePayload) async {
        let serverNames = Set(state.custom.map(\.name))
        let localOnly = assistantStore.custom.filter { !serverNames.contains($0.name) }
        var merged = state.custom
        if !localOnly.isEmpty {
            merged.append(contentsOf: localOnly.map {
                ServerCustomAssistant(name: $0.name, avatarText: $0.avatarText, colorIndex: $0.colorIndex)
            })
            if let endpoint, let token {
                let updated = AssistantStatePayload(selected: state.selected, reads: state.reads, custom: merged)
                if let pushed = try? await client.putAssistantState(endpoint: endpoint, token: token, state: updated) {
                    merged = pushed.custom
                }
            }
        }
        var byName: [String: Assistant] = [:]
        for assistant in assistantStore.custom { byName[assistant.name] = assistant }
        let adopted = merged.map { server -> Assistant in
            if let existing = byName[server.name] { return existing }
            return Assistant(id: "server-" + server.name, name: server.name,
                             avatarText: server.avatarText ?? "",
                             colorIndex: server.colorIndex ?? 0,
                             isBuiltIn: false, matchKeywords: [server.name])
        }
        let adoptedNames = Set(merged.map(\.name))
        for assistant in assistantStore.custom where !adoptedNames.contains(assistant.name) {
            avatarStore.reset(for: assistant.id)
        }
        assistantStore.replaceCustom(with: adopted)
        knownServerAssistantNames = Set(adopted.map(\.name))
        if let selected = selectedAssistantID,
           !assistantStore.assistants.contains(where: { $0.id == selected }) {
            selectedAssistantID = nil
        }
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
        dayCountsByConversation = [:]
        countedMessageIDs = []
        countDays(messages)
        reviewStore.rebuild(from: messages)
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
        reviewStore.rebuild(from: messages)
        cursor = max(cursor, visible.map(\.sequence).max() ?? cursor)
    }

    /// Calendar markers use the active conversation in verified routing mode.
    var visibleDayCounts: [String: Int] {
        guard routeIsolationEnabled else { return dayCounts }
        return dayCountsByConversation[selectedAssistantID ?? "__transfer__"] ?? [:]
    }

    private func countDays(_ msgs: [MessagePayload]) {
        for message in msgs where !countedMessageIDs.contains(message.id) {
            countedMessageIDs.insert(message.id)
            guard let date = TimestampFormat.date(from: message.createdAt) else { continue }
            let key = DayKey.string(from: Calendar.current.startOfDay(for: date))
            dayCounts[key, default: 0] += 1
            if routeIsolationEnabled {
                let identity = visibleIdentity(for: message) ?? "__transfer__"
                dayCountsByConversation[identity, default: [:]][key, default: 0] += 1
            }
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

        if let hit = visibleMessages.first(where: { Self.messageDayKey($0) == targetKey }) {
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
            if let hit = visibleMessages.first(where: { Self.messageDayKey($0) == targetKey }) {
                return .found(hit.id)
            }
        }
        if Task.isCancelled { return .cancelled }
        if let hit = visibleMessages.first(where: { Self.messageDayKey($0) == targetKey }) {
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
    /// Load an older favorited message before jumping across conversations.
    /// No server-side mutation; preserve the existing global pagination cursor.
    func ensureMessageLoaded(id: String) async -> Bool {
        if messages.contains(where: { $0.id == id }) { return true }
        var count = 0
        while hasOlder && count < Self.maxHistoryPages && !Task.isCancelled {
            guard await loadOlder() else { break }
            count += 1
            if messages.contains(where: { $0.id == id }) { return true }
        }
        return false
    }

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

    /// Coalesce a network page into a single sort and observation update.
    private func appendBatch(_ incoming: [MessagePayload]) {
        guard !incoming.isEmpty else { return }
        var knownIDs = Set(messages.map(\.id))
        let fresh = incoming.filter {
            !localStore.isHidden($0) && knownIDs.insert($0.id).inserted
        }
        guard !fresh.isEmpty else { return }
        messages.append(contentsOf: fresh)
        messages.sort { $0.sequence < $1.sequence }
        cursor = max(cursor, fresh.map(\.sequence).max() ?? cursor)
        countDays(fresh)
        for message in fresh {
            reviewStore.ingest(message: message)
            markUnreadIfNeeded(message)
            registerIncoming(message)
        }
    }

    private func append(_ message: MessagePayload) {
        appendBatch([message])
    }

    /// A newly arrived assistant message is "unseen" only while a *different*
    /// assistant is being filtered. Viewing 全部 or that assistant itself
    /// counts as seen, so no red dot is raised in those cases. Outgoing
    /// messages never raise a dot — including the ones addressed to an
    /// assistant with a wake tag.
    private func markUnreadIfNeeded(_ message: MessagePayload) {
        guard !message.isCurrentDevice else { return }
        if routeIsolationEnabled {
            if let id = visibleIdentity(for: message), id != selectedAssistantID {
                unreadAssistantIDs.insert(id)
            }
            return
        }
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
        guard !isConversationVisible(message) else { return }
        guard message.sequence > notificationSettings.lastNotifiedSequence else { return }
        notificationSettings.lastNotifiedSequence = message.sequence
        unreadMessageIDs.insert(message.id)
        updateBadge()
        Task { await notifier.notify(message: message, assistant: assistant) }
    }

    /// Whether the message's conversation is on screen right now.
    private func isConversationVisible(_ message: MessagePayload) -> Bool {
        guard isActive, phase == .connected || phase == .offline else { return false }
        if routeIsolationEnabled {
            return visibleIdentity(for: message) == selectedAssistantID
        }
        guard let selectedAssistantID else { return true }
        return assistantStore.assistant(for: message)?.id == selectedAssistantID
    }

    private func markVisibleAsRead() {
        if routeIsolationEnabled { clearUnreadForVisibleConversation() }
        else if let selectedAssistantID { clearUnread(forAssistant: selectedAssistantID) }
        else { clearAllUnread() }
    }

    private func clearUnreadForVisibleConversation() {
        unreadMessageIDs = unreadMessageIDs.filter { id in
            guard let message = messages.first(where: { $0.id == id }) else { return true }
            return visibleIdentity(for: message) != selectedAssistantID
        }
        updateBadge()
    }

    private func clearUnread(forAssistant id: String) {
        guard !unreadMessageIDs.isEmpty else { return }
        unreadMessageIDs = unreadMessageIDs.filter { messageID in
            guard let message = messages.first(where: { $0.id == messageID }) else { return true }
            if routeIsolationEnabled { return visibleIdentity(for: message) != id }
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
        // Two 待查看 samples — one per wire format — so the T9 list can be
        // exercised without a server (launch with "-uiTestMock").
        let reviewJSON = """
        {"review":{"id":"mock-review-package","kind":"package","title":"Ferry iOS build 13 待测","summary":"装上去过一遍待查看区","detail":"1. 打开总管页\\n2. 点开待查看\\n3. 标已看 / 回复"}}
        """
        let reviewJSONMessage = MessagePayload(id: "mock-review-json", sequence: 4, kind: .text,
                                               senderName: "总管", senderKind: "mac",
                                               isCurrentDevice: false, createdAt: createdAt,
                                               text: reviewJSON, file: nil)
        let reviewText = """
        [待查看:daily] 今日日报
        今天完成 2 项，等你确认 1 项。
        明细：待查看区已上线（mock 数据）。
        """
        let reviewTextMessage = MessagePayload(id: "mock-review-text", sequence: 5, kind: .text,
                                               senderName: "总管", senderKind: "mac",
                                               isCurrentDevice: false, createdAt: createdAt,
                                               text: reviewText, file: nil)
        messages = [text, image, video, reviewJSONMessage, reviewTextMessage]
        images["mock-image"] = makeMockImage()
        videoThumbnails["mock-video"] = makeMockImage()
        videoDurations["mock-video"] = 5.0
        countDays(messages)
        reviewStore.rebuild(from: messages)
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
