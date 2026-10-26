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
    @State private var galleryInitialID: String?
    @State private var atBottom = true
    @State private var selectionMode = false
    @State private var selectedIDs: Set<String> = []
    @State private var selectionAlert: SelectionAlert?
    @State private var pendingScroll: PendingScroll?
    @State private var didInitialScroll = false
    @State private var showNewPill = false
    @State private var highlightedID: String?
    @State private var toastText = ""
    @State private var showToast = false

    private static let bottomAnchorID = "timeline-bottom"

    /// Keyboard-appearance notifications, used to keep the newest message
    /// visible above the composer (see `followKeyboard(_:)`).
    private let keyboardWillShowPublisher = NotificationCenter.default
        .publisher(for: UIResponder.keyboardWillShowNotification)

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
                ScrollViewReader { proxy in
                    ScrollView {
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
                                           loadImage: { await model.loadImage(for: message) },
                                           loadVideoThumbnail: { await model.loadVideoThumbnail(for: message) },
                                           loadFile: { await model.fileData(for: message) },
                                           loadFileURL: { await model.fileURL(for: message) },
                                           isCurrent: message.isCurrentDevice,
                                           isFavorite: model.localStore.isFavorite(message.id),
                                           onToggleFavorite: { await model.toggleFavorite(message) },
                                           copyTemporaryLink: { await model.copyTemporaryLink(for: message) },
                                           onOpenGallery: { openMediaGallery(message.id) },
                                           onSendEditedImage: { image in sendEditedImage(image) },
                                           selectionMode: selectionMode,
                                           isSelected: selectedIDs.contains(message.id),
                                           isHighlighted: highlightedID == message.id,
                                           onToggleSelection: { toggleSelection(message.id) },
                                           assistant: model.assistantStore.assistant(for: message),
                                           assistantMedia: avatarMedia(for: message))
                                    .contentShape(Rectangle())
                                    .onTapGesture { dismissKeyboard() }
                                    .id(message.id)
                            }
                        }
                        // Invisible bottom anchor: scrolling to this reaches the
                        // true bottom regardless of LazyVStack content heights.
                        Color.clear.frame(height: 1).id(Self.bottomAnchorID)
                    }
                    // Extra top inset so the transcript scrolls *under* the
                    // floating (background-less) assistant bar and shows through
                    // it, instead of being permanently hidden behind it.
                    .padding(.horizontal, 18)
                    .padding(.bottom, 20)
                    .padding(.top, 20 + AssistantBarMetrics.height)
                    .contentShape(Rectangle())
                    .onTapGesture { dismissKeyboard() }
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: pendingScroll) { _, request in
                    guard let request else { return }
                    proxy.scrollTo(request.id, anchor: request.anchor)
                }
                .onChange(of: model.messages.first?.id) { oldFirst, newFirst in
                    // Older page prepended: keep the previous first message at
                    // the top so the content does not visually jump.
                    guard didInitialScroll, let oldFirst, oldFirst != newFirst else { return }
                    pendingScroll = PendingScroll(id: oldFirst, anchor: .top)
                }
                .onChange(of: model.visibleMessages.last?.id) { _, newLast in
                    guard newLast != nil else { return }
                    if !didInitialScroll {
                        didInitialScroll = true
                        scrollToBottomAnchor()
                        return
                    }
                    if atBottom {
                        scrollToBottomAnchor()
                    } else {
                        withAnimation { showNewPill = true }
                    }
                }
                .onChange(of: model.selectedAssistantID) { _, _ in
                    scrollToBottomAnchor()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { scrollToBottomAnchor() }
                }
                .onScrollGeometryChange(for: ScrollState.self) { geometry in
                    ScrollState(
                        atBottom: geometry.contentOffset.y + geometry.containerSize.height
                            >= geometry.contentSize.height - 120,
                        nearTop: geometry.contentOffset.y < 60
                    )
                } action: { _, state in
                    atBottom = state.atBottom
                    if state.atBottom { showNewPill = false }
                    if state.nearTop { onReachTop() }
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollContentBackground(.hidden)
                .background(Color.chatBackground.ignoresSafeArea())
                // Keyboard follow: see followKeyboard(_:) for the root cause.
                .onReceive(keyboardWillShowPublisher) { note in
                    followKeyboard(note)
                }
                .overlay(alignment: .bottomTrailing) {
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
                AssistantBarView(assistants: model.assistantStore.assistants,
                                 selectedID: $model.selectedAssistantID,
                                 unreadIDs: model.unreadAssistantIDs,
                                 avatarStore: model.avatarStore,
                                 onSelect: { model.selectAssistant($0) },
                                 onAdd: { showNewAssistant = true })
            }
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) {
                if selectionMode {
                    SelectionBar(onClearAll: { selectionAlert = .clearAll })
                } else {
                    ComposerView(model: model, focused: $composerFocused)
                }
            }
        }
        .sheet(isPresented: $showSearch) {
            SearchView(model: model, onSelect: { id in jumpToMessage(id) })
        }
        .sheet(isPresented: $showFavorites) {
            FavoritesView(model: model)
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
        .sheet(isPresented: $showMediaGallery) {
            MediaGalleryView(model: model, initialMessageID: galleryInitialID)
        }
        .sheet(isPresented: $showNewAssistant) {
            NewAssistantSheet { name, avatarText, colorIndex in
                model.assistantStore.addCustom(name: name, avatarText: avatarText, colorIndex: colorIndex)
            }
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
        .overlay { if showToast { toastView } }
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
    private func sendEditedImage(_ image: UIImage) {
        if let error = model.sendEditedImage(image, originalName: nil) {
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
        guard atBottom else { return }
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(duration, 0.1)))
            scrollToBottomAnchor()
        }
    }

    /// Dismiss the keyboard when a blank chat area is tapped. The composer is a
    /// UITextView (not a SwiftUI TextField), so clear the focus binding and also
    /// resign the first responder directly via the responder chain.
    private func dismissKeyboard() {
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
        guard !model.isLoadingOlder, model.hasOlder else { return }
        Task { await model.loadOlder() }
    }

    private func scrollToBottom() {
        showNewPill = false
        scrollToBottomAnchor()
    }

    private func scrollToBottomAnchor() {
        pendingScroll = PendingScroll(id: Self.bottomAnchorID, anchor: .bottom)
        // Repeat once after layout settles: LazyVStack heights change as
        // image/thumbnail cells load, which can shift the true bottom.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
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

    private func jumpToMessage(_ id: String) {
        Task { @MainActor in
            // Let the date-jump sheet finish dismissing before scrolling.
            try? await Task.sleep(for: .milliseconds(320))
            highlightedID = id
            pendingScroll = PendingScroll(id: id, anchor: .top)
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation { highlightedID = nil }
        }
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
    let onClearAll: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("清空全部", systemImage: "trash") { onClearAll() }
                .buttonStyle(.bordered)
                .tint(.red)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }
}
