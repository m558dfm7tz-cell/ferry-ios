import AVFoundation
import CoreTransferable
import Foundation
import Observation
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Sequential upload queue for `POST /api/v1/messages/file`.
///
/// The Go server accepts exactly one multipart part per request:
/// `name="file"; filename="<name>"` with a `Content-Type` part header. The
/// client no longer imposes its own size cap; files are streamed into a
/// multipart body temp file (1 MB chunks) and uploaded with
/// `uploadTask(with:fromFile:)` so the whole file never has to live in memory.
@MainActor @Observable
final class Uploader {
    struct Item: Identifiable, Equatable {
        let id: UUID
        var name: String
        var mediaType: String
        var size: Int64
        let boundary: String
        var bodyURL: URL
        var progress: Double = 0
        var phase: Phase = .waiting
        var error: String?

        enum Phase: Equatable { case waiting, uploading, transcoding, done, failed }
    }

    private(set) var items: [Item] = []
    private(set) var isUploading = false

    var onCreated: ((MessagePayload) -> Void)?
    var onUnauthorized: (() -> Void)?

    private var session: URLSession?
    private var delegate: UploadSessionDelegate?
    private var endpoint: ServerEndpoint?
    private var token: String?
    private var activeTask: URLSessionUploadTask?
    private var activeItemID: UUID?

    /// Reconfigure for a session, or tear everything down when the device is
    /// no longer connected (nil endpoint/token).
    func configure(endpoint: ServerEndpoint?, token: String?) {
        self.endpoint = endpoint
        self.token = token
        if endpoint == nil || token == nil {
            teardown()
        } else {
            ensureSession()
        }
    }

    func teardown() {
        activeTask?.cancel()
        session?.invalidateAndCancel()
        session = nil
        delegate = nil
        for item in items { try? FileManager.default.removeItem(at: item.bodyURL) }
        items.removeAll()
        isUploading = false
        activeTask = nil
        activeItemID = nil
    }

    /// Enqueue one in-memory payload (small images). No client-side size cap.
    @discardableResult
    func enqueue(data: Data, name: String, mediaType: String) -> String? {
        let safeName = Self.safeFilename(name)
        let safeMime = Self.safeMediaType(mediaType)
        let boundary = "Ferry-" + UUID().uuidString
        guard let bodyURL = try? Self.writeBody(data: data, filename: safeName, mediaType: safeMime, boundary: boundary) else {
            return "「\(name)」无法准备上传。"
        }
        items.append(Item(id: UUID(), name: safeName, mediaType: safeMime, size: Int64(data.count),
                          boundary: boundary, bodyURL: bodyURL))
        pump()
        return nil
    }

    /// Enqueue a file by streaming it into a multipart body temp file (never
    /// reads the whole file into memory). No client-side size cap.
    @discardableResult
    func enqueue(fileURL: URL, name: String, mediaType: String) -> String? {
        let safeName = Self.safeFilename(name)
        let safeMime = Self.safeMediaType(mediaType)
        let boundary = "Ferry-" + UUID().uuidString
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard let bodyURL = try? Self.writeBodyStreaming(sourceURL: fileURL, filename: safeName,
                                                         mediaType: safeMime, boundary: boundary) else {
            return "「\(name)」无法准备上传。"
        }
        items.append(Item(id: UUID(), name: safeName, mediaType: safeMime, size: size,
                          boundary: boundary, bodyURL: bodyURL))
        pump()
        return nil
    }

    func remove(_ id: UUID) {
        if activeItemID == id { activeTask?.cancel() }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: items[index].bodyURL)
        items.remove(at: index)
    }

    /// Re-queue a failed item and restart the sequential pump.
    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].phase = .waiting
        items[index].progress = 0
        items[index].error = nil
        pump()
    }

    /// Add a queue item that is still being transcoded. It shows "转码中…" and
    /// uploads nothing until `completeTranscode` is called with the result.
    @discardableResult
    func enqueueTranscoding(name: String) -> UUID {
        let safeName = Self.safeFilename(name)
        let boundary = "Ferry-" + UUID().uuidString
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".multipart")
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let id = UUID()
        items.append(Item(id: id, name: safeName, mediaType: "video/mp4", size: 0,
                          boundary: boundary, bodyURL: bodyURL, phase: .transcoding))
        return id
    }

    /// Replace a transcoding item's placeholder body with the finished file
    /// (streamed from `fileURL`) and start uploading it. Returns a Chinese
    /// error message on failure.
    @discardableResult
    func completeTranscode(_ id: UUID, fileURL: URL, name: String, mediaType: String) -> String? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let safeName = Self.safeFilename(name)
        let safeMime = Self.safeMediaType(mediaType)
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard let bodyURL = try? Self.writeBodyStreaming(sourceURL: fileURL, filename: safeName,
                                                         mediaType: safeMime, boundary: items[index].boundary) else {
            failTranscode(id, error: "「\(name)」无法准备上传。")
            return "「\(name)」无法准备上传。"
        }
        try? FileManager.default.removeItem(at: items[index].bodyURL)
        items[index].name = safeName
        items[index].mediaType = safeMime
        items[index].size = size
        items[index].bodyURL = bodyURL
        items[index].progress = 0
        items[index].phase = .waiting
        pump()
        return nil
    }

    func failTranscode(_ id: UUID, error: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].phase = .failed
        items[index].error = error
    }

    func removeFinished() {
        items.removeAll { $0.phase == .done || $0.phase == .failed }
    }

    private func ensureSession() {
        guard session == nil else { return }
        let d = UploadSessionDelegate()
        d.onProgress = { [weak self] progress in
            guard let self, let id = self.activeItemID,
                  let index = self.items.firstIndex(where: { $0.id == id }) else { return }
            self.items[index].progress = progress
        }
        d.onComplete = { [weak self] data, response, error in
            self?.finish(data: data, response: response, error: error)
        }
        delegate = d
        // Transfer session with generous timeouts for large files; JSON API
        // calls keep the default timeouts.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 24 * 3600
        session = URLSession(configuration: config, delegate: d, delegateQueue: .main)
    }

    private func pump() {
        guard !isUploading, let endpoint, let token, let session else { return }
        guard let index = items.firstIndex(where: { $0.phase == .waiting }) else { return }
        isUploading = true
        items[index].phase = .uploading
        items[index].progress = 0
        let id = items[index].id
        activeItemID = id

        var request = URLRequest(url: endpoint.url(path: "/api/v1/messages/file"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(items[index].boundary)", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.uploadTask(with: request, fromFile: items[index].bodyURL)
        activeTask = task
        task.resume()
    }

    private func finish(data: Data?, response: URLResponse?, error: Error?) {
        let finishedID = activeItemID
        activeTask = nil
        activeItemID = nil
        isUploading = false
        guard let id = finishedID, let index = items.firstIndex(where: { $0.id == id }) else {
            pump()
            return
        }
        defer { try? FileManager.default.removeItem(at: items[index].bodyURL) }

        if let error = error {
            let ns = error as NSError
            if ns.code == NSURLErrorCancelled {
                items[index].phase = .failed
                items[index].error = "已取消"
            } else {
                items[index].phase = .failed
                items[index].error = "发送失败：\(error.localizedDescription)"
            }
            pump()
            return
        }
        guard let http = response as? HTTPURLResponse else {
            items[index].phase = .failed
            items[index].error = "服务器无响应。"
            pump()
            return
        }
        if (200..<300).contains(http.statusCode) {
            if let message = try? JSONDecoder().decode(MessagePayload.self, from: data ?? Data()) {
                items[index].phase = .done
                items[index].progress = 1
                onCreated?(message)
            } else {
                items[index].phase = .failed
                items[index].error = "服务器返回无效响应。"
            }
        } else if http.statusCode == 401 {
            items[index].phase = .failed
            items[index].error = "当前设备已断开连接。"
            onUnauthorized?()
        } else {
            // 413 (too large, server-side cap) and 507 (insufficient storage)
            // both carry a Chinese message in the JSON error body.
            let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data ?? Data()))?.error.message
            items[index].phase = .failed
            items[index].error = message ?? "发送失败（HTTP \(http.statusCode)）。"
        }
        pump()
    }

    private static func writeBody(data: Data, filename: String, mediaType: String, boundary: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".multipart")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
            try handle.write(contentsOf: Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
            try handle.write(contentsOf: Data("Content-Type: \(mediaType)\r\n\r\n".utf8))
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()
        return url
    }

    /// Build a multipart body temp file by streaming `sourceURL` in 1 MB chunks
    /// (so large files never live in memory): boundary headers, then the file
    /// bytes, then the closing boundary.
    private static func writeBodyStreaming(sourceURL: URL, filename: String, mediaType: String, boundary: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".multipart")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        let input = try FileHandle(forReadingFrom: sourceURL)
        do {
            try output.write(contentsOf: Data("--\(boundary)\r\n".utf8))
            try output.write(contentsOf: Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
            try output.write(contentsOf: Data("Content-Type: \(mediaType)\r\n\r\n".utf8))
            while true {
                let chunk = try input.read(upToCount: 1 << 20)
                guard let chunk, !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        } catch {
            try? output.close()
            try? input.close()
            throw error
        }
        try output.close()
        try input.close()
        return url
    }

    static func safeFilename(_ name: String) -> String {
        var leaf = (name as NSString).lastPathComponent
        leaf = leaf.replacingOccurrences(of: "\\", with: "_")
        leaf = leaf.replacingOccurrences(of: "\"", with: "_")
        leaf = leaf.replacingOccurrences(of: "\r", with: "_")
        leaf = leaf.replacingOccurrences(of: "\n", with: "_")
        if leaf.isEmpty { leaf = "file" }
        return leaf
    }

    static func safeMediaType(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 127,
              trimmed.filter({ $0 == "/" }).count == 1,
              !trimmed.contains(where: { $0 <= " " || $0 == "\u{7f}" }) else {
            return "application/octet-stream"
        }
        return trimmed
    }
}

/// Delegate-only helper: forwards body-send progress and completion back to
/// the `Uploader`. Runs on the main queue because the session's delegate queue
/// is the main queue, so no cross-actor hops are needed.
private final class UploadSessionDelegate: NSObject, URLSessionDataDelegate {
    var onProgress: ((Double) -> Void)?
    var onComplete: ((Data?, URLResponse?, Error?) -> Void)?
    private var responseData = Data()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let data = responseData
        responseData = Data()
        onComplete?(data, task.response, error)
    }
}

/// A `PhotosPickerItem` transferable for movies: imports the original movie
/// bytes to a temp file without re-encoding, preserving the file extension.
struct MovieTransfer: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.lowercased()
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString).\(ext.isEmpty ? "mov" : ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return MovieTransfer(url: copy)
        }
    }
}

/// Turns a PhotosPicker item, a file URL, or a camera capture into upload-ready
/// bytes plus a media type and file name.
enum MediaLoader {
    static func isLivePhoto(_ item: PhotosPickerItem) -> Bool {
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .livePhoto) }) { return true }
        // Some picker items report image+movie instead of .livePhoto; fall back
        // to the photo-library asset's media subtype so a Live Photo is never
        // mistaken for a plain movie (which would drop the still image).
        guard let identifier = item.itemIdentifier else { return false }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        return assets.firstObject?.mediaSubtypes.contains(.photoLive) == true
    }

    static func isMovie(_ item: PhotosPickerItem) -> Bool {
        item.supportedContentTypes.contains { $0.conforms(to: .movie) }
    }

    /// Still image (or the still frame of a Live Photo) from a picker item.
    static func image(from item: PhotosPickerItem) async -> (data: Data, mime: String, name: String)? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let mime = imageMime(from: data)
        return (data, mime, generatedName(prefix: "照片", mime: mime))
    }

    /// Original movie bytes copied to a temp file, without re-encoding.
    static func movie(from item: PhotosPickerItem) async -> (url: URL, mime: String, name: String)? {
        guard let movie = try? await item.loadTransferable(type: MovieTransfer.self) else { return nil }
        let ext = movie.url.pathExtension.lowercased()
        let mime = mime(forExtension: ext.isEmpty ? "mov" : ext)
        let name = generatedName(prefix: "视频", mime: mime)
        return (movie.url, mime, name)
    }

    /// Transcode a source video to MP4 (H.264/AAC) for better compatibility.
    static func transcodeToMP4(from url: URL) async -> URL? {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcode-\(UUID().uuidString).mp4")
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            return nil
        }
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        if session.status == .completed {
            return output
        }
        try? FileManager.default.removeItem(at: output)
        return nil
    }

    static func mp4Name(from name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return (base.isEmpty ? "视频" : base) + ".mp4"
    }

    /// The Live Photo still frame, as a normal image. A Live Photo must NOT use
    /// `item.loadTransferable(type: Data.self)`, which can return the paired
    /// movie bytes instead of the still image (those bytes are then mislabeled
    /// as a photo and render as a broken "file" on the receiving device).
    ///
    /// Preferred path: `loadFileRepresentation(for:)` with an explicit image
    /// container (HEIC/JPEG/image) so we always get the still picture. Falls
    /// back to reading the `.fullSizePhoto`/`.photo` resource directly from the
    /// photo library for assets where the picker item does not expose a usable
    /// file representation.
    static func livePhotoStillImage(from item: PhotosPickerItem) async -> (data: Data, mime: String, name: String)? {
        if let data = await fileRepresentationData(from: item, types: [.heic, .jpeg, .image]) {
            let mime = imageMime(from: data)
            return (data, mime, generatedName(prefix: "照片", mime: mime))
        }
        if let result = await legacyLivePhotoStillImage(from: item) {
            return result
        }
        return nil
    }

    /// Extract the paired video of a Live Photo. Preferred path:
    /// `loadFileRepresentation(for: .movie)`; falls back to the `.pairedVideo`
    /// photo-library resource. Returns nil (still-only) when unavailable.
    static func livePhotoVideoURL(from item: PhotosPickerItem) async -> URL? {
        if let url = try? await item.loadFileRepresentation(for: .movie) {
            return Self.copyToTemp(url: url, prefix: "live")
        }
        return await legacyLivePhotoVideoURL(from: item)
    }

    /// Read a picker item's file representation for one of several content
    /// types (in order), returning the file bytes.
    private static func fileRepresentationData(from item: PhotosPickerItem, types: [UTType]) async -> Data? {
        for type in types {
            if let url = try? await item.loadFileRepresentation(for: type),
               let data = try? Data(contentsOf: url) {
                return data
            }
        }
        return nil
    }

    /// Copy a temporary file URL into a stable temp file (the URL returned by
    /// `loadFileRepresentation` is only valid for the duration of that call).
    private static func copyToTemp(url: URL, prefix: String) -> URL? {
        let ext = url.pathExtension.lowercased()
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).\(ext.isEmpty ? "mov" : ext)")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            return nil
        }
    }

    /// Fallback still-frame extraction via the photo-library resource
    /// (`.fullSizePhoto` / `.photo`), used when the picker item has no usable
    /// file representation (e.g. `itemIdentifier`-backed assets).
    private static func legacyLivePhotoStillImage(from item: PhotosPickerItem) async -> (data: Data, mime: String, name: String)? {
        guard let identifier = item.itemIdentifier else { return nil }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = assets.firstObject else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let photoResource = resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first(where: { $0.type == .photo }) else { return nil }
        guard let data = await resourceData(for: photoResource) else { return nil }
        let mime = imageMime(from: data)
        return (data, mime, generatedName(prefix: "照片", mime: mime))
    }

    /// Fallback paired-video extraction via the `.pairedVideo` resource.
    private static func legacyLivePhotoVideoURL(from item: PhotosPickerItem) async -> URL? {
        guard let identifier = item.itemIdentifier else { return nil }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = assets.firstObject else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let videoResource = resources.first(where: { $0.type == .pairedVideo }) else { return nil }
        let ext = (videoResource.originalFilename as NSString).pathExtension.lowercased()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-\(UUID().uuidString).\(ext.isEmpty ? "mov" : ext)")
        guard let data = await resourceData(for: videoResource) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Read a `PHAssetResource` into memory asynchronously.
    private static func resourceData(for resource: PHAssetResource) async -> Data? {
        let buffer = NSMutableData()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().requestData(for: resource, options: nil) { chunk in
                    buffer.append(chunk)
                } completionHandler: { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            return Data(referencing: buffer)
        } catch {
            return nil
        }
    }

    /// Detect the image container from magic bytes (avoids trusting the picker's
    /// reported content type, which is unreliable for Live Photo stills).
    static func imageMime(from data: Data) -> String {
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 { return "image/jpeg" }
        if data.count >= 4, data[0] == 0x89, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 { return "image/png" }
        if data.count >= 12, data[4] == 0x66, data[5] == 0x74, data[6] == 0x79, data[7] == 0x70 {
            let brand = String(bytes: data[8..<12], encoding: .ascii) ?? ""
            if ["heic", "heix", "hevc", "mif1", "heif"].contains(brand) { return "image/heic" }
        }
        return "image/jpeg"
    }

    /// File metadata only (mime + name) without reading the bytes, so the
    /// uploader can stream the file instead of loading it into memory.
    static func fileInfo(from url: URL) -> (mime: String, name: String)? {
        let mime: String
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           let preferred = contentType.preferredMIMEType {
            mime = preferred
        } else {
            mime = "application/octet-stream"
        }
        let name = url.lastPathComponent.isEmpty ? "文件" : url.lastPathComponent
        return (mime, name)
    }

    static func capturedImage(_ image: UIImage) -> (data: Data, mime: String, name: String)? {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        return (data, "image/jpeg", generatedName(prefix: "拍摄", mime: "image/jpeg"))
    }

    static func capturedVideo(from url: URL) -> (data: Data, mime: String, name: String)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = (url.pathExtension.isEmpty ? "mov" : url.pathExtension).lowercased()
        let mime = mime(forExtension: ext)
        return (data, mime, generatedName(prefix: "拍摄", mime: mime))
    }

    static func generatedName(prefix: String, mime: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "\(prefix)_\(formatter.string(from: Date())).\(fileExtension(mime: mime))"
    }

    static func fileExtension(mime: String) -> String {
        switch mime {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/heic", "image/heif": return "heic"
        case "image/gif": return "gif"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        default: return "bin"
        }
    }

    static func mime(forExtension ext: String) -> String {
        switch ext {
        case "mov": return "video/quicktime"
        case "mp4", "m4v": return "video/mp4"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        default: return "application/octet-stream"
        }
    }
}
