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
    var loadFileURL: (() async -> URL?)? = nil
    var tint: Color = .primary
    var onToast: ((String) -> Void)? = nil
    /// Optional extra entry rendered beside 保存/分享: opens the grid of every
    /// image and video in the current chat. Nil keeps the row unchanged.
    var onOpenGallery: (() -> Void)? = nil

    @State private var busy = false
    @State private var saved = false
    @State private var exporting = false
    @State private var document: ExportedFile?
    @State private var shareItem: ShareItem?

    private var isImageOrVideo: Bool {
        PreviewRouter.isImage(mediaType) || PreviewRouter.isVideo(mediaType, name: name)
    }

    private var contentType: UTType {
        UTType(mimeType: mediaType) ?? UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
    }

    var body: some View {
        HStack(spacing: 14) {
            if let onOpenGallery {
                Button(action: onOpenGallery) {
                    icon("square.grid.2x2")
                }
                .accessibilityLabel("全部图片和视频")
                .accessibilityIdentifier("viewer-open-gallery")
            }

            Button { Task { await save() } } label: {
                icon(saved ? "checkmark" : (isImageOrVideo ? "square.and.arrow.down" : "folder"),
                     tint: saved ? Color.green : nil)
            }
            .disabled(busy)
            .accessibilityLabel(isImageOrVideo ? "保存" : "保存到文件")
            .animation(.easeInOut(duration: 0.15), value: saved)

            Button { Task { await share() } } label: {
                icon("square.and.arrow.up")
            }
            .disabled(busy)
            .accessibilityLabel("分享")
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: contentType, defaultFilename: name) { result in
            document = nil
            if case .success = result {
                onToast?("已保存")
                flashSaved()
            }
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
    }

    /// Large (52pt) round action buttons with a 22pt icon, matching the
    /// enlarged preview chrome from T3.1 (>=44pt hit area).
    private func icon(_ systemName: String, tint iconTint: Color? = nil) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 22, weight: .medium))
            .frame(width: 52, height: 52)
            .background(Color.white.opacity(0.15), in: Circle())
            .foregroundStyle(iconTint ?? tint)
    }

    private func save() async {
        busy = true
        defer { busy = false }
        guard let data = await load() else { return }
        if isImageOrVideo {
            do {
                try await PhotoSaver.save(data, mediaType: mediaType, name: name)
                onToast?("已保存到相册")
                flashSaved()
            } catch PhotoSaver.SaveError.incompatible {
                document = ExportedFile(data: data)
                exporting = true
            } catch {
                onToast?("保存失败")
            }
        } else {
            document = ExportedFile(data: data)
            exporting = true
        }
    }

    private func flashSaved() {
        saved = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            saved = false
        }
    }

    private func share() async {
        busy = true
        defer { busy = false }
        if let loadFileURL {
            if let url = await loadFileURL() {
                shareItem = ShareItem(url: AttachmentSupport.namedShareURL(for: url, name: name))
            }
            return
        }
        guard let data = await load() else { return }
        if let url = AttachmentSupport.writeTemporaryFile(data, name: name) {
            shareItem = ShareItem(url: url)
        }
    }
}

enum AttachmentSupport {
    /// Preserve the original filename in the system share sheet without
    /// loading/rewriting the entire cached file. Linking is O(1) on APFS.
    static func namedShareURL(for cachedURL: URL, name: String) -> URL {
        let leaf = (name as NSString).lastPathComponent
        guard !leaf.isEmpty else { return cachedURL }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-share-" + UUID().uuidString, isDirectory: true)
        let target = directory.appendingPathComponent(leaf)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                try FileManager.default.linkItem(at: cachedURL, to: target)
            } catch {
                try FileManager.default.copyItem(at: cachedURL, to: target)
            }
            return target
        } catch {
            return cachedURL
        }
    }

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
