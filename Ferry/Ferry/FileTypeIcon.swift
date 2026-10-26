import SwiftUI

/// Shared file-type icon style: maps a file name/extension (falling back to
/// mime) to an SF Symbol + accent color, rendered as a tinted symbol on a
/// low-opacity rounded square so it reads well on the dark chat background.
struct FileTypeIcon {
    let symbol: String
    let color: Color

    static func style(for name: String, mediaType: String = "") -> FileTypeIcon {
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty { return style(extension: ext) }
        return style(mime: mediaType)
    }

    static func style(extension ext: String) -> FileTypeIcon {
        switch ext {
        case "mp3", "m4a", "wav", "flac", "aac", "ogg", "wma", "opus":
            return FileTypeIcon(symbol: "waveform", color: .pink)
        case "mp4", "mov", "m4v", "avi", "mkv", "webm":
            return FileTypeIcon(symbol: "film.fill", color: .purple)
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tif", "tiff":
            return FileTypeIcon(symbol: "photo.fill", color: .teal)
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz":
            return FileTypeIcon(symbol: "doc.zipper", color: .orange)
        case "pdf":
            return FileTypeIcon(symbol: "doc.richtext.fill", color: .red)
        case "doc", "docx", "rtf", "pages":
            return FileTypeIcon(symbol: "doc.text.fill", color: .blue)
        case "xls", "xlsx", "csv", "numbers":
            return FileTypeIcon(symbol: "tablecells.fill", color: .green)
        case "ppt", "pptx", "key":
            return FileTypeIcon(symbol: "play.rectangle.fill", color: .orange)
        case "json", "xml", "yaml", "yml", "swift", "go", "py", "js", "ts", "html",
             "css", "c", "cpp", "h", "hpp", "java", "sh", "ps1", "plist", "sql":
            return FileTypeIcon(symbol: "chevron.left.forwardslash.chevron.right", color: .cyan)
        case "txt", "md", "markdown", "log":
            return FileTypeIcon(symbol: "doc.plaintext.fill", color: .gray)
        case "exe", "msi", "apk", "dmg", "ipa", "pkg", "deb", "rpm":
            return FileTypeIcon(symbol: "shippingbox.fill", color: .indigo)
        default:
            return FileTypeIcon(symbol: "doc.fill", color: .gray)
        }
    }

    static func style(mime: String) -> FileTypeIcon {
        let lower = mime.lowercased()
        if lower.hasPrefix("audio/") { return FileTypeIcon(symbol: "waveform", color: .pink) }
        if lower.hasPrefix("video/") { return FileTypeIcon(symbol: "film.fill", color: .purple) }
        if lower.hasPrefix("image/") { return FileTypeIcon(symbol: "photo.fill", color: .teal) }
        if lower == "application/pdf" { return FileTypeIcon(symbol: "doc.richtext.fill", color: .red) }
        if lower == "application/zip" || lower == "application/x-7z-compressed" {
            return FileTypeIcon(symbol: "doc.zipper", color: .orange)
        }
        if lower.hasPrefix("text/") { return FileTypeIcon(symbol: "doc.plaintext.fill", color: .gray) }
        return FileTypeIcon(symbol: "doc.fill", color: .gray)
    }
}

/// Tinted symbol on a low-opacity rounded square, sized to match the existing
/// file-card icon slot.
struct FileTypeIconView: View {
    let file: FileInfo
    var size: CGFloat = 34

    var body: some View {
        let style = FileTypeIcon.style(for: file.name, mediaType: file.mediaType)
        Image(systemName: style.symbol)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(style.color)
            .frame(width: size, height: size)
            .background(style.color.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}
