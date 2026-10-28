import Foundation
import Observation

/// Where a tapped notification should take the user: which assistant to filter
/// on and which message to scroll to.
struct NotificationRoute: Equatable {
    /// Assistant to filter on (`nil` = 全部).
    let assistantID: String?
    /// Message to scroll to and highlight.
    let messageID: String?
    let origin: String?
    /// Unique per tap, so tapping the same notification twice re-applies it.
    let nonce: UUID

    init(assistantID: String?, messageID: String?, origin: String? = nil, nonce: UUID = UUID()) {
        self.assistantID = assistantID
        self.messageID = messageID
        self.origin = origin
        self.nonce = nonce
    }
}

/// Keys of the local-notification `userInfo` dictionary, plus the category id.
enum NotificationPayloadKey {
    static let assistantID = "ferry.assistantID"
    static let messageID = "ferry.messageID"
    static let origin = "ferry.serverOrigin"
    static let category = "FERRY_NEW_MESSAGE"
}

/// Notification preferences. Persisted per device; nothing here is ever sent
/// anywhere — Ferry has no push backend.
@MainActor @Observable
final class NotificationSettings {
    static let shared = NotificationSettings()

    private let defaults: UserDefaults
    private static let enabledKey = "ferry.notifications.enabled"
    private static let lastSequenceKey = "ferry.notifications.lastSequence"

    /// Master switch (设置 → 通知 → 新消息通知). On by default for a fresh
    /// install, matching the desktop client.
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.object(forKey: Self.enabledKey) as? Bool {
            isEnabled = stored
        } else {
            isEnabled = true
            defaults.set(true, forKey: Self.enabledKey)
        }
    }

    /// Highest message sequence already turned into a notification. Persisted
    /// so the same message is never announced twice (relaunch, reconnect, or a
    /// repeated poll page). `-1` means "nothing announced yet", so a server
    /// whose sequence starts at 0 still announces its first message.
    var activeOrigin: String?
    var lastNotifiedSequence: Int64 {
        get {
            guard let origin = activeOrigin else {
                return defaults.object(forKey: Self.lastSequenceKey) as? Int64 ?? -1
            }
            return defaults.object(forKey: Self.lastSequenceKey + "." + origin) as? Int64 ?? -1
        }
        set {
            if let origin = activeOrigin {
                defaults.set(newValue, forKey: Self.lastSequenceKey + "." + origin)
            } else {
                defaults.set(newValue, forKey: Self.lastSequenceKey)
            }
        }
    }
}

/// The one-line text shown in a new-message notification.
///
/// Rules follow the Windows client (`MainWindow.Notifications.cs`) so both ends
/// read the same: images get a bare type hint, other attachments get a type
/// hint plus the file name, and text is collapsed to a single line and capped.
enum NotificationSummary {
    /// Same 60-character cap as the desktop client's toast preview.
    static let maxLength = 60

    /// The sending assistant's name; falls back to the sending device name for
    /// messages that do not belong to any assistant.
    static func title(for message: MessagePayload, assistant: Assistant?) -> String {
        assistant?.name ?? message.displayDeviceName
    }

    static func body(for message: MessagePayload) -> String {
        if let file = message.file {
            if PreviewRouter.isImage(file.mediaType) { return "[图片]" }
            if PreviewRouter.isVideo(file) { return "[视频] \(fileName(file))" }
            if PreviewRouter.isAudio(file.mediaType) { return "[音频] \(fileName(file))" }
            return "[文件] \(fileName(file))"
        }
        let text = collapse(message.text ?? "")
        return text.isEmpty ? "[新消息]" : truncate(text)
    }

    private static func fileName(_ file: FileInfo) -> String {
        let name = file.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "文件" : name
    }

    /// Collapse runs of whitespace/newlines into single spaces so a multi-line
    /// message still fits on one notification line.
    private static func collapse(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func truncate(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength)) + "…"
    }
}
