import AVFoundation
import UIKit
import Foundation

/// Generates and caches poster frames for video messages, keyed by message id.
/// Thumbnails are stored on disk under Application Support/Thumbnails/<id>.jpg
/// and durations in a sidecar <id>.duration so both survive relaunches.
enum VideoThumbnailCache {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
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

    static func generate(from data: Data, id: String, fileExtension ext: String) async -> (image: UIImage?, duration: Double) {
        let safeExt = ext.isEmpty ? "mov" : ext
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-\(UUID().uuidString).\(safeExt)")
        do {
            try data.write(to: temp, options: .atomic)
        } catch {
            return (nil, 0)
        }
        defer { try? FileManager.default.removeItem(at: temp) }

        let asset = AVURLAsset(url: temp)
        var duration: Double = 0
        if let cmTime = try? await asset.load(.duration) {
            let seconds = cmTime.seconds
            if seconds.isFinite, seconds > 0 { duration = seconds }
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        do {
            let (cgImage, _) = try await generator.image(at: CMTime(seconds: 0, preferredTimescale: 600))
            let image = UIImage(cgImage: cgImage)
            save(image, id: id)
            saveDuration(duration, id: id)
            return (image, duration)
        } catch {
            return (nil, duration)
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
