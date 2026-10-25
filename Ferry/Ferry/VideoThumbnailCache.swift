import AVFoundation
import UIKit
import Foundation

/// Generates and caches poster frames for video messages, keyed by message id.
/// Thumbnails are stored on disk under Application Support/Thumbnails/<id>.jpg
/// so they survive relaunches and reconnects.
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

    static func generate(from data: Data, id: String, fileExtension ext: String) async -> UIImage? {
        let safeExt = ext.isEmpty ? "mov" : ext
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-\(UUID().uuidString).\(safeExt)")
        do {
            try data.write(to: temp, options: .atomic)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: temp) }

        let asset = AVURLAsset(url: temp)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        do {
            let (cgImage, _) = try await generator.image(at: CMTime(seconds: 0, preferredTimescale: 600))
            let image = UIImage(cgImage: cgImage)
            save(image, id: id)
            return image
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

    private static func fileURL(for id: String) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent(safe + ".jpg")
    }
}
