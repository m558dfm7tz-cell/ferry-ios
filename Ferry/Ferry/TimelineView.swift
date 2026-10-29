import SwiftUI
import UIKit
import Combine

struct TimelineView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var composerFocused = false
    @State private var showFavorites = false
    @State private var showDateJump = false
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showDeviceManagement = false
    @State private var showComputerSwitcher = false
    // Bind the selected message and the presentation in one state change.
    // The previous separate Bool / ID could show the grid on first launch.
    private struct MediaPresentation: Identifiable {
        let id = UUID()
        let initialMessageID: String?
    }
    @State private var mediaPresentation: MediaPresentation?
    @State private var showNewAssistant = false
    @State private var showReviewList = false
    @State private var atBottom = true
    @State private var isFollowingTail = true
    @State private var transcriptUserDragging = false
    @State private var showAttachmentPanel = false
    @State private var showAlbumPicker = false
    @State private var albumMounted = false
    @State private var albumRevealed = false
    @State private var selectionMode = false
    @State private var selectedIDs: Set<String> = []
    @State private var selectionAlert: SelectionAlert?
    @State private var pendingScroll: PendingScroll?
    @State private var didInitialScroll = false
    @State private var renderedTailID: String?
    @State private var visibleTailID: String?
    @State private var initialTailAligned = false
    // A new ScrollView identity forces LazyVStack to rebuild after an actual
    // background round-trip; stale lazy cells otherwise stay blank until drag.
    @State private var transcriptGeneration = 0
    @State private var wasBackgrounded = false
    @State private var initialAnchorTask: Task<Void, Never>?
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
    // Pin the transcript throughout the keyboard's entire safe-area animation.
    // A media row loading must not flip the bottom anchor mid-transition.
    @State private var keyboardAnchorLocked = false
    // Keyboard changes the viewport for many frames. These are not manual
    // scroll gestures and must not detach a media-heavy transcript from tail.
    @State private var keyboardTransitioning = false
    @State private var keyboardTransitionTask: Task<Void, Never>?
    @State private var keyboardTailNeedsCorrection = false
    @State private var measuredAtBottom = true
    @State private var keyboardReanchorQueued = false
    @State private var keyboardReanchorTask: Task<Void, Never>?
    // An explicit touch distinguishes a real history drag from UIKit's
    // keyboard-driven scroll-phase events.
    @State private var transcriptTouchDragging = false
    @State private var transcriptScrollPhase: ScrollPhase = .idle
    @State private var followMediaMessageID: String?

    // Distinguish an incoming message in the current conversation from an
    // avatar switch. The latter already scrolls via selectedAssistantID.
    private struct VisibleTail: Equatable {
        let conversationID: String?
        let messageID: String?
    }

    private static let bottomAnchorID = "timeline-bottom"

    /// Keyboard-appearance notifications, used to keep the newest message
    /// visible above the composer (see `followKeyboard(_:)`).
    private let keyboardWillShowPublisher = NotificationCenter.default
        .publisher(for: UIResponder.keyboardWillShowNotification)
    private let keyboardWillHidePublisher = NotificationCenter.default
        .publisher(for: UIResponder.keyboardWillHideNotification)
    private let keyboardDidHidePublisher = NotificationCenter.default
        .publisher(for: UIResponder.keyboardDidHideNotification)
    private let keyboardDidShowPublisher = NotificationCenter.default
        .publisher(for: UIResponder.keyboardDidShowNotification)
    private let keyboardWillChangeFramePublisher = NotificationCenter.default
        .publisher(for: UIResponder.keyboardWillChangeFrameNotification)
    private let keyboardDidChangeFramePublisher = NotificationCenter.default
        .publisher(for: UIResponder.keyboardDidChangeFrameNotification)

    /// A scroll request. The `nonce` makes every request unique so the same
    /// message id can be scrolled to more than once (date jump, re-anchor).
    private struct PendingScroll: Equatable {
        let id: String
        let anchor: UnitPoint
        let reason: ScrollReason
        let nonce = UUID()
    }

    /// A single gate for programmatic scroll. A keyboard/media callback must
    /// never override a drag, or a search/date jump already in progress.
    private enum ScrollReason: Equatable {
        case user, newMessage, keyboard, media, pagination, jump
    }

    private func queueScroll(to id: String, anchor: UnitPoint, reason: ScrollReason) {
        switch reason {
        case .user:
            break
        case .jump:
            guard !transcriptUserDragging else { return }
        case .pagination:
            guard !transcriptUserDragging, !keyboardTransitioning,
                  jumpHoldingID == nil else { return }
        case .newMessage, .keyboard, .media:
            guard isFollowingTail, !transcriptUserDragging, jumpHoldingID == nil else { return }
        }
        pendingScroll = PendingScroll(id: id, anchor: anchor, reason: reason)
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
        .sheet(isPresented: $showComputerSwitcher) {
            ComputerSwitcherView(model: model)
        }
        .sheet(isPresented: $showDeviceManagement) {
            NavigationStack {
                DeviceManagementView(model: model)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { Button("关闭") { showDeviceManagement = false } }
                    }
            }
        }
        .fullScreenCover(item: $mediaPresentation) { presentation in
            MediaGalleryView(model: model, initialMessageID: presentation.initialMessageID)
                .presentationBackground(.clear)
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
                Text("确定删除选中的 \(selectedIDs.count) 条消息吗？删除会同步到 Ferry 服务端及其他设备；对应原始附件也会被删除。")
            case .clearAll:
                Text("确定清空 Ferry 服务端全部聊天记录吗？这会影响所有设备，并删除消息关联的原始附件。")
            }
        }
        .overlay {
            GeometryReader { geometry in
                if albumMounted {
                    // Mount a complete opaque page below the screen before
                    // animating its single outer offset. Async photo loading
                    // can no longer animate each grid row during presentation.
                    AlbumPickerView(model: model,
                                    onClose: { showAlbumPicker = false },
                                    onDragDismissed: {
                                        albumMounted = false
                                        albumRevealed = false
                                        showAlbumPicker = false
                                    })
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        // No opaque backing outside the moved picker content:
                        // dragging down reveals the actual timeline.
                        .ignoresSafeArea()
                        .offset(y: albumRevealed ? 0 :
                                max(geometry.size.height, UIScreen.main.bounds.height) + 120)
                        .zIndex(10)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(albumMounted)
        }
        .onChange(of: showAlbumPicker, initial: true) { _, opened in
            if opened {
                albumMounted = true
                albumRevealed = false
                Task { @MainActor in
                    // Insert first, then animate the composed page as one layer.
                    try? await Task.sleep(for: .milliseconds(75))
                    guard showAlbumPicker else { return }
                    withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.43)) {
                        albumRevealed = true
                    }
                }
            } else if albumMounted {
                withAnimation(.timingCurve(0.20, 0.75, 0.28, 1, duration: 0.43)) {
                    albumRevealed = false
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    if !showAlbumPicker { albumMounted = false }
                }
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
                                TimelineMessageCell(model: model,
                                                    message: message,
                                                    selectionMode: selectionMode,
                                                    isSelected: selectedIDs.contains(message.id),
                                                    isHighlighted: jumpTargetID == message.id,
                                                    highlightOn: highlightOn,
                                                    onOpenGallery: openMediaGallery,
                                                    onSendEditedImage: sendEditedImage,
                                                    onToggleSelection: toggleSelection)
                                    // Reserve the floating bar's height above
                                    // the row a jump landed on, so anchoring
                                    // the row to the top of the scroll view
                                    // leaves it just below the bar.
                                    // Jump positioning is a scroll anchor, not
                                    // permanent padding on the target message.
                                    .contentShape(Rectangle())
                                    .id(message.id)
                                    .onAppear {
                                        if message.id == model.visibleMessages.last?.id {
                                            renderedTailID = message.id
                                            scheduleInitialBottomAnchor()
                                        }
                                    }
                                    .onScrollVisibilityChange(threshold: 0.02) { visible in
                                        // Geometry alone can report a bottom offset
                                        // while LazyVStack has failed to paint rows.
                                        guard message.id == model.visibleMessages.last?.id else { return }
                                        visibleTailID = visible ? message.id : nil
                                    }
                                if model.hasMobileNewerGap(after: message) {
                                    Button {
                                        Task { await model.loadNewerAcrossGap() }
                                    } label: {
                                        HStack(spacing: 8) {
                                            if model.isLoadingNewerGap { ProgressView() }
                                            Text("中间还有历史消息 · 加载较新记录")
                                        }
                                        .font(.footnote)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                    }
                                    .disabled(model.isLoadingNewerGap)
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("load-newer-history-gap")
                                }
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
                    .background {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { dismissKeyboard() }
                    }
                }
                let messageObserved = baseTranscript.id(transcriptGeneration)
                    .simultaneousGesture(DragGesture(minimumDistance: 8)
                        .onChanged { _ in
                            // Only a real touch can cancel tail-follow. Allow
                            // a user drag even during interactive dismissal.
                            transcriptTouchDragging = true
                            if !transcriptUserDragging {
                                initialAnchorTask?.cancel()
                                jumpTask?.cancel()
                                jumpHoldingID = nil
                                keyboardReanchorTask?.cancel()
                                keyboardReanchorQueued = false
                                // Invalidate any uncommitted keyboard scroll.
                                if pendingScroll?.reason == .keyboard { pendingScroll = nil }
                                keyboardWasAtBottom = false
                                keyboardAnchorLocked = false
                                keyboardTailNeedsCorrection = false
                                transcriptUserDragging = true
                                isFollowingTail = false
                            }
                        }
                        .onEnded { _ in
                            transcriptTouchDragging = false
                            if transcriptScrollPhase == .idle {
                                transcriptUserDragging = false
                                isFollowingTail = atBottom
                            }
                        })
                    .simultaneousGesture(TapGesture().onEnded {
                        // Tap outside the composer closes the attachment
                        // keyboard without stealing image/menu button taps.
                        if showAttachmentPanel || composerFocused || keyboardVisible {
                            dismissKeyboard()
                        }
                    })
                    .defaultScrollAnchor(.bottom)
                    // iOS 18 automatically keeps the bottom attached as the
                    // keyboard changes the viewport size. Do not force another
                    // scrollTo after its animation (costly with media rows).
                    .defaultScrollAnchor((isFollowingTail || keyboardAnchorLocked) ? .bottom : nil, for: .sizeChanges)
                .onChange(of: pendingScroll) { _, request in
                    guard let request else { return }
                    // A message can arrive in the same render transaction as the
                    // request. Wait for that layout pass before resolving its id.
                    Task { @MainActor in
                        await Task.yield()
                        guard pendingScroll == request else { return }
                        if request.reason == .keyboard {
                            guard isFollowingTail, !transcriptUserDragging,
                                  jumpHoldingID == nil else { return }
                            // Avoid a second animation fighting the native
                            // safe-area animation already in progress.
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                proxy.scrollTo(request.id, anchor: request.anchor)
                            }
                        } else {
                            proxy.scrollTo(request.id, anchor: request.anchor)
                        }
                    }
                }
                .onChange(of: model.olderPageAnchor) { _, anchor in
                    // Only an explicit history prepend can preserve the old
                    // first visible row. Cache replacement / other conversations
                    // must never hijack the current scroll position.
                    guard let anchor, anchor.conversationID == model.selectedAssistantID,
                          didInitialScroll,
                          model.visibleMessages.contains(where: { $0.id == anchor.messageID })
                    else { return }
                    queueScroll(to: anchor.messageID, anchor: .top, reason: .pagination)
                }
                .onChange(of: VisibleTail(
                    conversationID: model.selectedAssistantID,
                    messageID: model.visibleMessages.last?.id
                )) { old, latest in
                    // A conversation switch changes the visible tail too.
                    // Do not queue two scrollTo calls for the same avatar tap.
                    guard old.conversationID == latest.conversationID,
                          latest.messageID != nil, jumpHoldingID == nil else { return }
                    if !didInitialScroll {
                        scheduleInitialBottomAnchor()
                        return
                    }
                    if isFollowingTail {
                        scrollToBottomAnchor(reason: .newMessage)
                    } else {
                        withAnimation { showNewPill = true }
                    }
                }
                .onChange(of: model.selectedAssistantID) { _, _ in
                    guard jumpHoldingID == nil else { return }
                    clearJumpTarget()
                    initialAnchorTask?.cancel()
                    didInitialScroll = false
                    renderedTailID = nil
                    visibleTailID = nil
                    initialTailAligned = false
                    isFollowingTail = true
                    scheduleInitialBottomAnchor()
                }
                .onChange(of: model.isLoadingInitial) { wasLoading, loading in
                    guard wasLoading, !loading, isFollowingTail,
                          !model.visibleMessages.isEmpty, jumpHoldingID == nil else { return }
                    // A cache-to-server replacement can invalidate lazy cell
                    // geometry even when the current ScrollView reports bottom.
                    if !didInitialScroll || visibleTailID != model.visibleMessages.last?.id {
                        rebuildTranscriptAtTail()
                    } else {
                        scrollToBottomAnchor(reason: .newMessage)
                    }
                }
                .onAppear { scheduleInitialBottomAnchor() }
                .onChange(of: visibleTailID) { _, tailID in
                    // Visibility is a separate proof from the lazy content
                    // offset: the bottom spacer can be present with blank rows.
                    guard !didInitialScroll, !model.isLoadingInitial,
                          let tailID, tailID == model.visibleMessages.last?.id,
                          initialTailAligned, !transcriptUserDragging else { return }
                    didInitialScroll = true
                    initialAnchorTask?.cancel()
                }
                .onChange(of: model.scrollToBottomToken) { _, _ in
                    guard jumpHoldingID == nil else { return }
                    isFollowingTail = true
                    scrollToBottomAnchor()
                }
                let mediaObserved = messageObserved
                    // Media cells observe their own image/thumbnail state.
                    // Observing the entire image dictionaries here invalidates
                    // the WHOLE transcript for each decoded photo, especially
                    // while the keyboard's safe area is changing.
                    .onReceive(NotificationCenter.default.publisher(
                        for: AppModel.mediaDidResolveNotification)
                        .debounce(for: .milliseconds(240), scheduler: RunLoop.main)) { _ in
                        followPendingMediaLoad()
                    }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        keyboardFollowTask?.cancel()
                        keyboardTransitionTask?.cancel()
                        keyboardReanchorTask?.cancel()
                        keyboardReanchorQueued = false
                        keyboardTailNeedsCorrection = false
                        keyboardWasAtBottom = false
                        keyboardAnchorLocked = false
                        keyboardTransitioning = false
                        keyboardVisible = false
                        initialAnchorTask?.cancel()
                        if phase == .background { wasBackgrounded = true }
                    } else if wasBackgrounded {
                        wasBackgrounded = false
                        // Only rebuild after a genuine background transition.
                        // Preserve the user's historical scroll when not pinned.
                        if isFollowingTail, jumpHoldingID == nil,
                           !model.visibleMessages.isEmpty {
                            rebuildTranscriptAtTail()
                        }
                    } else if isFollowingTail && jumpHoldingID == nil {
                        if didInitialScroll { scrollToBottomAnchor(reason: .newMessage) }
                        else { scheduleInitialBottomAnchor() }
                    }
                }
                let geometryObserved = mediaObserved
                    .onScrollGeometryChange(for: ScrollState.self) { geometry in
                    ScrollState(
                        atBottom: geometry.contentOffset.y + geometry.containerSize.height
                            >= geometry.contentSize.height - 24,
                        nearTop: geometry.contentOffset.y < 260,
                        offsetY: geometry.contentOffset.y,
                        contentHeight: geometry.contentSize.height,
                        viewportHeight: geometry.containerSize.height,
                        distanceToBottom: max(0, geometry.contentSize.height
                            - geometry.contentOffset.y - geometry.containerSize.height)
                    )
                } action: { old, state in
                    // An initial scroll is complete only after the final cell
                    // actually mounted and the viewport is geometrically at
                    // the bottom. A queued scrollTo is not proof of success.
                    if !didInitialScroll {
                        let aligned = state.viewportHeight > 0 &&
                            state.contentHeight > 0 && state.distanceToBottom <= 24
                        if aligned != initialTailAligned { initialTailAligned = aligned }
                        if aligned, !model.isLoadingInitial,
                           let tail = model.visibleMessages.last?.id,
                           renderedTailID == tail, visibleTailID == tail,
                           !transcriptUserDragging, jumpHoldingID == nil {
                            didInitialScroll = true
                            initialAnchorTask?.cancel()
                        }
                    }
                    // The transform above runs on every frame of any scroll and
                    // of the keyboard animation (the visible height changes), so
                    // only write when a value actually flips: an unconditional
                    // @State write re-evaluated the whole body every frame.
                    // Keyboard native safe-area changes can generate dozens
                    // of geometry frames. Do NOT mutate the scroll anchor or
                    // push scrollTo per frame: finish one native transition,
                    // then do at most one corrective scroll if still displaced.
                    if isKeyboardTailPinned {
                        let aligned = state.distanceToBottom <= 24
                        if measuredAtBottom != aligned {
                            measuredAtBottom = aligned
                        }
                        if keyboardTailNeedsCorrection != !aligned {
                            keyboardTailNeedsCorrection = !aligned
                        }
                        // A late thumbnail can change content height after the
                        // keyboard has settled. That is a separate layout event
                        // and may require one non-animated correction.
                        if !keyboardTransitioning, keyboardVisible, !aligned,
                           abs(state.contentHeight - old.contentHeight) > 1 {
                            requestKeyboardTailCorrection()
                        }
                    }
                    // Keep the toolbar indicator stable throughout the keyboard
                    // animation. Refresh it from the *latest* measured state at
                    // settlement; old.atBottom can be stale across that window.
                    if !keyboardTransitioning && !keyboardAnchorLocked &&
                       state.atBottom != atBottom {
                        atBottom = state.atBottom
                        if state.atBottom { showNewPill = false }
                    }
                    // `onReachTop()` used to fire on every frame spent near the
                    // top, spawning a load task each time.
                    // A short ten-message transcript starts near the top.
                    // Only an actual upward user drag may prefetch history;
                    // keyboard geometry and initial layout must never do so.
                    if transcriptUserDragging, !keyboardVisible, !keyboardTransitioning,
                       !keyboardAnchorLocked, state.nearTop,
                       state.offsetY < old.offsetY - 2 {
                        onReachTop()
                    }
                }
                .onScrollPhaseChange { _, phase in
                    transcriptScrollPhase = phase
                    // UIKit also emits .interacting during keyboard geometry
                    // changes. Only the explicit DragGesture above may detach
                    // the chat from tail; phase changes only finish a drag.
                    if phase == .idle && transcriptUserDragging {
                        // UIKit may cancel DragGesture without onEnded.
                        transcriptTouchDragging = false
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
                .onReceive(keyboardDidHidePublisher) { _ in
                    completeKeyboardDismissal()
                }
                .onReceive(keyboardDidShowPublisher) { _ in
                    finishKeyboardAppearance()
                }
                .onReceive(keyboardWillChangeFramePublisher) { _ in
                    beginKeyboardFrameChange()
                }
                .onReceive(keyboardDidChangeFramePublisher) { _ in
                    if keyboardVisible && keyboardTransitioning {
                        settleKeyboardViewport(visible: true)
                    }
                }
                keyboardAware.overlay(alignment: .bottomTrailing) {
                    if !atBottom && !(keyboardTransitioning && isKeyboardTailPinned) {
                        Button {
                            scrollToBottom()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("最新消息")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundStyle(Color(red: 0.34, green: 0.75, blue: 0.95))
                            .padding(.horizontal, 15)
                            .frame(height: 34)
                            .background(Color(red: 0.07, green: 0.15, blue: 0.21),
                                        in: Capsule())
                            .overlay(Capsule().strokeBorder(
                                Color(red: 0.23, green: 0.47, blue: 0.62).opacity(0.7),
                                lineWidth: 0.8))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("回到最新消息")
                        .padding(.trailing, 14).padding(.bottom, 10)
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
                Button { showComputerSwitcher = true } label: {
                    Image(systemName: connectionIcon.symbol)
                        .foregroundStyle(connectionIcon.color)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换电脑")
                .accessibilityIdentifier("computer-switcher-button")
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
                            mediaPresentation = MediaPresentation(initialMessageID: nil)
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
        mediaPresentation = MediaPresentation(initialMessageID: messageID)
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

    /// Recreate only the scroll viewport, never AppModel or its local stores.
    /// A backgrounded LazyVStack can retain invalid visible-range bookkeeping
    /// even while its data remains populated; a fresh identity restores cells.
    /// Historical reading deliberately keeps the existing viewport intact.
    private func rebuildTranscriptAtTail() {
        guard isFollowingTail, !transcriptUserDragging,
              jumpHoldingID == nil, !model.visibleMessages.isEmpty else { return }
        initialAnchorTask?.cancel()
        keyboardReanchorTask?.cancel()
        pendingScroll = nil
        didInitialScroll = false
        renderedTailID = nil
        visibleTailID = nil
        initialTailAligned = false
        atBottom = true
        transcriptGeneration &+= 1
        Task { @MainActor in
            await Task.yield()
            scheduleInitialBottomAnchor()
        }
    }

    /// An initial list is laid out in several passes (cached rows, server
    /// replacement, decoded media). Retry only until geometry confirms the
    /// latest rendered row is actually at the bottom, not just queued.
    private func scheduleInitialBottomAnchor() {
        guard !didInitialScroll, isFollowingTail, !model.visibleMessages.isEmpty,
              !transcriptUserDragging, jumpHoldingID == nil else { return }
        initialAnchorTask?.cancel()
        initialAnchorTask = Task { @MainActor in
            for pause in [0, 70, 140, 220] {
                if pause > 0 { try? await Task.sleep(for: .milliseconds(pause)) }
                guard !Task.isCancelled, !didInitialScroll, isFollowingTail,
                      !transcriptUserDragging, jumpHoldingID == nil else { return }
                scrollToBottomAnchor(reason: .newMessage)
            }
        }
    }

    /// A keyboard transition may keep the bottom pinned only if the user
    /// was following the newest message before the viewport began to resize.
    /// Alignment itself is verified from ScrollGeometry, not assumed.
    private var isKeyboardTailPinned: Bool {
        // Keep following the tail even AFTER didShow: a late-arriving photo
        // layout can otherwise strand the chat several messages behind.
        isFollowingTail && !transcriptUserDragging && jumpHoldingID == nil &&
            (keyboardVisible || keyboardWasAtBottom)
    }

    /// Coalesce rapid geometry events and use the real bottom anchor after
    /// SwiftUI lays out the latest viewport. A cancelled user drag always wins.
    private func requestKeyboardTailCorrection() {
        guard isKeyboardTailPinned, !keyboardTransitioning,
              !keyboardReanchorQueued else { return }
        keyboardReanchorQueued = true
        keyboardReanchorTask?.cancel()
        keyboardReanchorTask = Task { @MainActor in
            await Task.yield()
            keyboardReanchorQueued = false
            guard !Task.isCancelled, isKeyboardTailPinned else { return }
            scrollToBottomAnchor(reason: .keyboard)
        }
    }

    private func followKeyboard(_ note: Notification) {
        keyboardTransitionTask?.cancel()
        if !keyboardVisible {
            keyboardWasAtBottom = isFollowingTail &&
                !transcriptUserDragging && jumpHoldingID == nil
            keyboardAnchorLocked = keyboardWasAtBottom
            keyboardTailNeedsCorrection = false
        }
        keyboardTransitioning = true
        keyboardVisible = true
        keyboardFollowTask?.cancel()
    }

    private func finishKeyboardAppearance() {
        settleKeyboardViewport(visible: true)
    }

    /// Third-party keyboards, emoji/QuickType changes and the replacement
    /// attachment inputView can resize without another keyboardWillShow.
    private func beginKeyboardFrameChange() {
        guard keyboardVisible else { return }
        keyboardTransitionTask?.cancel()
        if !keyboardTransitioning {
            keyboardWasAtBottom = isFollowingTail &&
                !transcriptUserDragging && jumpHoldingID == nil
            keyboardTailNeedsCorrection = false
        }
        keyboardAnchorLocked = keyboardWasAtBottom
        keyboardTransitioning = true
        // Do not remain locked if a keyboard implementation skips didChangeFrame.
        // A real gap check, rather than this timeout, determines any correction.
        settleKeyboardViewport(visible: true)
    }

    private func restoreAfterKeyboard(_ note: Notification) {
        guard keyboardVisible else { return }
        keyboardTransitionTask?.cancel()
        // Re-snapshot reading intent: a user may have scrolled back to the
        // bottom while the keyboard was open.
        keyboardWasAtBottom = isFollowingTail &&
            !transcriptUserDragging && jumpHoldingID == nil
        keyboardAnchorLocked = keyboardWasAtBottom
        keyboardVisible = false
        keyboardTransitioning = true
        keyboardFollowTask?.cancel()
    }

    private func completeKeyboardDismissal() {
        settleKeyboardViewport(visible: false)
    }

    /// Only one settlement survives a keyboard event sequence. SwiftUI keeps
    /// the bottom naturally *during* the animation. A single measured correction
    /// after layout handles any remaining gap; no scrollTo feedback loop.
    private func settleKeyboardViewport(visible: Bool) {
        keyboardTransitionTask?.cancel()
        keyboardTransitionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled, keyboardVisible == visible else { return }
            let pinned = isKeyboardTailPinned
            let needsCorrection = pinned && keyboardTailNeedsCorrection
            keyboardTransitioning = false
            if pinned {
                atBottom = measuredAtBottom
                if measuredAtBottom { showNewPill = false }
            }
            if needsCorrection {
                // Queue while the hide-transition pin is still valid.
                // The reader resolves this command after SwiftUI's next pass.
                scrollToBottomAnchor(reason: .keyboard)
            }
            keyboardAnchorLocked = false
            keyboardWasAtBottom = false
            keyboardTailNeedsCorrection = false
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
            } else if model.hasOlder {
                Button {
                    Task { await model.loadOlder() }
                } label: {
                    Text("加载更早消息")
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("load-older-messages")
            } else {
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

    private func scrollToBottomAnchor(reason: ScrollReason = .user) {
        queueScroll(to: Self.bottomAnchorID, anchor: .bottom, reason: reason)
        // Only one scroll per intent; don't enqueue a second delayed bounce.
    }

    private func followPendingMediaLoad() {
        // Lazy image/video sizes may resolve after date/search scrollTo().
        // Re-anchor the jumped row rather than drifting into another message.
        if let id = jumpHoldingID, !transcriptUserDragging {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                guard jumpHoldingID == id, !transcriptUserDragging else { return }
                queueScroll(to: id, anchor: .center, reason: .jump)
            }
            return
        }
        // Combine debounces thumbnail arrivals. During keyboard display,
        // let measured geometry decide whether a correction is necessary
        // instead of ignoring late media-size changes outright.
        if keyboardVisible {
            if keyboardTailNeedsCorrection { requestKeyboardTailCorrection() }
            return
        }
        guard isFollowingTail, !transcriptUserDragging,
              !keyboardTransitioning, !keyboardAnchorLocked,
              jumpHoldingID == nil else { return }
        queueScroll(to: Self.bottomAnchorID, anchor: .bottom, reason: .media)
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
            // Let the search/date sheet dismiss before loading the target's
            // local ten-message context. Its original message can be thousands
            // of entries older than the main ten-message window.
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            let loaded = await model.ensureMessageLoaded(id: id)
            guard !Task.isCancelled, loaded else {
                if jumpHoldingID == id { jumpHoldingID = nil }
                flashToast("定位消息失败，请检查电脑连接")
                return
            }
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
            queueScroll(to: id, anchor: .center, reason: .jump)
            // One soft highlight rather than an intrusive repeated yellow flash.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, jumpTargetID == id else { return }
            queueScroll(to: id, anchor: .center, reason: .jump)
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
              let message = model.messageForJump(id: id) else {
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

/// Each media row observes only its own presentation state. Keeping the
/// dictionary reads OUT of TimelineView prevents an arriving thumbnail from
/// rebuilding the keyboard-aware ScrollView and all day sections.
private struct TimelineMessageCell: View {
    let model: AppModel
    let message: MessagePayload
    let selectionMode: Bool
    let isSelected: Bool
    let isHighlighted: Bool
    let highlightOn: Bool
    let onOpenGallery: (String) -> Void
    let onSendEditedImage: (UIImage, MessagePayload) -> Void
    let onToggleSelection: (String) -> Void

    var body: some View {
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
                   onOpenGallery: { onOpenGallery(message.id) },
                   onSendEditedImage: { edited in onSendEditedImage(edited, message) },
                   selectionMode: selectionMode,
                   isSelected: isSelected,
                   isHighlighted: isHighlighted,
                   highlightOn: highlightOn,
                   onToggleSelection: { onToggleSelection(message.id) },
                   assistant: model.assistantStore.assistant(for: message),
                   assistantMedia: avatarMedia)
    }

    private var avatarMedia: AssistantAvatarMedia? {
        guard let id = model.assistantStore.assistant(for: message)?.id else { return nil }
        return model.avatarStore.media(for: id)
    }
}

/// Scroll geometry snapshot for the chat: whether the user is near the bottom
/// (auto-scroll on new messages) and whether they have reached the top
/// (trigger older-page loading).
private struct ScrollState: Hashable {
    let atBottom: Bool
    let nearTop: Bool
    let offsetY: CGFloat
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    let distanceToBottom: CGFloat
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
