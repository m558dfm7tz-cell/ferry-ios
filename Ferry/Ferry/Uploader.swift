import CoreTransferable
import Foundation
import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Sequential upload queue for `POST /api/v1/messages/file`.
///
/// The Go server accepts exactly one multipart part per request:
/// `name="file"; filename="<name>"` with a `Content-Type` part header, bounded
/// by `MaxFileBytes = 64 MiB` (see `internal/ferry/model.go` and `server.go`).
/// Files larger than that are rejected here before any network traffic.
@MainActor @Observable
final class Uploader {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let name: String
        let mediaType: String
        let size: Int64
        let boundary: String
        let bodyURL: URL
        var progress: Double = 0
        var phase: Phase = .waiting
        var error: String?

        enum Phase: Equatable { case waiting, uploading, done, failed }
    }

    static let maxBytes: Int64 = 64 << 20

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

    /// Enqueue one file. Returns a Chinese error message when the file cannot
    /// be sent (too large or unreadable), otherwise nil.
    @discardableResult
    func enqueue(data: Data, name: String, mediaType: String) -> String? {
        guard data.count <= Self.maxBytes else {
            return "「\(name)」超过 64 MB，无法发送。"
        }
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

    func remove(_ id: UUID) {
        if activeItemID == id { activeTask?.cancel() }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: items[index].bodyURL)
        items.remove(at: index)
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
        session = URLSession(configuration: .default, delegate: d, delegateQueue: .main)
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
        } else if http.statusCode == 413 {
            items[index].phase = .failed
            items[index].error = "文件超过 64 MB，无法发送。"
        } else {
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
    static func media(from item: PhotosPickerItem) async -> (data: Data, mime: String, name: String)? {
        let types = item.supportedContentTypes
        let isVideo = types.contains { $0.conforms(to: .movie) }
        if isVideo {
            guard let movie = try? await item.loadTransferable(type: MovieTransfer.self),
                  let data = try? Data(contentsOf: movie.url) else { return nil }
            try? FileManager.default.removeItem(at: movie.url)
            let ext = movie.url.pathExtension.lowercased()
            let mime = mime(forExtension: ext.isEmpty ? "mov" : ext)
            return (data, mime, generatedName(prefix: "视频", mime: mime))
        }
        let mime = types.first?.preferredMIMEType ?? "image/jpeg"
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return (data, mime, generatedName(prefix: "照片", mime: mime))
    }

    static func file(from url: URL) -> (data: Data, mime: String, name: String)? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mime: String
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           let preferred = contentType.preferredMIMEType {
            mime = preferred
        } else {
            mime = "application/octet-stream"
        }
        let name = url.lastPathComponent.isEmpty ? "文件" : url.lastPathComponent
        return (data, mime, name)
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
