import UIKit
import UniformTypeIdentifiers

/// Native iOS share-sheet entry. The extension NEVER sends to the Ferry
/// server and does not have access to the app's credentials. It only stages
/// original files for a later destination-choice and confirmation in Ferry.
final class ShareViewController: UIViewController {
    private let heading = UILabel()
    private let message = UILabel()
    private let action = UIButton(type: .system)
    private var isWorking = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 340, height: 240)

        heading.text = "发送到 Ferry"
        heading.font = .preferredFont(forTextStyle: .title2)
        heading.textAlignment = .center

        message.text = "导入文件后，请打开 Ferry 选择对话并确认发送。\n不会自动发送给任何助手。"
        message.numberOfLines = 0
        message.textAlignment = .center
        message.textColor = .secondaryLabel
        message.font = .preferredFont(forTextStyle: .subheadline)

        action.setTitle("添加到 Ferry 待发送", for: .normal)
        action.configuration = .filled()
        action.addTarget(self, action: #selector(stageItems), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [heading, message, action])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -22),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])
    }

    @objc private func stageItems() {
        guard !isWorking else { return }
        isWorking = true
        action.isEnabled = false
        message.text = "正在准备分享内容…"
        Task { @MainActor in
            do {
                try await collectToInbox()
                message.text = "已保存。请打开 Ferry 选择对话并确认发送。"
                action.setTitle("完成", for: .normal)
                extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            } catch {
                message.text = "导入失败：\(error.localizedDescription)"
                action.isEnabled = true
                isWorking = false
            }
        }
    }

    private func collectToInbox() async throws {
        let groupID = "group.com.ferry.test.shared"
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID) else {
            throw ImportError.noSharedContainer
        }
        let root = container.appendingPathComponent("IncomingShares", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var entries: [ImportedEntry] = []
        do {
            for item in extensionContext?.inputItems ?? [] {
                guard let input = item as? NSExtensionItem else { continue }
                for provider in input.attachments ?? [] {
                    if let entry = try await importProvider(provider, into: dir) {
                        entries.append(entry)
                    }
                }
            }
            guard !entries.isEmpty else { throw ImportError.noSupportedItems }
            let batch = ImportedBatch(id: id, createdAt: Date(), entries: entries)
            let data = try JSONEncoder().encode(batch)
            try data.write(to: dir.appendingPathComponent("request.json"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    private func importProvider(_ provider: NSItemProvider, into dir: URL) async throws -> ImportedEntry? {
        // URLs from Safari are links; files from Files, Photos and other
        // applications are staged as original bytes whenever available.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let item = try? await loadItem(provider, type: UTType.fileURL.identifier),
           let source = item as? URL, source.isFileURL {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let ext = source.pathExtension.isEmpty ? "bin" : source.pathExtension
            let file = UUID().uuidString + "." + ext
            let dest = dir.appendingPathComponent(file)
            try FileManager.default.copyItem(at: source, to: dest)
            let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            return ImportedEntry(id: UUID().uuidString, kind: "file",
                                 name: source.lastPathComponent, mediaType: mime,
                                 filename: file, text: nil)
        }
        let registered = provider.registeredTypeIdentifiers
        let fileType = registered.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .movie) || type.conforms(to: .image) ||
                   type.conforms(to: .data) || type.conforms(to: .content)
        }

        if let fileType,
           let copy = try await loadAndCopyFile(provider, type: fileType, dir: dir) {
            return copy
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let link = try? await loadItem(provider, type: UTType.url.identifier) as? URL {
            return ImportedEntry(id: UUID().uuidString, kind: "text",
                                 name: "网页链接", mediaType: "text/plain",
                                 filename: nil, text: link.absoluteString)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let item = try? await loadItem(provider, type: UTType.plainText.identifier)
            let text = (item as? String) ?? (item as? NSString).map(String.init)
            if let text, !text.isEmpty {
                return ImportedEntry(id: UUID().uuidString, kind: "text",
                                     name: "分享文字", mediaType: "text/plain",
                                     filename: nil, text: text)
            }
        }
        return nil
    }

    private func loadAndCopyFile(_ provider: NSItemProvider, type: String,
                                 dir: URL) async throws -> ImportedEntry? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { source, error in
                guard let source else {
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: nil) }
                    return
                }
                do {
                    let ext = source.pathExtension.isEmpty
                        ? (UTType(type)?.preferredFilenameExtension ?? "bin")
                        : source.pathExtension
                    let base = (provider.suggestedName ?? source.deletingPathExtension().lastPathComponent)
                        .replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: "\\", with: "_")
                    let safeName = base.isEmpty ? "分享文件" : String(base.prefix(90))
                    let file = UUID().uuidString + "." + ext
                    let dest = dir.appendingPathComponent(file)
                    try FileManager.default.copyItem(at: source, to: dest)
                    let mime = UTType(type)?.preferredMIMEType ??
                        (UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream")
                    continuation.resume(returning: ImportedEntry(
                        id: UUID().uuidString, kind: "file",
                        name: safeName + "." + ext, mediaType: mime,
                        filename: file, text: nil))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func loadItem(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: item) }
            }
        }
    }

    private enum ImportError: LocalizedError {
        case noSharedContainer, noSupportedItems
        var errorDescription: String? {
            switch self {
            case .noSharedContainer: "App Group 尚未配置，无法安全接收分享文件"
            case .noSupportedItems: "此 App 未提供 Ferry 可接收的文件或文字"
            }
        }
    }
}

private struct ImportedEntry: Codable {
    let id: String
    let kind: String
    let name: String
    let mediaType: String
    let filename: String?
    let text: String?
}

private struct ImportedBatch: Codable {
    let id: String
    let createdAt: Date
    let entries: [ImportedEntry]
}
