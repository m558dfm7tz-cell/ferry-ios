import Foundation
import Photos

/// Add-only writes to the photo library; Ferry never reads or enumerates the
/// user's photos, so only `NSPhotoLibraryAddUsageDescription` is required.
enum PhotoSaver {
    enum SaveError: LocalizedError {
        case denied
        case failed

        var errorDescription: String? {
            switch self {
            case .denied: "相册权限被禁用，请在 设置 中允许添加照片。"
            case .failed: "无法保存照片。"
            }
        }
    }

    static func save(_ data: Data, mediaType: String) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
            guard granted else { throw SaveError.denied }
        } else if status != .authorized {
            throw SaveError.denied
        }
        let resourceType: PHAssetResourceType = mediaType.hasPrefix("image/") ? .photo : .video
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: resourceType, data: data, options: nil)
            }
        } catch {
            throw SaveError.failed
        }
    }
}
