import SwiftUI

struct TimelineView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var composerFocused: Bool
    @State private var showImageGrid = false
    @State private var showFavorites = false
    @State private var showDateJump = false
    @State private var showSettings = false
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 18) {
                        if !model.messages.isEmpty { topLoader }
                        if model.messages.isEmpty {
                            ContentUnavailableView("等待传输", systemImage: "shippingbox",
                                                   description: Text("来自电脑的消息和文件会显示在这里。"))
                                .padding(.top, 100)
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
                                           isCurrent: message.isCurrentDevice,
                                           isFavorite: model.localStore.isFavorite(message.id),
                                           onToggleFavorite: { await model.toggleFavorite(message) },
                                           copyTemporaryLink: { await model.copyTemporaryLink(for: message) },
                                           selectionMode: selectionMode,
                                           isSelected: selectedIDs.contains(message.id),
                                           isHighlighted: highlightedID == message.id,
                                           onToggleSelection: { toggleSelection(message.id) })
                                    .id(message.id)
                            }
                        }
                        // Invisible bottom anchor: scrolling to this reaches the
                        // true bottom regardless of LazyVStack content heights.
                        Color.clear.frame(height: 1).id(Self.bottomAnchorID)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 20)
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
                .onChange(of: model.messages.last?.id) { _, newLast in
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
            .navigationTitle("Ferry")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selectionMode {
                        Button("取消") { exitSelection() }
                    } else {
                        Label(model.currentDevice?.name ?? "设备", systemImage: "iphone")
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("current-device")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !selectionMode {
                        HStack(spacing: 14) {
                            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                                .accessibilityLabel("设置")
                            Button { showDateJump = true } label: { Image(systemName: "calendar") }
                                .accessibilityLabel("跳转到日期")
                            Button { showFavorites = true } label: { Image(systemName: "star") }
                                .accessibilityLabel("收藏")
                            Button { showImageGrid = true } label: { Image(systemName: "square.grid.2x2") }
                                .accessibilityLabel("图片")
                            Button { enterSelection() } label: { Text("选择") }
                                .accessibilityLabel("选择")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selectionMode {
                    SelectionBar(selectedCount: selectedIDs.count,
                                 onDelete: { selectionAlert = .delete },
                                 onClearAll: { selectionAlert = .clearAll })
                } else {
                    ComposerView(model: model, focused: $composerFocused)
                }
            }
        }
        .sheet(isPresented: $showImageGrid) {
            ImageGridView(messages: model.imageMessages,
                          images: model.images,
                          loadImage: { m in await model.loadImage(for: m) },
                          loadFile: { m in await model.fileData(for: m) })
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
            SettingsView()
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

/// Bottom bar shown while in select mode: 清空全部 on the left, 删除(N) on the
/// right. Confirmation happens in the parent via alerts.
private struct SelectionBar: View {
    let selectedCount: Int
    let onDelete: () -> Void
    let onClearAll: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("清空全部", systemImage: "trash") { onClearAll() }
                .buttonStyle(.bordered)
                .tint(.red)
            Spacer()
            Button {
                onDelete()
            } label: {
                Text(selectedCount > 0 ? "删除(\(selectedCount))" : "删除")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selectedCount == 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }
}
