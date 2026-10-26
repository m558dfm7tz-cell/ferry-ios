import AVFoundation
import UIKit
import Foundation
import os

/// Generates and caches poster frames for video messages, keyed by message id.
/// Thumbnails are stored on disk under Application Support/Thumbnails/<id>.jpg
/// and durations in a sidecar <id>.duration so both survive relaunches.
enum VideoThumbnailCache {
    private static let logger = Logger(subsystem: "com.ferry.test", category: "VideoThumbnail")
    private static let spaceLock = NSLock()
    private static var spaceFolderName: String?

    /// Set once per connect. Thumbnails are then written under a per-space
    /// folder so different servers never share poster caches.
    static func setSpace(_ space: SpaceKey?) {
        spaceLock.lock()
        spaceFolderName = space?.folderName
        spaceLock.unlock()
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        spaceLock.lock()
        let folder = spaceFolderName
        spaceLock.unlock()
        if let folder {
            return base.appendingPathComponent("Ferry", isDirectory: true)
                .appendingPathComponent("Spaces", isDirectory: true)
                .appendingPathComponent(folder, isDirectory: true)
                .appendingPathComponent("Thumbnails", isDirectory: true)
        }
        return base.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    static func cachedThumbnail(for id: String) -> UIImage? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    static func cachedDuration(for id: String) -> Double {
        let url = durationURL(for: id)
        guard let string = try? String(contentsOfFile: url.path, encoding: .utf8) else { return 0 }
        return Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Generate a poster frame. Robust to files that fail to decode a frame at
    /// exactly t=0: falls back to synchronous `copyCGImage` at 0 s and 0.5 s
    /// with infinite tolerances. Logs the failure reason (never tokens) via
    /// os.Logger so a video never silently becomes a plain file card.
    static func generate(from data: Data, id: String, fileExtension ext: String) async -> (image: UIImage?, duration: Double) {
        let safeExt = ext.isEmpty ? "mov" : ext.lowercased()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-\(UUID().uuidString).\(safeExt)")
        do {
            try data.write(to: temp, options: .atomic)
        } catch {
            logger.error("thumbnail write temp failed: \(error.localizedDescription, privacy: .public)")
            return (nil, 0)
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        return await generate(fromFileURL: temp, id: id)
    }

    /// Generate a poster frame directly from a local file URL (no in-memory
    /// Data roundtrip) — the preferred path for large downloaded videos.
    static func generate(fromFileURL url: URL, id: String) async -> (image: UIImage?, duration: Double) {
        let asset = AVURLAsset(url: url)
        var duration: Double = 0
        if let cmTime = try? await asset.load(.duration) {
            let seconds = cmTime.seconds
            if seconds.isFinite, seconds > 0 { duration = seconds }
        }

        // Confirm the file actually has a decodable video track before trying
        // to pull a frame (AVAssetImageGenerator throws otherwise).
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty else {
                logger.error("no video tracks for message \(id, privacy: .public)")
                return (nil, duration)
            }
        } catch {
            logger.error("loadTracks failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return (nil, duration)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)

        if let image = await asyncImage(generator: generator, seconds: 0, id: id) {
            save(image, id: id)
            saveDuration(duration, id: id)
            return (image, duration)
        }
        for seconds in [0.0, 0.5] {
            if let image = syncImage(generator: generator, seconds: seconds) {
                save(image, id: id)
                saveDuration(duration, id: id)
                return (image, duration)
            }
        }
        logger.error("thumbnail generation failed for message \(id, privacy: .public)")
        return (nil, duration)
    }

    private static func asyncImage(generator: AVAssetImageGenerator, seconds: Double, id: String) async -> UIImage? {
        do {
            let (cgImage, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            return UIImage(cgImage: cgImage)
        } catch {
            logger.error("async image(at:\(seconds)) failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func syncImage(generator: AVAssetImageGenerator, seconds: Double) -> UIImage? {
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        do {
            var actualTime = CMTime.zero
            let cgImage = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600),
                                                    actualTime: &actualTime)
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }

    private static func save(_ image: UIImage, id: String) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: id), options: .atomic)
        } catch {}
    }

    private static func saveDuration(_ duration: Double, id: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? String(duration).write(toFile: durationURL(for: id).path, atomically: true, encoding: .utf8)
    }

    private static func fileURL(for id: String) -> URL {
        let safe = sanitized(id)
        return directory.appendingPathComponent(safe + ".jpg")
    }

    private static func durationURL(for id: String) -> URL {
        let safe = sanitized(id)
        return directory.appendingPathComponent(safe + ".duration")
    }

    private static func sanitized(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    }
}
