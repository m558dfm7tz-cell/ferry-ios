import SwiftUI

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

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 3)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if model.mediaMessages.isEmpty {
                    ContentUnavailableView("暂无媒体", systemImage: "photo.on.rectangle.angled",
                                           description: Text("图片和视频消息会显示在这里。"))
                        .padding(.top, 120)
                } else {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(model.mediaMessages) { message in
                            cell(for: message)
                        }
                    }
                    .padding(3)
                }
            }
            .navigationTitle("媒体")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
        }
        .onAppear {
            guard let id = initialMessageID,
                  let message = model.mediaMessages.first(where: { $0.id == id }) else { return }
            selectedMessage = message
        }
        .fullScreenCover(item: $selectedMessage) { message in
            MediaPagerView(messages: model.mediaMessages, startID: message.id, model: model)
        }
    }

    @ViewBuilder private func cell(for message: MessagePayload) -> some View {
        if PreviewRouter.isImage(message.file?.mediaType ?? "") {
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
                if PreviewRouter.isImage(message.file?.mediaType ?? "") {
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

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var videoURLs: [String: URL] = [:]

    init(messages: [MessagePayload], startID: String, model: AppModel) {
        self.messages = messages
        self.model = model
        _currentIndex = State(initialValue: messages.firstIndex(where: { $0.id == startID }) ?? 0)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $currentIndex) {
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    page(for: message)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.15), in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回网格")
            .padding(.top, 4)
        }
        .statusBarHidden()
    }

    @ViewBuilder private func page(for message: MessagePayload) -> some View {
        let mediaType = message.file?.mediaType ?? ""
        let name = message.file?.name ?? ""
        if PreviewRouter.isImage(mediaType) {
            if case .some(.some(let decoded)) = model.images[message.id] {
                ImageViewer(image: decoded, name: name, mediaType: mediaType,
                            load: { await model.fileData(for: message) })
            } else {
                Color.black.overlay { ProgressView() }
                    .task { await model.loadImage(for: message) }
            }
        } else if PreviewRouter.isVideo(mediaType, name: name) {
            if let url = videoURLs[message.id] {
                VideoPlayerView(url: url, name: name, mediaType: mediaType)
            } else {
                Color.black.overlay { ProgressView() }
                    .task { await prepareVideo(message) }
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
