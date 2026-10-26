import SwiftUI
import UIKit
import UserNotifications

@main
struct FerryApp: App {
    @UIApplicationDelegateAdaptor(FerryAppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in model.setActive(phase == .active) }
        }
    }
}

/// Exists only to install the notification delegate and to surface the two
/// remote-notification callbacks, which are the seam an APNs backend plugs into
/// later (see `PushRegistrationServicing`). Scene lifecycle still belongs to
/// SwiftUI — no `UISceneDelegate`-style methods are implemented here.
final class FerryAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The delegate has to be in place before the app finishes launching,
        // so it is installed synchronously rather than inside a Task.
        MainActor.assumeIsolated {
            MessageNotifier.shared.configure(delegate: FerryNotificationDelegate.shared)
        }
        Task { @MainActor in await MessageNotifier.shared.requestAuthorization() }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            MessageNotifier.shared.pushRegistration.didRegister(deviceToken: deviceToken)
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            MessageNotifier.shared.pushRegistration.didFailToRegister(error: error)
        }
    }
}
