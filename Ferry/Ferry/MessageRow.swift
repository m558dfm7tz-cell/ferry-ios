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
    @State private var busy = false
    @State private var exporting = false
    @State private var exportDocument: ExportedFile?
    @State private var shareItem: ShareItem?

    private var isImage: Bool { message.file?.mediaType.hasPrefix("image/") == true }
    private var isImageOrVideo: Bool {
        let mime = message.file?.mediaType ?? ""
        return mime.hasPrefix("image/") || mime.hasPrefix("video/")
    }

    private var fileContentType: UTType {
        let mime = message.file?.mediaType ?? "application/octet-stream"
        let name = message.file?.name ?? ""
        return UTType(mimeType: mime) ?? UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if !isCurrent { avatar }
            VStack(alignment: isCurrent ? .trailing : .leading, spacing: 6) {
                header
                content
                if message.file != nil { AttachmentActions(name: message.file?.name ?? "文件",
                                                           mediaType: message.file?.mediaType ?? "application/octet-stream",
                                                           load: loadFile) }
            }
            .frame(maxWidth: .infinity, alignment: isCurrent ? .trailing : .leading)
            if isCurrent { avatar }
        }
        .contextMenu {
            if message.file != nil { attachmentMenu }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: fileContentType,
                      defaultFilename: message.file?.name ?? "文件") { _ in
            exportDocument = nil
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        .fullScreenCover(isPresented: $viewing) {
            if case .some(.some(let decoded)) = image {
                ImageViewer(image: decoded, name: message.file?.name ?? "图片",
                            mediaType: message.file?.mediaType ?? "image/jpeg", load: loadFile)
            }
        }
    }

    private var avatar: some View {
        Text(String(message.senderName.prefix(1)).uppercased())
            .font(.caption.bold())
            .frame(width: 28, height: 28)
            .background(Color.accentColor.opacity(0.18), in: Circle())
    }

    private var header: some View {
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
            Spacer(minLength: 12)
            Button {
                Task { await copy() }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(copied ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("复制")
            .animation(.easeInOut(duration: 0.15), value: copied)
        }
    }

    @ViewBuilder private var content: some View {
        if let text = message.text {
            LinkedText(text: text, linkColor: isCurrent ? .white : .blue)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(isCurrent ? Color.accentColor : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .foregroundStyle(isCurrent ? .white : .primary)
        } else if isImage, let file = message.file {
            switch image {
            case .some(.some(let decoded)):
                Image(uiImage: decoded)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onTapGesture { viewing = true }
            case .some(.none):
                FileCard(file: file)
            case .none:
                RoundedRectangle(cornerRadius: 18).fill(.quaternary)
                    .frame(width: 176, height: 118)
                    .overlay { ProgressView() }
                    .task { await loadImage() }
            }
        } else if let file = message.file {
            FileCard(file: file)
        }
    }

    @ViewBuilder private var attachmentMenu: some View {
        if isImageOrVideo {
            Button { Task { await saveToPhotos() } } label: { Label("保存", systemImage: "square.and.arrow.down") }
        } else {
            Button { Task { await saveToFiles() } } label: { Label("保存到文件", systemImage: "folder") }
        }
        Button { Task { await share() } } label: { Label("分享", systemImage: "square.and.arrow.up") }
        Button { Task { await copy() } } label: { Label("复制", systemImage: "doc.on.doc") }
    }

    private func saveToPhotos() async {
        busy = true
        defer { busy = false }
        guard let data = await loadFile() else { return }
        try? await PhotoSaver.save(data, mediaType: message.file?.mediaType ?? "image/jpeg")
    }

    private func saveToFiles() async {
        busy = true
        defer { busy = false }
        guard let data = await loadFile() else { return }
        exportDocument = ExportedFile(data: data)
        exporting = true
    }

    private func share() async {
        busy = true
        defer { busy = false }
        guard let data = await loadFile() else { return }
        if let url = AttachmentSupport.writeTemporaryFile(data, name: message.file?.name ?? "文件") {
            shareItem = ShareItem(url: url)
        }
    }

    private func copy() async {
        if let text = message.text {
            UIPasteboard.general.string = text
        } else if isImage {
            if case .some(.some(let decoded)) = image {
                UIPasteboard.general.image = decoded
            } else if let data = await loadFile(), let decoded = UIImage(data: data) {
                UIPasteboard.general.image = decoded
            } else {
                return
            }
        } else if let file = message.file {
            guard let data = await loadFile(), let url = AttachmentSupport.writeTemporaryFile(data, name: file.name) else { return }
            UIPasteboard.general.url = url
        } else {
            return
        }
        copied = true
        try? await Task.sleep(for: .seconds(1.6))
        copied = false
    }
}

private struct FileCard: View {
    let file: FileInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.mediaType.hasPrefix("video/") ? "film.fill" : "doc.fill").foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.body.weight(.medium)).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
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
