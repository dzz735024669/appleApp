import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    @Published private(set) var token: String?
    @Published private(set) var status: String = "可在此开启待办和值班提醒"
    @Published var pendingItemID: UUID?
    @Published private(set) var optedIn = UserDefaults.standard.bool(forKey: "workbench.pushOptedIn")

    var buildSupportsPush: Bool { Bundle.main.object(forInfoDictionaryKey: "WorkbenchAPNSEnabled") as? String == "YES" }
    var environment: String { Bundle.main.object(forInfoDictionaryKey: "WorkbenchAPNSEnvironment") as? String ?? "development" }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func enable() async {
        guard buildSupportsPush else { return }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            guard granted else { status = "请在 iPhone 设置中允许工作台发送通知"; return }
            optedIn = true
            UserDefaults.standard.set(true, forKey: "workbench.pushOptedIn")
            UIApplication.shared.registerForRemoteNotifications()
        } catch { status = error.localizedDescription }
    }

    func registerIfEnabled() async {
        guard buildSupportsPush, optedIn else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        default:
            status = "请在 iPhone 设置中允许工作台发送通知"
        }
    }

    func disableLocally() {
        optedIn = false
        UserDefaults.standard.set(false, forKey: "workbench.pushOptedIn")
        token = nil
        UIApplication.shared.unregisterForRemoteNotifications()
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard optedIn else { return }
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        status = "已获取系统通知凭据"
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        status = "系统通知注册失败：\(error.localizedDescription)"
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                          withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                          withCompletionHandler completionHandler: @escaping () -> Void) {
        if let value = response.notification.request.content.userInfo["item_id"] as? String,
           let id = UUID(uuidString: value) {
            Task { @MainActor [weak self] in self?.pendingItemID = id }
        }
        completionHandler()
    }
}
