import SwiftUI
import UIKit

/// Media gallery: a grid of every loaded image + video message. Tapping a cell
/// opens a full-screen pager (TabView `.page`) positioned on that item, with
/// left/right swipe between media, existing ImageViewer zoom for images and
/// VideoPlayerView for videos. A "grid" button returns from the pager to the
/// grid; the viewers keep their own drag-to-dismiss (back to grid).
struct MediaGalleryView: View {
    @Bindable var model: AppModel
    let initialMessageID: String?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedMessage: MessagePayload?
    @State private var wantsGrid = false
    @State private var gridAtTop = true
    @State private var gridDrag: CGFloat = 0
    @State private var gridClosing = false
    /// Freeze this chat's media identity for the life of the viewer; a server
    /// refresh cannot silently repopulate the pager with another chat's media.
    @State private var scopedMessages: [MessagePayload]

    init(model: AppModel, initialMessageID: String?) {
        self.model = model
        self.initialMessageID = initialMessageID
        let scope = model.mediaMessages
        _scopedMessages = State(initialValue: scope)
        // Select before the FIRST frame: avoids flashing the entire grid when
        // the user first taps a bubble after opening Ferry.
        _selectedMessage = State(initialValue:
            initialMessageID.flatMap { id in scope.first(where: { $0.id == id }) })
    }

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 3)]

    var body: some View {
        Group {
            if let selectedMessage {
                MediaPagerView(messages: scopedMessages, startID: selectedMessage.id,
                               model: model,
                               onReturnToGrid: {
                                   wantsGrid = true
                                   self.selectedMessage = nil
                               },
                               onCloseViewer: {
                                   if initialMessageID != nil { dismiss() }
                                   else { self.selectedMessage = nil }
                               })
            } else if initialMessageID != nil && !wantsGrid {
                // A freshly resumed app may not have hydrated mediaMessages
                // on the first frame. Never flash the all-media grid.
                Color.black.ignoresSafeArea()
                    .overlay { ProgressView().tint(.white) }
            } else {
                mediaGrid
            }
        }
        .onAppear { reconcileInitialMedia() }
        .onChange(of: model.mediaMessages.map(\.id)) { _, _ in
            reconcileInitialMedia()
        }
    }

    private func reconcileInitialMedia() {
        guard !wantsGrid, let target = initialMessageID, selectedMessage == nil else { return }
        let current = model.mediaMessages
        guard let message = current.first(where: { $0.id == target }) else { return }
        scopedMessages = current
        selectedMessage = message
    }

    private var mediaGrid: some View {
        NavigationStack {
            ScrollView {
                if scopedMessages.isEmpty {
                    ContentUnavailableView("暂无媒体", systemImage: "photo.on.rectangle.angled",
                                           description: Text("图片和视频消息会显示在这里。"))
                        .padding(.top, 120)
                } else {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(scopedMessages) { message in
                            cell(for: message)
                        }
                    }
                    .padding(3)
                }
            }
            .background(Color.chatBackground.ignoresSafeArea())
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                gridAtTop = offset <= 2
            }
            .navigationTitle("媒体")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
        }
        .background(Color.chatBackground.ignoresSafeArea())
        .offset(y: gridDrag)
        // Same pull-down interaction as the composer album: only dismiss
        // when starting at the top; otherwise keep the normal grid scroll.
        .simultaneousGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .global)
                .onChanged { value in
                    guard !gridClosing, gridAtTop,
                          value.translation.height > 0,
                          value.translation.height > abs(value.translation.width) else { return }
                    gridDrag = value.translation.height
                }
                .onEnded { value in
                    guard !gridClosing else { return }
                    let shouldClose = gridDrag > 140 ||
                        (gridDrag > 40 && value.predictedEndTranslation.height > 240)
                    if shouldClose {
                        gridClosing = true
                        withAnimation(.timingCurve(0.2, 0.75, 0.28, 1, duration: 0.38)) {
                            gridDrag = UIScreen.main.bounds.height + 100
                        }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(390))
                            dismiss()
                        }
                    } else {
                        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                            gridDrag = 0
                        }
                    }
                }
        )
    }

    @ViewBuilder private func cell(for message: MessagePayload) -> some View {
        if (message.file.map { PreviewRouter.isImage($0) } ?? false) {
            if case .some(.some(let decoded)) = model.images[message.id] {
                Image(uiImage: decoded)
                    .resizable().scaledToFill()
                    .frame(width: 104, height: 104)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture { selectedMessage = message }
            } else {
                placeholder(message)
            }
        } else {
            ZStack {
                if case .some(.some(let thumbnail)) = model.videoThumbnails[message.id] {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Color(.systemGray5)
                }
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.9))
                if let duration = model.videoDurations[message.id], duration > 0 {
                    Text(TimeText.mmss(duration))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .frame(width: 104, height: 104)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { selectedMessage = message }
        }
    }

    @ViewBuilder private func placeholder(_ message: MessagePayload) -> some View {
        RoundedRectangle(cornerRadius: 0)
            .fill(Color(.systemGray5))
            .frame(width: 104, height: 104)
            .overlay { ProgressView() }
            .task {
                if (message.file.map { PreviewRouter.isImage($0) } ?? false) {
                    await model.loadImage(for: message)
                } else {
                    await model.loadVideoThumbnail(for: message)
                }
            }
    }
}

/// Full-screen left/right pager over the media items, positioned on `startID`.
private struct MediaPagerView: View {
    let messages: [MessagePayload]
    let model: AppModel
    let onReturnToGrid: () -> Void
    let onCloseViewer: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var videoURLs: [String: URL] = [:]
    @State private var verticalDrag: CGFloat = 0
    @State private var showToast = false
    @State private var toastText = ""

    private var safeTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow })?.safeAreaInsets.top ?? 44
    }

    init(messages: [MessagePayload], startID: String, model: AppModel,
         onReturnToGrid: @escaping () -> Void,
         onCloseViewer: @escaping () -> Void) {
        self.messages = messages
        self.model = model
        self.onReturnToGrid = onReturnToGrid
        self.onCloseViewer = onCloseViewer
        _currentIndex = State(initialValue: messages.firstIndex(where: { $0.id == startID }) ?? 0)
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(max(0, 1 - Double(abs(verticalDrag) / 380)))
                .ignoresSafeArea()
            TabView(selection: $currentIndex) {
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    // Keep page identity and layout stable throughout the
                    // swipe. Replacing neighboring pages during a TabView
                    // transition caused the visible "bounce back" artifact.
                    page(for: message, isCurrent: index == currentIndex)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.clear)
            .ignoresSafeArea()
        }
        .onChange(of: currentIndex) { _, _ in verticalDrag = 0 }
        .overlay(alignment: .topTrailing) {
            Button { onReturnToGrid() } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.15), in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("此聊天全部图片和视频")
            .accessibilityIdentifier("viewer-open-gallery")
            .padding(.top, max(12, safeTop + 6))
            .padding(.trailing, 16)
            .opacity(abs(verticalDrag) > 0.5 ? 0 : 1)
            .allowsHitTesting(abs(verticalDrag) <= 0.5)
        }
        .overlay(alignment: .top) {
            Text("\(currentIndex + 1) / \(messages.count)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.white.opacity(0.82))
                .padding(.top, max(12, safeTop + 18))
                .allowsHitTesting(false)
                .accessibilityIdentifier("media-pager-position")
                .opacity(abs(verticalDrag) > 0.5 ? 0 : 1)
        }
        .overlay { if showToast { toastView } }
        .statusBarHidden()
    }

    private var toastView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(toastText).foregroundStyle(.white).font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.black.opacity(0.85), in: Capsule())
        .transition(.opacity)
    }

    private func flashToast(_ text: String) {
        toastText = text
        withAnimation(.easeIn(duration: 0.15)) { showToast = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.15)) { showToast = false }
        }
    }

    /// The editor produced a copy: send it as a new message, then leave the
    /// pager after a moment so the toast is readable.
    private func sendEdited(_ image: UIImage, sourceMessage: MessagePayload) {
        if let error = model.sendEditedImage(image, originalName: sourceMessage.file?.name,
                                             sourceMessage: sourceMessage) {
            flashToast(error)
            return
        }
        flashToast("已发送编辑后的图片")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            dismiss()
        }
    }

    @ViewBuilder private func page(for message: MessagePayload, isCurrent: Bool) -> some View {
        let mediaType = message.file?.mediaType ?? ""
        let name = message.file?.name ?? ""
        if PreviewRouter.isImage(mediaType, name: name) {
            if case .some(.some(let decoded)) = model.images[message.id] {
                ImageViewer(image: decoded, name: name, mediaType: mediaType,
                            load: { await model.fileData(for: message) },
                            loadFileURL: { await model.fileURL(for: message) },
                            // The top-right grid control already exists;
                            // don't display a second one in the action strip.
                            onOpenGallery: nil, onClose: onCloseViewer,
                            onVerticalDrag: { verticalDrag = $0 },
                            onEditFinished: { edited in sendEdited(edited, sourceMessage: message) })
            } else {
                Color.black.overlay { ProgressView() }
                    .task { await model.loadImage(for: message) }
            }
        } else if PreviewRouter.isVideo(mediaType, name: name) {
            // Keep the same hosting page when the TabView selection changes.
            // Swapping an offscreen thumbnail for an entirely different
            // VideoPlayerView during an interactive swipe caused the visible
            // snap-back, even though currentIndex had advanced correctly.
            ZStack {
                Color.black
                if let url = videoURLs[message.id] {
                    VideoPlayerView(url: url, name: name, mediaType: mediaType,
                                    isActive: isCurrent,
                                    onClose: onCloseViewer,
                                    onVerticalDrag: { verticalDrag = $0 },
                                    onHorizontalSwipe: { distance in
                                        // A real AVPlayerLayer may swallow the parent
                                        // TabView pan. Change exactly one page here,
                                        // unless TabView already moved it itself.
                                        guard currentIndex == index else { return }
                                        let next = index + (distance < 0 ? 1 : -1)
                                        guard messages.indices.contains(next) else { return }
                                        withAnimation(.easeOut(duration: 0.24)) {
                                            currentIndex = next
                                        }
                                    })
                } else {
                    Group {
                        if case .some(.some(let thumbnail)) = model.videoThumbnails[message.id] {
                            Image(uiImage: thumbnail).resizable().scaledToFit()
                        } else {
                            ProgressView().tint(.white)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: isCurrent) {
                if isCurrent && videoURLs[message.id] == nil {
                    await prepareVideo(message)
                }
            }
        } else {
            Color.black
        }
    }

    private func prepareVideo(_ message: MessagePayload) async {
        guard let url = await model.fileURL(for: message) else { return }
        videoURLs[message.id] = url
    }
}
