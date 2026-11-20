import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    @Published private(set) var token: String?
    @Published private(set) var status: String = "可在此开启待办和值班提醒"
    @Published var pendingItemID: UUID?
    @Published private(set) var optedIn = UserDefaults.standard.bool(forKey: "workbench.pushOptedIn")
    @Published private(set) var localReminderEnabled = UserDefaults.standard.bool(forKey: "workbench.localReminderEnabled")
    @Published private(set) var localStatus: String = "免费试装版支持本机提醒，打开 App 时自动同步未来提醒"
    private static let localPrefix = "workbench.local."

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

    func enableLocalReminders(api: WorkbenchAPI) async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            guard granted else {
                localStatus = "请在 iPhone 设置中允许工作台发送通知"
                return
            }
            localReminderEnabled = true
            UserDefaults.standard.set(true, forKey: "workbench.localReminderEnabled")
            await syncLocalReminders(api: api)
        } catch {
            localStatus = error.localizedDescription
        }
    }

    func disableLocalReminders() {
        localReminderEnabled = false
        UserDefaults.standard.set(false, forKey: "workbench.localReminderEnabled")
        let center = UNUserNotificationCenter.current()
        let prefix = Self.localPrefix
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
        }
        localStatus = "本机提醒已关闭"
    }

    func syncLocalReminders(api: WorkbenchAPI) async {
        guard !buildSupportsPush, localReminderEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        default:
            localStatus = "请在 iPhone 设置中允许工作台发送通知"
            return
        }
        do {
            let now = Date()
            let todayKey = BeijingDates.key(now)
            let horizonKey = BeijingDates.key(now.addingTimeInterval(60 * 86400))
            async let tasksPage = api.items(kind: .task, offset: 0)
            async let eventsPage = api.items(kind: .event, offset: 0)
            async let dutyList = api.shifts(start: todayKey, end: horizonKey)
            let (tasks, events, duties) = try await (tasksPage.items, eventsPage.items, dutyList)

            struct Planned {
                let id: String
                let itemID: UUID
                let subtitle: String
                let body: String
                let date: Date
            }

            var planned: [Planned] = []
            for task in tasks where task.fields.status != .completed {
                if let remind = task.fields.remindAt, remind > now {
                    planned.append(.init(id: "\(Self.localPrefix)\(task.id.uuidString).reminder",
                                         itemID: task.id, subtitle: "待办提醒", body: task.fields.title, date: remind))
                }
                if task.fields.status == .waiting, let follow = task.fields.followUpAt, follow > now {
                    planned.append(.init(id: "\(Self.localPrefix)\(task.id.uuidString).follow_up",
                                         itemID: task.id, subtitle: "跟进提醒", body: task.fields.title, date: follow))
                }
            }
            for event in events {
                if let remind = event.fields.remindAt, remind > now {
                    planned.append(.init(id: "\(Self.localPrefix)\(event.id.uuidString).reminder",
                                         itemID: event.id, subtitle: "倒计时提醒", body: event.fields.title, date: remind))
                }
            }
            for duty in duties {
                if duty.fields.reminderEnabled != false, let remind = duty.fields.remindAt, remind > now {
                    let dateText = duty.fields.date ?? "全天"
                    planned.append(.init(id: "\(Self.localPrefix)\(duty.id.uuidString).duty",
                                         itemID: duty.id, subtitle: "值班提醒", body: "\(dateText) · \(duty.fields.title)", date: remind))
                }
            }

            planned.sort { $0.date < $1.date }
            let scheduled = Array(planned.prefix(50))

            let existing = await center.pendingNotificationRequests()
            let oldIDs = existing.map(\.identifier).filter { $0.hasPrefix(Self.localPrefix) }
            if !oldIDs.isEmpty { center.removePendingNotificationRequests(withIdentifiers: oldIDs) }

            for entry in scheduled {
                let content = UNMutableNotificationContent()
                content.title = "个人工作台 · \(entry.subtitle)"
                content.body = entry.body
                content.sound = .default
                content.userInfo = ["item_id": entry.itemID.uuidString]
                let interval = max(1, entry.date.timeIntervalSinceNow)
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                try await center.add(UNNotificationRequest(identifier: entry.id, content: content, trigger: trigger))
            }
            localStatus = scheduled.isEmpty ? "当前没有待发送的未来提醒" : "已同步 \(scheduled.count) 条未来本机提醒"
        } catch {
            if !Task.isCancelled { localStatus = "本机提醒同步失败：\(error.localizedDescription)" }
        }
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
