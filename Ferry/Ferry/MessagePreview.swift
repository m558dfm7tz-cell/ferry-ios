import SwiftUI
import UIKit

/// A routable preview of a message. `kind` selects the viewer; `url` is a
/// local file URL for video/audio/document kinds (already downloaded); `image`
/// is the decoded UIImage for the image kind; `text` is decoded content for
/// the text kind.
struct MessagePreview: Identifiable {
    enum Kind { case image, video, audio, document, text }

    let id = UUID()
    let kind: Kind
    let name: String
    let mediaType: String
    let url: URL?
    let image: UIImage?
    let text: String?

    init(kind: Kind, name: String, mediaType: String = "",
         url: URL? = nil, image: UIImage? = nil, text: String? = nil) {
        self.kind = kind
        self.name = name
        self.mediaType = mediaType
        self.url = url
        self.image = image
        self.text = text
    }
}

/// Type classification + temp-file helpers shared by the timeline row and the
/// favorites list so both route message files to the same previews.
enum PreviewRouter {
    static func isImage(_ mediaType: String) -> Bool { mediaType.hasPrefix("image/") }
    static func isVideo(_ mediaType: String) -> Bool { mediaType.hasPrefix("video/") }
    static func isAudio(_ mediaType: String) -> Bool { mediaType.hasPrefix("audio/") }

    /// Plain text files get a native SwiftUI text viewer; everything else
    /// non-media falls through to QuickLook.
    static func isPlainText(_ file: FileInfo) -> Bool {
        let ext = (file.name as NSString).pathExtension.lowercased()
        return ["txt", "md", "markdown"].contains(ext) || file.mediaType.hasPrefix("text/")
    }

    /// Write downloaded bytes to a temporary file with a sensible extension so
    /// AVPlayer / QuickLook can identify the container by content type.
    static func temporaryURL(for data: Data, name: String, mediaType: String) -> URL? {
        let ext = fileExtension(name: name, mediaType: mediaType)
        let leaf = "ferry-preview-\(UUID().uuidString).\(ext)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(leaf)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Extension (without a leading dot) derived from the file name, falling
    /// back to a media-type mapping, and finally "bin".
    static func fileExtension(name: String, mediaType: String) -> String {
        let nameExt = (name as NSString).pathExtension.lowercased()
        if !nameExt.isEmpty, !nameExt.contains(" "), nameExt.count <= 10 { return nameExt }
        switch mediaType {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/heic", "image/heif": return "heic"
        case "image/gif": return "gif"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "audio/mpeg": return "mp3"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/wav", "audio/x-wav": return "wav"
        case "application/pdf": return "pdf"
        case "application/msword": return "doc"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return "docx"
        case "application/vnd.ms-excel": return "xls"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": return "xlsx"
        case "text/plain": return "txt"
        default: return "bin"
        }
    }
}

enum TimeText {
    static func mmss(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
