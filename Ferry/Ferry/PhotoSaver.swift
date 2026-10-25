import Foundation
import Photos
import UIKit

/// Add-only writes to the photo library; Ferry never reads or enumerates the
/// user's photos, so only `NSPhotoLibraryAddUsageDescription` is required.
enum PhotoSaver {
    enum SaveError: LocalizedError {
        case denied
        case failed
        /// The video container is not compatible with the photo library; the
        /// caller should fall back to "Save to Files".
        case incompatible

        var errorDescription: String? {
            switch self {
            case .denied: "相册权限被禁用，请在 设置 中允许添加照片。"
            case .failed: "无法保存照片。"
            case .incompatible: "该视频无法保存到相册。"
            }
        }
    }

    static func save(_ data: Data, mediaType: String, name: String) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
            guard granted else { throw SaveError.denied }
        } else if status != .authorized {
            throw SaveError.denied
        }

        if PreviewRouter.isVideo(mediaType, name: name) {
            try await saveVideo(data, name: name, mediaType: mediaType)
        } else {
            try await saveImage(data)
        }
    }

    private static func saveImage(_ data: Data) async throws {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }
        } catch {
            throw SaveError.failed
        }
    }

    /// Videos must be written to a temp file with the correct container
    /// extension and saved via `addResource(.video, fileURL:)` — PhotoKit
    /// rejects video *data* resources, which is why the old path failed.
    private static func saveVideo(_ data: Data, name: String, mediaType: String) async throws {
        let ext = videoExtension(name: name, mediaType: mediaType)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ferry-save-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: tempURL, options: .atomic)
        } catch {
            throw SaveError.failed
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(tempURL.path) else {
            throw SaveError.incompatible
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: tempURL, options: nil)
            }
        } catch {
            throw SaveError.failed
        }
    }

    /// Video container extension from the file name, falling back to the mime
    /// type, then "mp4".
    static func videoExtension(name: String, mediaType: String) -> String {
        let nameExt = (name as NSString).pathExtension.lowercased()
        if ["mp4", "mov", "m4v"].contains(nameExt) { return nameExt }
        switch mediaType {
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/x-m4v": return "m4v"
        default: return "mp4"
        }
    }
}
