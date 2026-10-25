import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MessageRow: View {
    let message: MessagePayload
    let image: UIImage??
    let loadImage: () async -> Void
    let loadFile: () async -> Data?
    @State private var copied = false
    @State private var viewing = false

    private var isImage: Bool { message.file?.mediaType.hasPrefix("image/") == true }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(message.senderName.prefix(1)).uppercased())
                .font(.caption.bold()).frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.18), in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(message.senderName).font(.subheadline.bold())
                    if let text = message.text {
                        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            copy(text)
                        }
                        .labelStyle(.titleOnly).font(.caption).buttonStyle(.plain)
                        .foregroundStyle(.secondary).accessibilityIdentifier("copy-message")
                    }
                }
                if let text = message.text {
                    Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("message-text")
                } else if isImage, let file = message.file {
                    switch image {
                    case .some(.some(let decoded)):
                        Image(uiImage: decoded).resizable().scaledToFit()
                            .frame(maxWidth: 260, maxHeight: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .onTapGesture { viewing = true }
                            .accessibilityIdentifier("message-image")
                            .accessibilityLabel(file.name)
                    case .some(.none):
                        FileCard(file: file, load: loadFile)
                    case .none:
                        RoundedRectangle(cornerRadius: 18).fill(.quaternary)
                            .frame(width: 176, height: 118)
                            .overlay { ProgressView() }
                            .task { await loadImage() }
                    }
                } else if let file = message.file {
                    FileCard(file: file, load: loadFile)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .fullScreenCover(isPresented: $viewing) {
            if case .some(.some(let decoded)) = image {
                ImageViewer(image: decoded, name: message.file?.name ?? "image",
                            mediaType: message.file?.mediaType ?? "image/jpeg", load: loadFile)
            }
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }
}

private struct FileCard: View {
    let file: FileInfo
    let load: () async -> Data?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.mediaType.hasPrefix("video/") ? "film.fill" : "doc.fill").foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.body.weight(.medium)).lineLimit(1)
                    .accessibilityIdentifier("message-file-name")
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            AttachmentActions(name: file.name, mediaType: file.mediaType, load: load)
        }
        .padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ImageViewer: View {
    let image: UIImage
    let name: String
    let mediaType: String
    let load: () async -> Data?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image).resizable().scaledToFit().ignoresSafeArea()
        }
        .onTapGesture { dismiss() }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 12) {
                AttachmentActions(name: name, mediaType: mediaType, load: load)
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly).buttonStyle(.bordered)
            }
            .padding(20)
        }
    }
}

/// Fetches attachment bytes on demand and offers the system export actions:
/// save-to-Photos for image/video, Save to Files for everything else, and a
/// share sheet for any file.
private struct AttachmentActions: View {
    let name: String
    let mediaType: String
    let load: () async -> Data?
    @State private var busy = false
    @State private var document: ExportedFile?
    @State private var exporting = false
    @State private var shareItem: ShareItem?

    private var isImageOrVideo: Bool {
        mediaType.hasPrefix("image/") || mediaType.hasPrefix("video/")
    }

    private var contentType: UTType {
        UTType(mimeType: mediaType) ?? UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
    }

    var body: some View {
        HStack(spacing: 14) {
            if isImageOrVideo {
                Button {
                    Task {
                        busy = true
                        defer { busy = false }
                        guard let data = await load() else { return }
                        try? await PhotoSaver.save(data, mediaType: mediaType)
                    }
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down.on.square")
                }
                .labelStyle(.titleOnly).font(.caption).buttonStyle(.plain)
                .disabled(busy).accessibilityIdentifier("save-photo")
            } else {
                Button {
                    Task {
                        busy = true
                        defer { busy = false }
                        guard let data = await load() else { return }
                        document = ExportedFile(data: data)
                        exporting = true
                    }
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .labelStyle(.titleOnly).font(.caption).buttonStyle(.plain)
                .disabled(busy).accessibilityIdentifier("save-file")
                .fileExporter(isPresented: $exporting, document: document,
                              contentType: contentType, defaultFilename: name) { _ in
                    document = nil
                }
            }
            Button {
                Task {
                    busy = true
                    defer { busy = false }
                    guard let data = await load() else { return }
                    if let url = writeTemporaryFile(data, name: name) { shareItem = ShareItem(url: url) }
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.titleOnly).font(.caption).buttonStyle(.plain)
            .disabled(busy).accessibilityIdentifier("share-file")
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
    }

    private func writeTemporaryFile(_ data: Data, name: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory
        let safeName = (name as NSString).lastPathComponent.isEmpty ? "file" : (name as NSString).lastPathComponent
        let url = directory.appendingPathComponent(safeName)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

private struct ExportedFile: FileDocument {
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

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
