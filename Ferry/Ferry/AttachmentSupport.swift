import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A compact row of round icon buttons for an attachment: 保存 (save), 分享
/// (share), 复制 (copy). For non-media files the save action opens the system
/// "Save to Files" exporter; for images/videos it writes to the photo library.
/// The buttons keep their own busy/sheet state so they can be embedded both in
/// a message row and in the full-screen viewer.
struct AttachmentActions: View {
    let name: String
    let mediaType: String
    let load: () async -> Data?
    var tint: Color = .primary

    @State private var busy = false
    @State private var exporting = false
    @State private var document: ExportedFile?
    @State private var shareItem: ShareItem?
    @State private var copied = false

    private var isImageOrVideo: Bool {
        mediaType.hasPrefix("image/") || mediaType.hasPrefix("video/")
    }

    private var contentType: UTType {
        UTType(mimeType: mediaType) ?? UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { Task { await save() } } label: {
                icon("square.and.arrow.down")
            }
            .disabled(busy)
            .accessibilityLabel(isImageOrVideo ? "保存" : "保存到文件")

            Button { Task { await share() } } label: {
                icon("square.and.arrow.up")
            }
            .disabled(busy)
            .accessibilityLabel("分享")

            Button { Task { await copy() } } label: {
                icon(copied ? "checkmark" : "doc.on.doc")
            }
            .disabled(busy)
            .accessibilityLabel("复制")
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: contentType, defaultFilename: name) { _ in
            document = nil
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
    }

    private func icon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .frame(width: 30, height: 30)
            .background(Color.secondary.opacity(0.15), in: Circle())
            .foregroundStyle(tint)
    }

    private func save() async {
        busy = true
        defer { busy = false }
        guard let data = await load() else { return }
        if isImageOrVideo {
            try? await PhotoSaver.save(data, mediaType: mediaType)
        } else {
            document = ExportedFile(data: data)
            exporting = true
        }
    }

    private func share() async {
        busy = true
        defer { busy = false }
        guard let data = await load() else { return }
        if let url = AttachmentSupport.writeTemporaryFile(data, name: name) {
            shareItem = ShareItem(url: url)
        }
    }

    private func copy() async {
        busy = true
        defer { busy = false }
        if mediaType.hasPrefix("image/") {
            guard let data = await load(), let image = UIImage(data: data) else { return }
            UIPasteboard.general.image = image
        } else {
            guard let data = await load(), let url = AttachmentSupport.writeTemporaryFile(data, name: name) else { return }
            UIPasteboard.general.url = url
        }
        copied = true
        try? await Task.sleep(for: .seconds(1.4))
        copied = false
    }
}

enum AttachmentSupport {
    static func writeTemporaryFile(_ data: Data, name: String) -> URL? {
        let leaf = (name as NSString).lastPathComponent
        let safe = leaf.isEmpty ? "file" : leaf
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

struct ExportedFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
