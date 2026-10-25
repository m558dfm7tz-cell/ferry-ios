import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A compact row of large round icon buttons for an attachment: 保存 (save)
/// and 分享 (share). For non-media files the save action opens the system
/// "Save to Files" exporter; for images/videos it writes to the photo library.
/// The buttons keep their own busy/sheet state so they can be embedded both in
/// a message row and in the full-screen viewer.
struct AttachmentActions: View {
    let name: String
    let mediaType: String
    let load: () async -> Data?
    var tint: Color = .primary
    var onToast: ((String) -> Void)? = nil

    @State private var busy = false
    @State private var exporting = false
    @State private var document: ExportedFile?
    @State private var shareItem: ShareItem?

    private var isImageOrVideo: Bool {
        mediaType.hasPrefix("image/") || mediaType.hasPrefix("video/")
    }

    private var contentType: UTType {
        UTType(mimeType: mediaType) ?? UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { Task { await save() } } label: {
                icon(isImageOrVideo ? "square.and.arrow.down" : "folder")
            }
            .disabled(busy)
            .accessibilityLabel(isImageOrVideo ? "保存" : "保存到文件")

            Button { Task { await share() } } label: {
                icon("square.and.arrow.up")
            }
            .disabled(busy)
            .accessibilityLabel("分享")
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: contentType, defaultFilename: name) { result in
            document = nil
            if case .success = result { onToast?("已保存") }
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
    }

    private func icon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .medium))
            .frame(width: 36, height: 36)
            .background(Color.white.opacity(0.15), in: Circle())
            .foregroundStyle(tint)
    }

    private func save() async {
        busy = true
        defer { busy = false }
        guard let data = await load() else { return }
        if isImageOrVideo {
            do {
                try await PhotoSaver.save(data, mediaType: mediaType)
                onToast?("已保存到相册")
            } catch {
                onToast?("保存失败")
            }
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
