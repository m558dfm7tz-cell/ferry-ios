import SwiftUI
import UIKit

struct TimelineView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var composerFocused: Bool
    @State private var showFavorites = false
    @State private var showDateJump = false
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showDeviceManagement = false
    @State private var showMediaGallery = false
    @State private var showNewAssistant = false
    @State private var showReviewList = false
    @State private var galleryInitialID: String?
    @State private var atBottom = true
    @State private var isFollowingTail = true
    @State private var transcriptUserDragging = false
    @State private var showAttachmentPanel = false
    @State private var showAlbumPicker = false
    @State private var selectionMode = false
    @State private var selectedIDs: Set<String> = []
    @State private var selectionAlert: SelectionAlert?
    @State private var pendingScroll: PendingScroll?
    @State private var didInitialScroll = false
    @State private var showNewPill = false
    /// Message a date/search jump landed on. It keeps a top gap (see
    /// `jumpTopInset`) so the row sits below the floating bar, and it is the
    /// row the highlight flash is drawn on.
    @State private var jumpTargetID: String?
    /// Bright phase of the jump-to-message flash.
    @State private var highlightOn = false
    @State private var toastText = ""
    @State private var showToast = false
    /// The in-flight keyboard-follow scroll, so a second `keyboardWillShow`
    /// (which also fires when the keyboard only *changes*) cannot stack two
    /// overlapping re-anchors on top of each other.
    @State private var keyboardFollowTask: Task<Void, Never>?
    @State private var jumpTask: Task<Void, Never>?
    @State private var jumpHoldingID: String?
    @State private var keyboardVisible = false
    @State private var keyboardWasAtBottom = false
    @State private var followMediaMessageID: String?

    private static let bottomAnchorID = "timeline-bottom"

    /// Keyboard-appearance notifications, used to keep the newest message
    /// visible above the composer (see `followKeyboard(_:)`).
    private let keyboardWillShowPublisher = NotificationCenter.default
        .publisher(for: UIResponder.keyboardWillShowNotification)
    private let keyboardWillHidePublisher = NotificationCenter.default
        .publisher(for: UIResponder.keyboardWillHideNotification)

    /// A scroll request. The `nonce` makes every request unique so the same
    /// message id can be scrolled to more than once (date jump, re-anchor).
    private struct PendingScroll: Equatable {
        let id: String
        let anchor: UnitPoint
        let nonce = UUID()
    }

    private enum SelectionAlert: String, Identifiable {
        case delete, clearAll
        var id: String { rawValue }
        var title: String {
            switch self {
            case .delete: return "删除消息"
            case .clearAll: return "清空全部"
            }
        }
    }

    private var selectionAlertBinding: Binding<Bool> {
        Binding(get: { selectionAlert != nil }, set: { if !$0 { selectionAlert = nil } })
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                transcriptView
                VStack(spacing: 0) {
                    AssistantBarView(assistants: model.assistantStore.assistants,
                                     allowCustomHide: model.routeIsolationEnabled,
                                     transferMode: model.routeIsolationEnabled,
                                     showUnclassifiedHistory: model.hasUnclassifiedHistory,
                                     selectedID: $model.selectedAssistantID,
                                     unreadIDs: model.unreadAssistantIDs,
                                     avatarStore: model.avatarStore,
                                     onSelect: { model.selectAssistant($0) },
                                     onAdd: { showNewAssistant = true },
                                     onUpdate: { model.updateAssistant($0) },
                                     onDelete: { model.deleteAssistant(id: $0) },
                                     onHide: { model.hideBuiltInAssistant(id: $0) },
                                     canRestoreDeletedBuiltIns: model.routeIsolationEnabled
                                         ? model.assistantStore.hasDeletedServerProfiles
                                         : !model.assistantStore.deletedBuiltInIDs.isEmpty,
                                     onRestoreDeletedBuiltIns: { model.resetDeletedBuiltInAssistants() },
                                     canRestoreBuiltIns: model.routeIsolationEnabled
                                         ? model.assistantStore.hasHiddenServerProfiles
                                         : !model.assistantStore.hiddenBuiltInIDs.isEmpty,
                                     onRestoreBuiltIns: { model.restoreBuiltInAssistants() })
                    if model.showsReviewEntry {
                        ReviewEntryRow(count: model.reviewStore.unseenCount) {
                            showReviewList = true
                        }
                    }
                }
            }
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selectionMode {
                    SelectionBar(canClearAll: !model.routeIsolationEnabled,
                                 onClearAll: { selectionAlert = .clearAll })
                } else {
                    ComposerView(model: model, focused: $composerFocused,
                                 showImagePicker: $showAlbumPicker,
                                 showPlus: $showAttachmentPanel)
                }
            }
            .background(Color.chatBackground.ignoresSafeArea(edges: .bottom))
        }
        .sheet(isPresented: $showSearch) {
            SearchView(model: model, onSelect: { id in jumpToMessage(id) })
        }
        .sheet(isPresented: $showFavorites) {
            FavoritesView(model: model, onLocate: { id in jumpToMessage(id) })
        }
        .sheet(isPresented: $showDateJump) {
            DateJumpSheet(model: model,
                          onJump: { id in jumpToMessage(id) },
                          onEmpty: { flashToastAfterDismiss("当天没有消息") })
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $showDeviceManagement) {
            NavigationStack {
                DeviceManagementView(model: model)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { Button("关闭") { showDeviceManagement = false } }
                    }
            }
        }
        .fullScreenCover(isPresented: $showMediaGallery) {
            MediaGalleryView(model: model, initialMessageID: galleryInitialID)
        }
        .sheet(isPresented: $showNewAssistant) {
            NewAssistantSheet { name, avatarText, colorIndex in
                model.addAssistant(name: name, avatarText: avatarText, colorIndex: colorIndex)
            }
        }
        .sheet(isPresented: $showReviewList) {
            ReviewListView(model: model)
        }
        .onAppear { applyPendingRoute() }
        .onChange(of: model.pendingRoute) { _, route in
            guard route != nil else { return }
            applyPendingRoute()
        }
        .alert(selectionAlert?.title ?? "", isPresented: selectionAlertBinding, presenting: selectionAlert) { alert in
            switch alert {
            case .delete:
                Button("删除", role: .destructive) {
                    model.deleteSelected(selectedIDs)
                    exitSelection()
                }
                Button("取消", role: .cancel) {}
            case .clearAll:
                Button("清空全部", role: .destructive) {
                    model.clearAllMessages()
                    exitSelection()
                }
                Button("取消", role: .cancel) {}
            }
        } message: { alert in
            switch alert {
            case .delete:
                Text("确定从本机删除选中的 \(selectedIDs.count) 条消息吗？其他设备仍会保留这些消息。")
            case .clearAll:
                Text("确定清空本机全部消息吗？此操作仅在本机隐藏，不会删除服务器上的消息。")
            }
        }
        .overlay {
            if showAlbumPicker {
                AlbumPickerView(model: model, onClose: {
                    showAlbumPicker = false
                })
                .ignoresSafeArea()
                .zIndex(10)
            }
        }
        .overlay { if showToast { toastView } }

    }

    /// Split the lazy row hierarchy and scroll modifiers into smaller view
    /// expressions to keep Xcode's SwiftUI type-checker tractable.
    private var transcriptContents: some View {
                        LazyVStack(spacing: 18) {
                            if !model.visibleMessages.isEmpty { topLoader }
                            if model.visibleMessages.isEmpty {
                                if model.selectedAssistantID != nil {
                                    ContentUnavailableView("该助手暂无消息", systemImage: "person.crop.circle.badge.questionmark",
                                                           description: Text("这位助手还没有发过消息。"))
                                        .padding(.top, 100)
                                } else {
                                    ContentUnavailableView("等待传输", systemImage: "shippingbox",
                                                           description: Text("来自电脑的消息和文件会显示在这里。"))
                                        .padding(.top, 100)
                                }
                            }
                        ForEach(model.daySections) { section in
                            Text(section.dayLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 6)
                            ForEach(section.messages) { message in
                                MessageRow(message: message,
                                           image: model.images[message.id],
                                           videoThumbnail: model.videoThumbnails[message.id],
                                           videoDuration: model.videoDurations[message.id] ?? 0,
                                           loadImage: {
                                                if case .some(.none) = model.images[message.id] {
                                                    await model.retryImage(for: message)
                                                } else {
                                                    await model.loadImage(for: message)
                                                }
                                           },
                                           loadVideoThumbnail: { await model.loadVideoThumbnail(for: message) },
                                           loadFile: { await model.fileData(for: message) },
                                           loadFileURL: { await model.fileURL(for: message) },
                                           isCurrent: message.isCurrentDevice,
                                           isFavorite: model.localStore.isFavorite(message.id),
                                           onToggleFavorite: { await model.toggleFavorite(message) },
                                           copyTemporaryLink: { await model.copyTemporaryLink(for: message) },
                                           onOpenGallery: { openMediaGallery(message.id) },
                                           onSendEditedImage: { image in sendEditedImage(image, sourceMessage: message) },
                                           selectionMode: selectionMode,
                                           isSelected: selectedIDs.contains(message.id),
                                           isHighlighted: jumpTargetID == message.id,
                                           highlightOn: highlightOn,
                                           onToggleSelection: { toggleSelection(message.id) },
                                           assistant: model.assistantStore.assistant(for: message),
                                           assistantMedia: avatarMedia(for: message))
                                    // Reserve the floating bar's height above
                                    // the row a jump landed on, so anchoring
                                    // the row to the top of the scroll view
                                    // leaves it just below the bar.
                                    // Jump positioning is a scroll anchor, not
                                    // permanent padding on the target message.
                                    .contentShape(Rectangle())
                                    .id(message.id)
                            }
                        }
                        // Invisible bottom anchor: scrolling to this reaches the
                        // true bottom regardless of LazyVStack content heights.
                        Color.clear.frame(height: 1).id(Self.bottomAnchorID)
                    }

    }

    private var transcriptView: some View {
                ScrollViewReader { proxy in
                    let baseTranscript = ScrollView {
                        transcriptContents
                    // Extra top inset so the transcript scrolls *under* the
                    // floating (background-less) assistant bar and shows through
                    // it, instead of being permanently hidden behind it.
                    .padding(.horizontal, 18)
                    .padding(.bottom, 20)
                    // Reserve room for the floating avatar bar and, when it is
                    // showing, the pinned 待查看 row underneath it.
                    .padding(.top, 20 + AssistantBarMetrics.height
                             + (model.showsReviewEntry ? ReviewEntryMetrics.height : 0))
                    .contentShape(Rectangle())
                    .onTapGesture { dismissKeyboard() }
                }
                let messageObserved = baseTranscript
                    .defaultScrollAnchor(.bottom)
                .onChange(of: pendingScroll) { _, request in
                    guard let request else { return }
                    proxy.scrollTo(request.id, anchor: request.anchor)
                }
                .onChange(of: model.messages.first?.id) { oldFirst, newFirst in
                    // Older page prepended: keep the previous first message at
                    // the top so the content does not visually jump.
                    guard jumpHoldingID == nil, didInitialScroll,
                          let oldFirst, oldFirst != newFirst else { return }
                    pendingScroll = PendingScroll(id: oldFirst, anchor: .top)
                }
                .onChange(of: model.visibleMessages.last?.id) { _, newLast in
                    guard newLast != nil, jumpHoldingID == nil else { return }
                    if !didInitialScroll {
                        didInitialScroll = true
                        scrollToBottomAnchor()
                        return
                    }
                    // The last cell loading can temporarily make geometry say
                    // !atBottom without a single user scroll. Track user
                    // intention separately so *every* new photo follows.
                    if isFollowingTail {
                        scrollToBottomAnchor()
                    } else {
                        withAnimation { showNewPill = true }
                    }
                }
                .onChange(of: model.selectedAssistantID) { _, _ in
                    guard jumpHoldingID == nil else { return }
                    clearJumpTarget()
                    isFollowingTail = true
                    scrollToBottomAnchor()
                }
                .onChange(of: model.scrollToBottomToken) { _, _ in
                    guard jumpHoldingID == nil else { return }
                    isFollowingTail = true
                    scrollToBottomAnchor()
                }
                let mediaObserved = messageObserved
                    .onChange(of: model.images.count) { _, _ in
                    followPendingMediaLoad()
                }
                .onChange(of: model.videoThumbnails.count) { _, _ in
                    followPendingMediaLoad()
                }
                .onChange(of: scenePhase) { _, phase in
                    // SwiftUI restores the geometry when the scene returns.
                    // Avoid a second forced re-anchor which caused two bounces.
                    if phase != .active { keyboardFollowTask?.cancel() }
                }
                let geometryObserved = mediaObserved
                    .onScrollGeometryChange(for: ScrollState.self) { geometry in
                    ScrollState(
                        atBottom: geometry.contentOffset.y + geometry.containerSize.height
                            >= geometry.contentSize.height - 120,
                        nearTop: geometry.contentOffset.y < 60
                    )
                } action: { old, state in
                    // The transform above runs on every frame of any scroll and
                    // of the keyboard animation (the visible height changes), so
                    // only write when a value actually flips: an unconditional
                    // @State write re-evaluated the whole body every frame.
                    if state.atBottom != old.atBottom {
                        atBottom = state.atBottom
                        if state.atBottom { showNewPill = false }
                    }
                    // `onReachTop()` used to fire on every frame spent near the
                    // top, spawning a load task each time.
                    if state.nearTop, !old.nearTop { onReachTop() }
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting {
                        // A real user drag takes precedence over a timed jump.
                        if jumpHoldingID != nil {
                            jumpTask?.cancel()
                            jumpHoldingID = nil
                        }
                        transcriptUserDragging = true
                        isFollowingTail = false
                        if keyboardVisible { keyboardWasAtBottom = false }
                    } else if phase == .idle && transcriptUserDragging {
                        transcriptUserDragging = false
                        isFollowingTail = atBottom
                    }
                }
                let keyboardAware = geometryObserved
                    .scrollDismissesKeyboard(.interactively)
                .scrollContentBackground(.hidden)
                .background(Color.chatBackground.ignoresSafeArea())
                // Keyboard follow: see followKeyboard(_:) for the root cause.
                .onReceive(keyboardWillShowPublisher) { note in
                    followKeyboard(note)
                }
                .onReceive(keyboardWillHidePublisher) { note in
                    restoreAfterKeyboard(note)
                }
                keyboardAware.overlay(alignment: .bottomTrailing) {
                    if !atBottom {
                        Button {
                            scrollToBottom()
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 20, weight: .bold))
                                    .frame(width: 52, height: 52)
                                    .background(.black.opacity(0.72), in: Circle())
                                Text(showNewPill ? "有新消息" : "最新消息")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white)
                                    .shadow(radius: 2)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 16).padding(.bottom, 12)
                        .transition(.opacity)
                    }
                }
            }
    }

    /// Connection status icon for the top bar leading slot (tap opens device
    /// management). Green = connected, orange = connecting/offline, red = setup.
    private var connectionIcon: (symbol: String, color: Color) {
        switch model.phase {
        case .connected: return ("wifi", .green)
        case .connecting: return ("dot.radiowaves.left.and.right", .orange)
        case .offline: return ("wifi.exclamationmark", .orange)
        case .setup: return ("wifi.slash", .red)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if selectionMode {
                Button("取消") { exitSelection() }
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            } else {
                Button { showDeviceManagement = true } label: {
                    Image(systemName: connectionIcon.symbol)
                        .foregroundStyle(connectionIcon.color)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("连接状态")
                .accessibilityIdentifier("connection-status")
            }
        }
        ToolbarItem(placement: .principal) {
            Text(selectionMode ? "已选 \(selectedIDs.count) 项" : "Ferry")
                .font(.headline)
        }
        ToolbarItem(placement: .topBarTrailing) {
            if selectionMode {
                Button("删除", role: .destructive) { selectionAlert = .delete }
                    .disabled(selectedIDs.isEmpty)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
                    .accessibilityIdentifier("delete-selected")
            } else {
                HStack(spacing: 4) {
                    Button { showSearch = true } label: {
                        Image(systemName: "magnifyingglass")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("搜索")
                    .accessibilityIdentifier("search-button")

                    Menu {
                        Button { showDateJump = true } label: { Label("跳转到日期", systemImage: "calendar") }
                        Button { showFavorites = true } label: { Label("收藏", systemImage: "star") }
                        Button {
                            galleryInitialID = nil
                            showMediaGallery = true
                        } label: { Label("图片与视频", systemImage: "square.grid.2x2") }
                        Button { enterSelection() } label: { Label("选择", systemImage: "checkmark.circle") }
                        Button { showSettings = true } label: { Label("设置", systemImage: "gearshape") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("更多")
                    .accessibilityIdentifier("more-menu")
                }
            }
        }
    }

    private func openMediaGallery(_ messageID: String) {
        galleryInitialID = messageID
        showMediaGallery = true
    }

    /// Enqueue an image edited from a preview as a new outgoing message.
    private func sendEditedImage(_ image: UIImage, sourceMessage: MessagePayload) {
        if let error = model.sendEditedImage(image, originalName: sourceMessage.file?.name,
                                             sourceMessage: sourceMessage) {
            flashToast(error)
        } else {
            flashToast("已发送编辑后的图片")
        }
    }

    /// Custom avatar media (image / looping video) for the assistant a message
    /// belongs to, or nil for the default letter disc.
    private func avatarMedia(for message: MessagePayload) -> AssistantAvatarMedia? {
        guard let id = model.assistantStore.assistant(for: message)?.id else { return nil }
        return model.avatarStore.media(for: id)
    }

    /// Keep the newest message visible above the composer when the keyboard
    /// comes up.
    ///
    /// Root cause of the bug this fixes: SwiftUI models the keyboard as a bottom
    /// safe-area region, so showing it shrinks the ScrollView's **visible**
    /// height while `contentOffset` stays exactly where it was. The
    /// `.defaultScrollAnchor(.bottom)` above only re-anchors when the **content**
    /// size changes (a new message, or first appearance), so it never fires for
    /// the keyboard; the bottom `keyboardHeight` of the transcript ends up
    /// underneath it. `atBottom` is captured here — before the layout shrinks —
    /// and the re-anchor runs after the keyboard animation so the newest message
    /// lands right above the composer. Someone reading older history is left
    /// where they are.
    private func followKeyboard(_ note: Notification) {
        // A keyboard height-change notification is not another keyboard opening.
        // Scheduling on each one previously caused repeated jumps.
        guard !keyboardVisible else { return }
        keyboardWasAtBottom = isFollowingTail && atBottom
        keyboardVisible = true
        guard keyboardWasAtBottom else { return }
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        keyboardFollowTask?.cancel()
        keyboardFollowTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(duration, 0.1)))
            guard !Task.isCancelled else { return }
            // A single re-anchor on purpose. `scrollToBottomAnchor()` repeats
            // itself 120ms later to catch LazyVStack height changes; during the
            // keyboard animation that second scroll lands while the new layout
            // is still settling and was the main source of the dropped frames.
            guard keyboardVisible, isFollowingTail, !transcriptUserDragging else { return }
            pendingScroll = PendingScroll(id: Self.bottomAnchorID, anchor: .bottom)
        }
    }

    /// A keyboard shrink changes viewport height again; restore the bottom only
    /// if it was being followed before the keyboard appeared.
    private func restoreAfterKeyboard(_ note: Notification) {
        guard keyboardVisible else { return }
        let shouldFollow = keyboardWasAtBottom && isFollowingTail
        keyboardVisible = false
        keyboardWasAtBottom = false
        keyboardFollowTask?.cancel()
        guard shouldFollow else { return }
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        keyboardFollowTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(duration, 0.1) + 0.05))
            guard !Task.isCancelled, isFollowingTail, !transcriptUserDragging,
                  !showAlbumPicker, !showAttachmentPanel, jumpHoldingID == nil else { return }
            pendingScroll = PendingScroll(id: Self.bottomAnchorID, anchor: .bottom)
        }
    }

    /// Dismiss the keyboard when a blank chat area is tapped. The composer is a
    /// UITextView (not a SwiftUI TextField), so clear the focus binding and also
    /// resign the first responder directly via the responder chain.
    private func dismissKeyboard() {
        if showAttachmentPanel {
            withAnimation(.easeOut(duration: 0.18)) { showAttachmentPanel = false }
        }
        composerFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                         to: nil, from: nil, for: nil)
    }

    private var topLoader: some View {
        Group {
            if model.isLoadingOlder {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("加载更早消息…").font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            } else if !model.hasOlder {
                Text("没有更早的消息了").font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
        }
    }

    private var toastView: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
            Text(toastText).foregroundStyle(.white).font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.black.opacity(0.8), in: Capsule())
        .transition(.opacity)
    }

    private func onReachTop() {
        guard !model.isLoadingOlder, model.hasOlder,
              !keyboardVisible, jumpHoldingID == nil else { return }
        Task { await model.loadOlder() }
    }

    private func scrollToBottom() {
        isFollowingTail = true
        showNewPill = false
        scrollToBottomAnchor()
    }

    private func scrollToBottomAnchor() {
        pendingScroll = PendingScroll(id: Self.bottomAnchorID, anchor: .bottom)
        // Do not schedule a second scroll: it used to arrive after another
        // navigation/keyboard gesture and cause the visible bounce.
    }

    private func followPendingMediaLoad() {
        // Lazy image/video sizes may resolve after date/search scrollTo().
        // Re-anchor the jumped row rather than drifting into another message.
        if let id = jumpHoldingID, !transcriptUserDragging {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                guard jumpHoldingID == id, !transcriptUserDragging else { return }
                pendingScroll = PendingScroll(id: id, anchor: .center)
            }
            return
        }
        guard isFollowingTail, !transcriptUserDragging else { return }
        // LazyVStack remeasures an image on the next layout pass. Following
        // every media load (not only the first) fixes consecutive photo sends.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard jumpHoldingID == nil, isFollowingTail, !transcriptUserDragging else { return }
            pendingScroll = PendingScroll(id: Self.bottomAnchorID, anchor: .bottom)
        }
    }

    /// Open the conversation a tapped notification points at: select the
    /// assistant (which also clears its unread badge) and scroll to the message.
    /// Falls back to the newest message when that one is not loaded yet.
    private func applyPendingRoute() {
        guard let route = model.pendingRoute else { return }
        model.consumeNotificationRoute()
        model.selectAssistant(route.assistantID)
        if let messageID = route.messageID,
           model.visibleMessages.contains(where: { $0.id == messageID }) {
            jumpToMessage(messageID)
        } else {
            scrollToBottomAnchor()
        }
    }

    /// Place a date/search target in the middle of the viewport, not under
    /// the floating avatar row. Keep it anchored while its media loads.
    private func jumpToMessage(_ id: String) {
        // A message the active assistant filter hides would silently scroll
        // nowhere (search happily finds messages of every assistant), so move
        // to the page it belongs to — or 全部 when it belongs to none — first.
        let expectedFilter = jumpFilter(for: id)
        jumpTask?.cancel()
        jumpHoldingID = id
        if expectedFilter != model.selectedAssistantID { model.selectAssistant(expectedFilter) }
        isFollowingTail = false
        didInitialScroll = true
        keyboardFollowTask?.cancel()
        jumpTask = Task { @MainActor in
            // Let the date-jump sheet finish dismissing before scrolling.
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            // The user picked another assistant meanwhile: drop the jump.
            guard model.selectedAssistantID == expectedFilter else {
                if jumpHoldingID == id { jumpHoldingID = nil }
                return
            }
            jumpTargetID = id
            highlightOn = true
            // One layout pass for the reserved gap before anchoring to it.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            pendingScroll = PendingScroll(id: id, anchor: .center)
            // One soft highlight rather than an intrusive repeated yellow flash.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, jumpTargetID == id else { return }
            pendingScroll = PendingScroll(id: id, anchor: .center)
            try? await Task.sleep(for: .milliseconds(1250))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { highlightOn = false }
            if jumpHoldingID == id { jumpHoldingID = nil }
        }
    }

    /// The assistant page a jump has to end up on for `id` to be visible: the
    /// current one when the message is already on screen, otherwise the page it
    /// belongs to — or 全部 (nil) when it belongs to no assistant.
    private func jumpFilter(for id: String) -> String? {
        guard !model.visibleMessages.contains(where: { $0.id == id }),
              let message = model.messages.first(where: { $0.id == id }) else {
            return model.selectedAssistantID
        }
        if model.routeIsolationEnabled { return model.conversationIDForJump(message) }
        return model.assistantStore.assistant(for: message)?.id
    }

    /// Forget the row a jump reserved space above (used when the transcript is
    /// rebuilt for another assistant filter). The in-flight jump is left alone
    /// on purpose: it checks the filter itself and bails out, so a filter
    /// change made *by* the jump is not cancelled by its own side effect.
    private func clearJumpTarget() {
        jumpTargetID = nil
        highlightOn = false
    }

    private func flashToastAfterDismiss(_ text: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            flashToast(text)
        }
    }

    private func flashToast(_ text: String) {
        toastText = text
        withAnimation(.easeIn(duration: 0.15)) { showToast = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.15)) { showToast = false }
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    private func enterSelection() {
        selectedIDs = []
        selectionMode = true
    }

    private func exitSelection() {
        selectionMode = false
        selectedIDs = []
    }
}

/// Scroll geometry snapshot for the chat: whether the user is near the bottom
/// (auto-scroll on new messages) and whether they have reached the top
/// (trigger older-page loading).
private struct ScrollState: Hashable {
    let atBottom: Bool
    let nearTop: Bool
}

/// Bottom bar shown while in select mode. 删除 now lives in the top bar, so
/// this keeps only the 清空全部 access (so it is not lost). Confirmation
/// happens in the parent via alerts.
private struct SelectionBar: View {
    let canClearAll: Bool
    let onClearAll: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if canClearAll {
                Button("清空全部", systemImage: "trash") { onClearAll() }
                    .buttonStyle(.bordered)
                    .tint(.red)
            } else {
                Text("可删除所选消息；互传不支持单独清空")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }
}
