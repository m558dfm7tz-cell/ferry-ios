import AVFoundation
import Foundation
import Observation
import PhotosUI
import SwiftUI
import UIKit

// MARK: - Model

/// How an assistant avatar is rendered: the default coloured letter disc, a
/// still image, or a muted looping video.
enum AssistantAvatarKind: String, Codable, Sendable {
    case text
    case image
    case video
}

/// A locally stored custom avatar. `fileName` is the file name inside
/// `AssistantAvatarStore.directory`.
struct AssistantAvatar: Codable, Equatable, Sendable {
    var kind: AssistantAvatarKind
    var fileName: String?
}

/// Resolved avatar media, ready to render.
struct AssistantAvatarMedia: Equatable, Sendable {
    let kind: AssistantAvatarKind
    let imageURL: URL?
    let videoURL: URL?
}

// MARK: - Server sync (stub, never performs network access)

/// Future server-side sync for assistant avatars.
///
/// Nothing is wired up yet: avatars are stored on this phone only and
/// `NoopAssistantAvatarSync` performs **no network access at all**. Replace the
/// default with a real implementation when the server grows an avatar endpoint —
/// `AssistantAvatarStore` already routes both directions through it.
protocol AssistantAvatarSyncing: Sendable {
    /// Avatar metadata (not the media files) as known by the server.
    func fetchAvatars() async throws -> [String: AssistantAvatar]
    /// Publish one avatar so the user's other devices can pick it up.
    func uploadAvatar(_ avatar: AssistantAvatar, assistantID: String) async throws
}

enum AssistantAvatarSyncError: Error, LocalizedError {
    case notAvailable

    var errorDescription: String? { "助手头像尚未与服务器同步" }
}

/// Placeholder sync implementation: fails immediately and never touches the
/// network, so the app stays local-only until a real endpoint exists.
struct NoopAssistantAvatarSync: AssistantAvatarSyncing {
    func fetchAvatars() async throws -> [String: AssistantAvatar] {
        throw AssistantAvatarSyncError.notAvailable
    }

    func uploadAvatar(_ avatar: AssistantAvatar, assistantID: String) async throws {
        throw AssistantAvatarSyncError.notAvailable
    }
}

// MARK: - Store

/// Local persistence for custom assistant avatars (metadata in `UserDefaults`,
/// media files under Application Support). Server sync goes through
/// `AssistantAvatarSyncing`, currently the no-op stub.
@MainActor @Observable
final class AssistantAvatarStore {
    private(set) var avatars: [String: AssistantAvatar] = [:]

    private let defaults: UserDefaults
    private let sync: any AssistantAvatarSyncing
    private(set) var spaceKey: SpaceKey?

    private static let storageKey = "ferry.local.assistantAvatars"
    private static let directoryName = "AssistantAvatars"

    private var scopedKey: String { Self.storageKey + "." + (spaceKey?.value ?? "") }

    init(defaults: UserDefaults = .standard,
         sync: any AssistantAvatarSyncing = NoopAssistantAvatarSync()) {
        self.defaults = defaults
        self.sync = sync
    }

    /// Point the store at one Ferry space and load its avatars. The first space
    /// ever activated absorbs legacy (unscoped) data.
    func activate(space: SpaceKey) {
        guard space != spaceKey else { return }
        spaceKey = space
        if let data = defaults.data(forKey: scopedKey),
           let decoded = try? JSONDecoder().decode([String: AssistantAvatar].self, from: data) {
            avatars = decoded
        } else if let legacy = defaults.data(forKey: Self.storageKey),
                  let decoded = try? JSONDecoder().decode([String: AssistantAvatar].self, from: legacy) {
            avatars = decoded
            defaults.removeObject(forKey: Self.storageKey)
            persist()
        } else {
            avatars = [:]
        }
    }

    /// Directory holding the avatar media files (created on first access),
    /// scoped to the active space.
    var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url: URL
        if let spaceKey {
            url = base.appendingPathComponent("Ferry", isDirectory: true)
                .appendingPathComponent("Spaces", isDirectory: true)
                .appendingPathComponent(spaceKey.folderName, isDirectory: true)
                .appendingPathComponent(Self.directoryName, isDirectory: true)
        } else {
            url = base.appendingPathComponent(Self.directoryName, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Media to render for an assistant, or nil when it uses the default disc.
    func media(for assistantID: String) -> AssistantAvatarMedia? {
        guard let avatar = avatars[assistantID],
              let fileName = avatar.fileName, !fileName.isEmpty else { return nil }
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        switch avatar.kind {
        case .text: return nil
        case .image: return AssistantAvatarMedia(kind: .image, imageURL: url, videoURL: nil)
        case .video: return AssistantAvatarMedia(kind: .video, imageURL: nil, videoURL: url)
        }
    }

    /// Store a still image avatar (downscaled to keep memory small).
    func setImage(_ data: Data, for assistantID: String) {
        guard let jpeg = Self.normalizedJPEG(data) else { return }
        let name = "\(assistantID).jpg"
        replaceFile(named: name, data: jpeg, for: assistantID)
        avatars[assistantID] = AssistantAvatar(kind: .image, fileName: name)
        persistAndPush(assistantID)
    }

    /// Store a video avatar (copied as-is; the player loops it muted).
    func setVideo(from sourceURL: URL, for assistantID: String) {
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let name = "\(assistantID).\(ext)"
        let destination = directory.appendingPathComponent(name)
        do {
            removeFile(for: assistantID)
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            avatars[assistantID] = AssistantAvatar(kind: .video, fileName: name)
            Self.imageCache.removeObject(forKey: destination.path as NSString)
            persistAndPush(assistantID)
        } catch {
            return
        }
    }

    /// Drop the custom avatar and fall back to the default letter disc.
    func reset(for assistantID: String) {
        removeFile(for: assistantID)
        avatars.removeValue(forKey: assistantID)
        persist()
    }

    // MARK: - Server sync entry points (stub)

    /// Pull avatar metadata from the server. Currently a no-op because the
    /// sync implementation is `NoopAssistantAvatarSync`.
    func syncFromServer() async {
        guard let remote = try? await sync.fetchAvatars() else { return }
        for (id, avatar) in remote where avatars[id] == nil {
            avatars[id] = avatar
        }
        persist()
    }

    /// Push one avatar to the server. Currently a no-op.
    func pushToServer(_ assistantID: String) async {
        guard let avatar = avatars[assistantID] else { return }
        _ = try? await sync.uploadAvatar(avatar, assistantID: assistantID)
    }

    // MARK: - Internals

    private func persistAndPush(_ assistantID: String) {
        persist()
        let id = assistantID
        Task { @MainActor in await pushToServer(id) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(avatars) {
            defaults.set(data, forKey: scopedKey)
        }
    }

    private func replaceFile(named name: String, data: Data, for assistantID: String) {
        removeFile(for: assistantID)
        let url = directory.appendingPathComponent(name)
        try? data.write(to: url, options: .atomic)
        Self.imageCache.removeObject(forKey: url.path as NSString)
    }

    private func removeFile(for assistantID: String) {
        guard let name = avatars[assistantID]?.fileName else { return }
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        Self.imageCache.removeObject(forKey: url.path as NSString)
    }

    /// Small in-memory cache so re-rendering a long timeline does not hit disk
    /// for every avatar.
    static let imageCache = NSCache<NSString, UIImage>()

    static func cachedImage(at url: URL) -> UIImage? {
        let key = url.path as NSString
        if let hit = imageCache.object(forKey: key) { return hit }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    private static func normalizedJPEG(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 256
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        if longest <= maxSide { return image.jpegData(compressionQuality: 0.9) }
        let scale = maxSide / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.jpegData(withCompressionQuality: 0.9) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - Rendering

/// Muted, endlessly looping video used for custom avatars.
struct LoopingVideoView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> LoopingVideoUIView {
        let view = LoopingVideoUIView()
        view.setURL(url)
        return view
    }

    func updateUIView(_ uiView: LoopingVideoUIView, context: Context) {
        uiView.setURL(url)
    }
}

final class LoopingVideoUIView: UIView {
    private let playerLayer = AVPlayerLayer()
    private var queuePlayer: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }

    func setURL(_ url: URL) {
        guard url != currentURL else { return }
        currentURL = url
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer(items: [item])
        player.isMuted = true
        player.actionAtItemEnd = .none
        looper = AVPlayerLooper(player: player, templateItem: item)
        playerLayer.player = player
        queuePlayer = player
        player.play()
    }
}

/// Sheet used from an avatar's long-press menu and from 设置 to replace one
/// assistant's avatar with an image or a muted looping video, or restore the
/// default disc. Media is written to this phone only.
struct AssistantAvatarEditorView: View {
    let assistant: Assistant
    let store: AssistantAvatarStore

    @State private var imageItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?

    private var media: AssistantAvatarMedia? { store.media(for: assistant.id) }

    var body: some View {
        Form {
            Section("当前头像") {
                HStack {
                    Spacer()
                    AssistantAvatarView(assistant: assistant, size: 72, media: media)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            Section("更换头像") {
                PhotosPicker(selection: $imageItem, matching: .images) {
                    Label("选择图片", systemImage: "photo")
                }
                .accessibilityIdentifier("assistant-avatar-pick-image")

                PhotosPicker(selection: $videoItem, matching: .videos) {
                    Label("选择视频（静音循环播放）", systemImage: "video")
                }
                .accessibilityIdentifier("assistant-avatar-pick-video")

                Button {
                    store.reset(for: assistant.id)
                } label: {
                    Label("恢复默认头像", systemImage: "arrow.uturn.left")
                }
                .disabled(media == nil)
                .accessibilityIdentifier("assistant-avatar-reset")
            }

            Section {
                Text("头像只保存在本机，未来可与服务器同步（接口已预留，尚未接入）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(assistant.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: imageItem) { _, item in
            guard let item else { return }
            imageItem = nil
            Task { @MainActor in
                if let data = try? await item.loadTransferable(type: Data.self) {
                    store.setImage(data, for: assistant.id)
                }
            }
        }
        .onChange(of: videoItem) { _, item in
            guard let item else { return }
            videoItem = nil
            Task { @MainActor in
                if let movie = try? await item.loadTransferable(type: MovieTransfer.self) {
                    store.setVideo(from: movie.url, for: assistant.id)
                }
            }
        }
    }
}
