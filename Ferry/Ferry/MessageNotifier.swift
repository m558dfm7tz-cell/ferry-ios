import Foundation
import UserNotifications

/// Posts local notifications for newly arrived Ferry messages and keeps the
/// app icon badge in sync with the unread count.
///
/// Ferry has no APNs certificate and no paid relay, so every notification here
/// is a plain `UNUserNotificationCenter` local notification created by the app
/// itself while it still has execution time — foreground, or the short
/// background grace window granted by `UIApplication.beginBackgroundTask`.
/// Once the system suspends the app nothing can wake it, which is the one hard
/// limitation of this approach (see `PushRegistrationServicing` for the seam a
/// future push backend plugs into).
@MainActor
final class MessageNotifier {
    static let shared = MessageNotifier()

    private let center: UNUserNotificationCenter
    private let settings: NotificationSettings

    /// Set by `AppModel`: routes a tapped notification to its conversation.
    var onRoute: ((NotificationRoute) -> Void)?

    /// Seam for a future APNs (or self-hosted relay) backend. Ships as a no-op.
    var pushRegistration: any PushRegistrationServicing = NoopPushRegistration()

    init(center: UNUserNotificationCenter = .current(), settings: NotificationSettings = .shared) {
        self.center = center
        self.settings = settings
    }

    /// Install the `UNUserNotificationCenter` delegate. Must happen before the
    /// app finishes launching (see `FerryAppDelegate`).
    func configure(delegate: UNUserNotificationCenterDelegate) {
        center.delegate = delegate
    }

    /// Ask for alert/sound/badge permission. Safe to call repeatedly: iOS only
    /// shows its prompt once per install.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard settings.isEnabled else { return false }
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// Whether notifications can actually be delivered right now.
    func isAuthorized() async -> Bool {
        let current = await center.notificationSettings()
        return current.authorizationStatus == .authorized
            || current.authorizationStatus == .provisional
    }

    /// Show one local notification for a single new message.
    func notify(message: MessagePayload, assistant: Assistant?, origin: String) async {
        guard settings.isEnabled else { return }
        guard await isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = NotificationSummary.title(for: message, assistant: assistant)
        content.body = NotificationSummary.body(for: message)
        content.sound = .default
        content.categoryIdentifier = NotificationPayloadKey.category
        // Group by conversation so iOS stacks a burst under one header.
        content.threadIdentifier = assistant?.id ?? "device-\(message.senderName)"
        content.userInfo[NotificationPayloadKey.messageID] = message.id
        content.userInfo[NotificationPayloadKey.origin] = origin
        if let assistantID = assistant?.id {
            content.userInfo[NotificationPayloadKey.assistantID] = assistantID
        }
        let request = UNNotificationRequest(identifier: "ferry.message.\(origin).\(message.id)",
                                            content: content,
                                            trigger: nil)
        try? await center.add(request)
    }

    /// Update the app icon badge. Clearing it to 0 also removes every delivered
    /// notification, so "读后清零" leaves nothing behind.
    func setBadge(_ count: Int) async {
        try? await center.setBadgeCount(count)
        guard count == 0 else { return }
        center.removeAllDeliveredNotifications()
    }

    /// Notifications switched off: drop the badge and everything already shown.
    func clearAll() async {
        try? await center.setBadgeCount(0)
        center.removeAllDeliveredNotifications()
    }
}

/// Delivers notifications that arrive while Ferry is open, and opens the right
/// conversation when one is tapped. Installed once from `FerryAppDelegate`.
final class FerryNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = FerryNotificationDelegate()

    /// A notification can only reach the app while it is in the foreground if
    /// it belongs to a conversation the user is *not* looking at (see
    /// `AppModel.registerIncoming`), so showing it is never a duplicate.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// Tapping a notification opens the conversation (and message) it came from.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let route = NotificationRoute(
            assistantID: userInfo[NotificationPayloadKey.assistantID] as? String,
            messageID: userInfo[NotificationPayloadKey.messageID] as? String,
            origin: userInfo[NotificationPayloadKey.origin] as? String
        )
        Task { @MainActor in MessageNotifier.shared.onRoute?(route) }
        completionHandler()
    }
}

/// Seam for a future APNs (or self-hosted relay) push backend.
///
/// Ferry currently runs entirely on the LAN with no push certificate, so the
/// shipped implementation is `NoopPushRegistration`. When a certificate or
/// relay becomes available, implement this protocol (upload the device token to
/// the Ferry server, subscribe to silent pushes, wake `AppModel` to poll) and
/// assign it to `MessageNotifier.shared.pushRegistration` — no call site in the
/// app has to change, and `AppModel.registerIncoming(_:)` keeps working
/// unchanged because it is fed by messages, not by the transport.
@MainActor
protocol PushRegistrationServicing {
    /// Ask iOS for a device token (no-op until a push entitlement exists).
    func registerForRemoteNotifications()
    func didRegister(deviceToken: Data)
    func didFailToRegister(error: Error)
}

@MainActor
struct NoopPushRegistration: PushRegistrationServicing {
    func registerForRemoteNotifications() {
        // Deliberately not calling UIApplication.shared
        // .registerForRemoteNotifications(): without the push entitlement it
        // always fails, so registering would only produce console noise.
    }

    func didRegister(deviceToken: Data) {
        // A future APNs backend would upload `deviceToken` to the Ferry server
        // here (paired with the per-device token already stored in Keychain).
    }

    func didFailToRegister(error: Error) {
        // No push backend: a failed registration is expected and harmless.
    }
}
