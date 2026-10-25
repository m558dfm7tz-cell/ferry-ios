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
            case .denied: "Photo access is disabled. Enable Add Photos in Settings."
            case .failed: "The photo could not be saved."
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
