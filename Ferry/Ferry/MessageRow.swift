import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MessageRow: View {
    let message: MessagePayload
    let image: UIImage??
    let loadImage: () async -> Void
    let loadFile: () async -> Data?
    let isCurrent: Bool

    @State private var copied = false
    @State private var viewing = false
    @State private var exporting = false
    @State private var exportDocument: ExportedFile?
    @State private var shareItem: ShareItem?
    @State private var showToast = false
    @State private var toastText = ""

    private var isImage: Bool { message.file?.mediaType.hasPrefix("image/") == true }
    private var isImageOrVideo: Bool {
        let mime = message.file?.mediaType ?? ""
        return mime.hasPrefix("image/") || mime.hasPrefix("video/")
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
        VStack(alignment: isCurrent ? .trailing : .leading, spacing: 6) {
            metaRow
            content
            if isImage, message.file != nil, imageLoaded {
                mediaActionRow
            }
        }
        .frame(maxWidth: .infinity, alignment: isCurrent ? .trailing : .leading)
        .overlay { if showToast { toastView } }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: fileContentType,
                      defaultFilename: message.file?.name ?? "文件") { result in
            exportDocument = nil
            if case .success = result { flashToast("已保存") }
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        .fullScreenCover(isPresented: $viewing) {
            if case .some(.some(let decoded)) = image {
                ImageViewer(image: decoded, name: message.file?.name ?? "图片",
                            mediaType: message.file?.mediaType ?? "image/jpeg", load: loadFile)
            }
        }
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            Image(systemName: message.deviceIcon)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(isCurrent ? Color.accentColor : .incomingBubble,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .foregroundStyle(isCurrent ? .white : .primary)
        } else if isImage, let file = message.file {
            switch image {
            case .some(.some(let decoded)):
                Image(uiImage: decoded)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onTapGesture { viewing = true }
                    .contextMenu { mediaMenu }
            case .some(.none):
                FileCard(file: file, isCurrent: isCurrent,
                         onSave: { Task { await save() } },
                         onShare: { Task { await share() } })
            case .none:
                RoundedRectangle(cornerRadius: 18).fill(.quaternary)
                    .frame(width: 176, height: 118)
                    .overlay { ProgressView() }
                    .task { await loadImage() }
            }
        } else if let file = message.file {
            FileCard(file: file, isCurrent: isCurrent,
                     onSave: { Task { await save() } },
                     onShare: { Task { await share() } })
        }
    }

    private var mediaActionRow: some View {
        HStack(spacing: 10) {
            RoundActionButton(systemName: "square.and.arrow.down", label: "保存",
                              background: Color(.systemFill)) { Task { await save() } }
            RoundActionButton(systemName: "square.and.arrow.up", label: "分享",
                              background: Color(.systemFill)) { Task { await share() } }
        }
    }

    @ViewBuilder private var mediaMenu: some View {
        Button { Task { await save() } } label: { Label("保存", systemImage: "square.and.arrow.down") }
        Button { Task { await share() } } label: { Label("分享", systemImage: "square.and.arrow.up") }
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

    private func save() async {
        guard let data = await loadFile() else { return }
        if isImageOrVideo {
            do {
                try await PhotoSaver.save(data, mediaType: message.file?.mediaType ?? "image/jpeg")
                flashToast("已保存到相册")
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

    private func flashToast(_ text: String) {
        toastText = text
        withAnimation(.easeIn(duration: 0.15)) { showToast = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.15)) { showToast = false }
        }
    }
}

private struct FileCard: View {
    let file: FileInfo
    let isCurrent: Bool
    let onSave: () -> Void
    let onShare: () -> Void

    private var isVideo: Bool { file.mediaType.hasPrefix("video/") }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isVideo ? "film.fill" : "doc.fill")
                .foregroundStyle(isCurrent ? .white : .cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? .white : .primary)
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(isCurrent ? .white.opacity(0.8) : .secondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                RoundActionButton(systemName: isVideo ? "square.and.arrow.down" : "folder",
                                  label: isVideo ? "保存" : "保存到文件",
                                  tint: isCurrent ? .white : .primary,
                                  background: isCurrent ? .white.opacity(0.2) : Color(.systemFill),
                                  action: onSave)
                RoundActionButton(systemName: "square.and.arrow.up", label: "分享",
                                  tint: isCurrent ? .white : .primary,
                                  background: isCurrent ? .white.opacity(0.2) : Color(.systemFill),
                                  action: onShare)
            }
        }
        .padding(14)
        .background(isCurrent ? Color.accentColor : .incomingBubble,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contextMenu {
            Button(action: onSave) {
                Label(isVideo ? "保存" : "保存到文件", systemImage: isVideo ? "square.and.arrow.down" : "folder")
            }
            Button(action: onShare) { Label("分享", systemImage: "square.and.arrow.up") }
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
