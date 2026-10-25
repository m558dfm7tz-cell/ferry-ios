import SwiftUI
import UIKit

/// Toolbar "收藏" page: every locally favorited message, tappable into the same
/// preview used by the timeline. Favorites are phone-local only.
struct FavoritesView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var previewItem: MessagePreview?

    var body: some View {
        NavigationStack {
            ScrollView {
                if model.localStore.favorites.isEmpty {
                    ContentUnavailableView("暂无收藏", systemImage: "star",
                                           description: Text("长按消息并选择「收藏」后，会显示在这里。"))
                        .padding(.top, 120)
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(model.localStore.favorites) { favorite in
                            FavoriteRow(favorite: favorite,
                                        localURL: localURL(for: favorite),
                                        onOpen: { await open(favorite) },
                                        onUnfavorite: { await model.toggleFavorite(favorite.message) })
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
        }
        .fullScreenCover(item: $previewItem) { preview in previewView(for: preview) }
    }

    @MainActor
    private func localURL(for favorite: FavoriteMessage) -> URL? {
        guard let name = favorite.localFileName else { return nil }
        return model.localStore.favoriteFileURL(for: name)
    }

    @MainActor
    private func open(_ favorite: FavoriteMessage) async {
        guard let preview = await Self.makePreview(for: favorite, model: model) else { return }
        previewItem = preview
    }

    @ViewBuilder private func previewView(for preview: MessagePreview) -> some View {
        switch preview.kind {
        case .image:
            if let image = preview.image {
                ImageViewer(image: image, name: preview.name, mediaType: preview.mediaType,
                            load: {
                                if let url = preview.url { return try? Data(contentsOf: url) }
                                return nil
                            })
            }
        case .video:
            if let url = preview.url {
                VideoPlayerView(url: url, name: preview.name, mediaType: preview.mediaType)
            }
        case .audio:
            if let url = preview.url {
                AudioPlayerView(url: url, name: preview.name, mediaType: preview.mediaType)
            }
        case .document:
            if let url = preview.url {
                DocumentPreviewView(url: url)
            }
        case .text:
            if let text = preview.text {
                TextFileView(text: text, name: preview.name)
            }
        }
    }

    @MainActor
    private static func makePreview(for favorite: FavoriteMessage, model: AppModel) async -> MessagePreview? {
        let message = favorite.message
        if let text = message.text {
            return MessagePreview(kind: .text, name: "文本", mediaType: "text/plain", text: text)
        }
        guard let file = message.file else { return nil }
        let mediaType = file.mediaType

        let data: Data?
        if let localName = favorite.localFileName {
            data = try? Data(contentsOf: model.localStore.favoriteFileURL(for: localName))
        } else {
            data = await model.fileData(for: message)
        }
        guard let data = data else { return nil }

        if PreviewRouter.isImage(mediaType) {
            guard let image = UIImage(data: data) else { return nil }
            let localURL = favorite.localFileName.map { model.localStore.favoriteFileURL(for: $0) }
            return MessagePreview(kind: .image, name: file.name, mediaType: mediaType, url: localURL, image: image)
        } else if PreviewRouter.isVideo(mediaType, name: file.name) {
            guard let url = PreviewRouter.temporaryURL(for: data, name: file.name, mediaType: mediaType) else { return nil }
            return MessagePreview(kind: .video, name: file.name, mediaType: mediaType, url: url)
        } else if PreviewRouter.isAudio(mediaType) {
            guard let url = PreviewRouter.temporaryURL(for: data, name: file.name, mediaType: mediaType) else { return nil }
            return MessagePreview(kind: .audio, name: file.name, mediaType: mediaType, url: url)
        } else if PreviewRouter.isPlainText(file) {
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? "无法解码文本。"
            return MessagePreview(kind: .text, name: file.name, mediaType: mediaType, text: text)
        } else {
            guard let url = PreviewRouter.temporaryURL(for: data, name: file.name, mediaType: mediaType) else { return nil }
            return MessagePreview(kind: .document, name: file.name, mediaType: mediaType, url: url)
        }
    }
}

private struct FavoriteRow: View {
    let favorite: FavoriteMessage
    let localURL: URL?
    let onOpen: () async -> Void
    let onUnfavorite: () async -> Void

    private var message: MessagePayload { favorite.message }
    private var mediaType: String { message.file?.mediaType ?? "" }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(message.displayDeviceName).font(.caption).foregroundStyle(.secondary)
                contentLine
                Text(message.timeText).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button { Task { await onUnfavorite() } } label: {
                Image(systemName: "star.fill").foregroundStyle(.yellow)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消收藏")
        }
        .padding(12)
        .background(Color.incomingBubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { Task { await onOpen() } }
        .contextMenu {
            Button { Task { await onOpen() } } label: { Label("打开", systemImage: "arrow.up.left.and.arrow.down.right") }
            Button(role: .destructive) { Task { await onUnfavorite() } } label: { Label("取消收藏", systemImage: "star.slash") }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if PreviewRouter.isImage(mediaType), let image = thumbnailImage {
            Image(uiImage: image)
                .resizable().scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.systemGray5))
                .frame(width: 56, height: 56)
                .overlay { iconForType }
        }
    }

    @ViewBuilder private var iconForType: some View {
        if PreviewRouter.isVideo(mediaType, name: message.file?.name ?? "") {
            Image(systemName: "play.circle.fill").font(.title).foregroundStyle(.white)
        } else if PreviewRouter.isAudio(mediaType) {
            Image(systemName: "waveform").font(.title2).foregroundStyle(.secondary)
        } else if message.text != nil {
            Image(systemName: "text.alignleft").font(.title2).foregroundStyle(.secondary)
        } else {
            Image(systemName: "doc.fill").font(.title2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var contentLine: some View {
        if let text = message.text {
            Text(text).font(.body).lineLimit(3)
        } else if let file = message.file {
            Text(file.name).font(.body.weight(.medium)).lineLimit(2)
        }
    }

    private var thumbnailImage: UIImage? {
        guard let localURL else { return nil }
        return UIImage(contentsOfFile: localURL.path)
    }
}
