import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Chat bubbles are capped at ~75% of the screen width so there is always
/// blank space beside them to tap (for keyboard dismissal).
private var maxChatBubbleWidth: CGFloat {
    UIScreen.main.bounds.width * 0.75
}

struct MessageRow: View {
    let message: MessagePayload
    let image: UIImage??
    let videoThumbnail: UIImage??
    let videoDuration: Double
    let loadImage: () async -> Void
    let loadVideoThumbnail: () async -> Void
    let loadFile: () async -> Data?
    let loadFileURL: () async -> URL?
    let isCurrent: Bool
    let isFavorite: Bool
    let onToggleFavorite: () async -> Void
    let copyTemporaryLink: () async -> String?
    let onOpenGallery: () -> Void
    /// Sends the edited copy produced from this message's image preview.
    let onSendEditedImage: (UIImage) -> Void
    let selectionMode: Bool
    let isSelected: Bool
    let isHighlighted: Bool
    let onToggleSelection: () -> Void
    let assistant: Assistant?
    /// Custom avatar media for that assistant (nil = default letter disc).
    let assistantMedia: AssistantAvatarMedia?

    @State private var copied = false
    @State private var saved = false
    @State private var exporting = false
    @State private var exportDocument: ExportedFile?
    @State private var shareItem: ShareItem?
    @State private var previewItem: MessagePreview?
    @State private var showToast = false
    @State private var toastText = ""

    private var isImage: Bool { message.file?.mediaType.hasPrefix("image/") == true }
    private var isVideo: Bool {
        guard let file = message.file else { return false }
        return PreviewRouter.isVideo(file)
    }
    private var isImageOrVideo: Bool {
        let file = message.file
        let mime = file?.mediaType ?? ""
        let name = file?.name ?? ""
        return PreviewRouter.isImage(mime) || PreviewRouter.isVideo(mime, name: name)
    }
    private var imageLoaded: Bool {
        if case .some(.some(_)) = image { return true }
        return false
    }

    private var fileContentType: UTType {
        let mime = message.file?.mediaType ?? "application/octet-stream"
        let name = message.file?.name ?? ""
        return UTType(mimeType: mime) ?? UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if selectionMode { selectionIndicator }
            if let assistant, !isCurrent {
                AssistantAvatarView(assistant: assistant, size: 32, media: assistantMedia)
                    .padding(.bottom, 1)
            }
            VStack(alignment: isCurrent ? .trailing : .leading, spacing: 6) {
                metaRow
                content
                if (isImage && imageLoaded) || isVideo {
                    mediaActionRow
                }
            }
            .frame(maxWidth: .infinity, alignment: isCurrent ? .trailing : .leading)
        }
        .overlay { if showToast { toastView } }
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.yellow.opacity(0.25))
            }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: fileContentType,
                      defaultFilename: message.file?.name ?? "文件") { result in
            exportDocument = nil
            if case .success = result {
                flashToast("已保存")
                flashSaved()
            }
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        .fullScreenCover(item: $previewItem) { preview in previewView(for: preview) }
    }

    @ViewBuilder private func previewView(for preview: MessagePreview) -> some View {
        switch preview.kind {
        case .image:
            if let image = preview.image {
                ImageViewer(image: image, name: preview.name, mediaType: preview.mediaType,
                            load: loadFile, onOpenGallery: openMediaGalleryFromPreview,
                            onEditFinished: sendEditedFromPreview)
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

    private var selectionIndicator: some View {
        Button { onToggleSelection() } label: {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : Color(.systemGray))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelected ? "取消选择" : "选择")
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            // The avatar disc already identifies an assistant, so the small
            // device-kind icon is hidden for assistant messages.
            if assistant == nil {
                Image(systemName: message.deviceIcon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(message.displayDeviceName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("·")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(message.timeText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if message.text != nil {
                copyButton
            }
        }
    }

    /// Web-style rounded-square copy button (text messages only), shown in the
    /// meta row right after icon + name + time, with check-mark animation.
    private var copyButton: some View {
        Button {
            Task { await copyText() }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(copied ? .green : .secondary)
                .frame(width: 30, height: 30)
                .background(Color(.systemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("复制")
        .animation(.easeInOut(duration: 0.15), value: copied)
    }

    @ViewBuilder private var content: some View {
        if let text = message.text {
            LinkedText(text: text, linkColor: isCurrent ? .white : .blue)
                .textSelection(.enabled)
                .frame(maxWidth: maxChatBubbleWidth, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(isCurrent ? Color.accentColor : .incomingBubble,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .foregroundStyle(isCurrent ? .white : .primary)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contextMenu { textMenu }
        } else if isImage, let file = message.file {
            switch image {
            case .some(.some(let decoded)):
                imageBubble(decoded, file: file)
            case .some(.none):
                FileCard(file: file, isCurrent: isCurrent, isFavorite: isFavorite, saved: saved,
                         onOpen: openFile,
                         onSave: { Task { await save() } },
                         onShare: { Task { await share() } },
                         onFavorite: { Task { await onToggleFavorite() } },
                         onCopyLink: { await copyTemporaryLink() })
            case .none:
                RoundedRectangle(cornerRadius: 18).fill(.quaternary)
                    .frame(width: 176, height: 118)
                    .overlay { ProgressView() }
                    .task { await loadImage() }
            }
        } else if isVideo, let file = message.file {
            switch videoThumbnail {
            case .some(.some(let thumbnail)):
                videoBubble(thumbnail: thumbnail, file: file)
            case .some(.none):
                // Thumbnail failed: show a dark placeholder with a play icon and
                // duration rather than degrading to a plain file card.
                videoBubble(thumbnail: nil, file: file)
            case .none:
                RoundedRectangle(cornerRadius: 18).fill(.quaternary)
                    .frame(width: 220, height: 150)
                    .overlay { ProgressView() }
                    .task { await loadVideoThumbnail() }
            }
        } else if let file = message.file {
            FileCard(file: file, isCurrent: isCurrent, isFavorite: isFavorite, saved: saved,
                     onOpen: openFile,
                     onSave: { Task { await save() } },
                     onShare: { Task { await share() } },
                     onFavorite: { Task { await onToggleFavorite() } },
                     onCopyLink: { await copyTemporaryLink() })
        }
    }

    @ViewBuilder private func imageBubble(_ decoded: UIImage, file: FileInfo) -> some View {
        Button {
            if !selectionMode {
                previewItem = MessagePreview(kind: .image, name: file.name,
                                             mediaType: file.mediaType, image: decoded)
            }
        } label: {
            Image(uiImage: decoded)
                .resizable().scaledToFit()
                .frame(maxWidth: 240, maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("bubble.image")
        .contextMenu { mediaMenu }
    }

    @ViewBuilder private func videoBubble(thumbnail: UIImage?, file: FileInfo) -> some View {
        Button {
            openFile()
        } label: {
            ZStack {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable().scaledToFill()
                } else {
                    Color(white: 0.16)
                }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 4)
            }
            .frame(width: 220, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if videoDuration > 0 {
                    Text(TimeText.mmss(videoDuration))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.black.opacity(0.6),
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("bubble.video")
        .contextMenu { mediaMenu }
    }

    private func openFile() {
        guard !selectionMode else { return }
        Task { await openFilePreview() }
    }

    /// Close the full-screen viewer first, then hand over to the chat-wide
    /// media gallery (all images + videos) from the timeline.
    private func openMediaGalleryFromPreview() {
        previewItem = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            onOpenGallery()
        }
    }

    /// The editor hands back an edited copy; close the preview and hand it to
    /// the timeline, which enqueues it as a new message.
    private func sendEditedFromPreview(_ image: UIImage) {
        previewItem = nil
        onSendEditedImage(image)
    }

    private var mediaActionRow: some View {
        HStack(spacing: 10) {
            RoundActionButton(systemName: saved ? "checkmark" : "square.and.arrow.down", label: "保存",
                              tint: saved ? .green : .primary,
                              background: Color(.systemFill)) { Task { await save() } }
            RoundActionButton(systemName: "square.and.arrow.up", label: "分享",
                              background: Color(.systemFill)) { Task { await share() } }
            RoundActionButton(systemName: "square.grid.2x2", label: "媒体",
                              background: Color(.systemFill)) { onOpenGallery() }
        }
        .animation(.easeInOut(duration: 0.15), value: saved)
    }

    @ViewBuilder private var mediaMenu: some View {
        Button { Task { await save() } } label: { Label("保存", systemImage: "square.and.arrow.down") }
        Button { Task { await share() } } label: { Label("分享", systemImage: "square.and.arrow.up") }
        Button { Task { await performCopyTemporaryLink() } } label: { Label("复制临时下载链接", systemImage: "link") }
        favoriteButton
    }

    @ViewBuilder private var textMenu: some View {
        Button { Task { await copyText() } } label: { Label("复制", systemImage: "doc.on.doc") }
        favoriteButton
    }

    @ViewBuilder private var favoriteButton: some View {
        Button { Task { await onToggleFavorite() } } label: {
            Label(isFavorite ? "取消收藏" : "收藏", systemImage: isFavorite ? "star.fill" : "star")
        }
    }

    private var toastView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(toastText).foregroundStyle(.white).font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.black.opacity(0.8), in: Capsule())
        .transition(.opacity)
    }

    private func openFilePreview() async {
        guard let file = message.file else { return }
        let mediaType = file.mediaType

        if PreviewRouter.isVideo(mediaType, name: file.name) {
            guard let url = await loadFileURL() else { return }
            previewItem = MessagePreview(kind: .video, name: file.name, mediaType: mediaType, url: url)
        } else if PreviewRouter.isAudio(mediaType) {
            guard let url = await loadFileURL() else { return }
            previewItem = MessagePreview(kind: .audio, name: file.name, mediaType: mediaType, url: url)
        } else if PreviewRouter.isPlainText(file) {
            guard let data = await loadFile() else { return }
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? "无法解码文本。"
            previewItem = MessagePreview(kind: .text, name: file.name, mediaType: mediaType, text: text)
        } else {
            guard let url = await loadFileURL() else { return }
            previewItem = MessagePreview(kind: .document, name: file.name, mediaType: mediaType, url: url)
        }
    }

    private func save() async {
        guard let data = await loadFile() else { return }
        if isImageOrVideo {
            do {
                try await PhotoSaver.save(data, mediaType: message.file?.mediaType ?? "image/jpeg",
                                          name: message.file?.name ?? "文件")
                flashToast("已保存到相册")
                flashSaved()
            } catch PhotoSaver.SaveError.incompatible {
                exportDocument = ExportedFile(data: data)
                exporting = true
            } catch {
                flashToast("保存失败")
            }
        } else {
            exportDocument = ExportedFile(data: data)
            exporting = true
        }
    }

    private func share() async {
        guard let data = await loadFile() else { return }
        if let url = AttachmentSupport.writeTemporaryFile(data, name: message.file?.name ?? "文件") {
            shareItem = ShareItem(url: url)
        }
    }

    private func copyText() async {
        guard let text = message.text else { return }
        UIPasteboard.general.string = text
        copied = true
        try? await Task.sleep(for: .seconds(1.6))
        copied = false
    }

    private func performCopyTemporaryLink() async {
        if let error = await copyTemporaryLink() {
            flashToast(error)
        } else {
            flashToast("已复制，约90秒内有效")
        }
    }

    private func flashToast(_ text: String) {
        toastText = text
        withAnimation(.easeIn(duration: 0.15)) { showToast = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.15)) { showToast = false }
        }
    }

    private func flashSaved() {
        saved = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            saved = false
        }
    }
}

private struct FileCard: View {
    let file: FileInfo
    let isCurrent: Bool
    let isFavorite: Bool
    let saved: Bool
    let onOpen: () -> Void
    let onSave: () -> Void
    let onShare: () -> Void
    let onFavorite: () -> Void
    let onCopyLink: () async -> String?

    @State private var showToast = false
    @State private var toastText = ""

    private var isVideo: Bool { PreviewRouter.isVideo(file) }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    FileTypeIconView(file: file)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(isCurrent ? .white : .primary)
                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(isCurrent ? .white.opacity(0.8) : .secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .padding(.trailing, 96)
                .background(isCurrent ? Color.accentColor : .incomingBubble,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                RoundActionButton(systemName: saved ? "checkmark" : (isVideo ? "square.and.arrow.down" : "folder"),
                                  label: isVideo ? "保存" : "保存到文件",
                                  tint: saved ? .green : (isCurrent ? .white : .primary),
                                  background: isCurrent ? .white.opacity(0.2) : Color(.systemFill),
                                  action: onSave)
                RoundActionButton(systemName: "square.and.arrow.up", label: "分享",
                                  tint: isCurrent ? .white : .primary,
                                  background: isCurrent ? .white.opacity(0.2) : Color(.systemFill),
                                  action: onShare)
            }
            .padding(.trailing, 14)
            .animation(.easeInOut(duration: 0.15), value: saved)
        }
        .frame(maxWidth: maxChatBubbleWidth, alignment: .leading)
        .overlay { if showToast { toastView } }
        .contextMenu {
            Button(action: onSave) {
                Label(isVideo ? "保存" : "保存到文件", systemImage: isVideo ? "square.and.arrow.down" : "folder")
            }
            Button(action: onShare) { Label("分享", systemImage: "square.and.arrow.up") }
            Button { Task { await copyLink() } } label: { Label("复制临时下载链接", systemImage: "link") }
            Button(action: onFavorite) {
                Label(isFavorite ? "取消收藏" : "收藏", systemImage: isFavorite ? "star.fill" : "star")
            }
        }
    }

    private var toastView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(toastText).foregroundStyle(.white).font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.black.opacity(0.8), in: Capsule())
        .transition(.opacity)
    }

    private func copyLink() async {
        if let error = await onCopyLink() {
            flashToast(error)
        } else {
            flashToast("已复制，约90秒内有效")
        }
    }

    private func flashToast(_ text: String) {
        toastText = text
        withAnimation(.easeIn(duration: 0.15)) { showToast = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.15)) { showToast = false }
        }
    }
}

private struct RoundActionButton: View {
    let systemName: String
    let label: String
    var tint: Color = .primary
    var background: Color = Color(.systemFill)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 36)
                .background(background, in: Circle())
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

extension Color {
    /// Chat background: #1C1C1E in dark mode, system grouped background in light.
    static let chatBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 28/255, green: 28/255, blue: 30/255, alpha: 1)
            : UIColor.systemGroupedBackground
    })

    /// Incoming bubble/card: #2C2C2E in dark mode, secondary grouped background in light.
    static let incomingBubble = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 44/255, green: 44/255, blue: 46/255, alpha: 1)
            : UIColor.secondarySystemGroupedBackground
    })
}

/// Text that auto-detects http(s):// and bare `www.` links via `NSDataDetector`
/// and renders them as tappable blue links (opened in the default browser).
private struct LinkedText: View {
    let text: String
    let linkColor: Color

    var body: some View {
        Text(attributed)
            .environment(\.openURL, OpenURLAction { url in .systemAction(url) })
    }

    private var attributed: AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return result
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector.matches(in: text, options: [], range: nsRange)
        for match in matches {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: text) else { continue }
            guard let lower = AttributedString.Index(stringRange.lowerBound, within: result),
                  let upper = AttributedString.Index(stringRange.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
            result[lower..<upper].foregroundColor = linkColor
            result[lower..<upper].underlineStyle = .single
        }
        return result
    }
}
