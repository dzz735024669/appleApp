import SwiftUI
import UIKit
import WidgetKit

enum WorkbenchTheme {
    static let blue = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.38, green: 0.58, blue: 1, alpha: 1)
            : UIColor(red: 0.14, green: 0.33, blue: 0.84, alpha: 1)
    })
    static let action = Color(red: 0.14, green: 0.33, blue: 0.84)
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .systemBackground
            : UIColor(red: 0.96, green: 0.97, blue: 0.985, alpha: 1)
    })
}

@main
@MainActor
struct WorkbenchApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var push
    @StateObject private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            Group {
                if let api = session.api {
                    MainTabs(api: api)
                } else {
                    SignInView()
                }
            }
            .environmentObject(session)
            .environmentObject(push)
            .environment(\.timeZone, BeijingDates.timeZone)
            .environment(\.calendar, BeijingDates.calendar)
            .tint(WorkbenchTheme.blue)
            .task { await session.restore() }
        }
    }
}

struct ItemRoute: Identifiable, Hashable {
    let id: UUID
}

@MainActor
struct MainTabs: View {
    private enum Tab: Hashable { case home, tasks, duty, library }

    let api: WorkbenchAPI
    @EnvironmentObject private var push: PushDelegate
    @EnvironmentObject private var session: SessionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Tab = .home
    @State private var incoming: ItemRoute?

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { HomeView(api: api) { selectedTab = .tasks } }
                .tag(Tab.home)
                .tabItem { Label("今天", systemImage: "house") }
            NavigationStack { ItemListView(api: api, mode: .tasks) }
                .tag(Tab.tasks)
                .tabItem { Label("待办", systemImage: "checklist") }
            NavigationStack { DutyCalendarView(api: api) }
                .tag(Tab.duty)
                .tabItem { Label("值班", systemImage: "calendar") }
            NavigationStack { ItemListView(api: api, mode: .library) }
                .tag(Tab.library)
                .tabItem { Label("资料", systemImage: "folder") }
        }
        .task { await push.registerIfEnabled() }
        .task(id: "\(session.refreshVersion):\(push.localReminderEnabled)") {
            await push.syncLocalReminders(api: api)
        }
        .task(id: session.refreshVersion) {
            await syncWidgetSnapshot()
        }
        .task(id: push.token) {
            if let token = push.token {
                await session.syncPush(token, environment: push.environment)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                session.changed()
                Task { await push.registerIfEnabled() }
            }
        }
        .onChange(of: push.pendingItemID, initial: true) { _, id in
            if let id {
                incoming = ItemRoute(id: id)
                push.pendingItemID = nil
            }
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .sheet(item: $incoming) { route in
            NavigationStack {
                ItemDetail(api: api, id: route.id)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { incoming = nil }
                        }
                    }
            }
        }
    }

    private func syncWidgetSnapshot() async {
        do {
            let home = try await api.home(category: nil)
            guard !Task.isCancelled else { return }
            WidgetSnapshotStore.save(.from(home: home))
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // Keep last valid widget snapshot on transient network failures.
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "workbench" else { return }
        switch url.host {
        case "home":
            selectedTab = .home
        case "tasks":
            selectedTab = .tasks
        case "duty":
            selectedTab = .duty
        case "item":
            if let raw = url.pathComponents.dropFirst().first, let id = UUID(uuidString: raw) {
                incoming = ItemRoute(id: id)
            }
        default:
            break
        }
    }
}

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var push: PushDelegate
    @State private var signingOut = false

    var body: some View {
        Form {
            Section("连接") {
                LabeledContent("账号", value: session.username)
                LabeledContent("服务器", value: WorkbenchAPI.serverHostDisplay)
                LabeledContent("日历时区", value: "北京时间")
            }
            Section("小组件") {
                LabeledContent("共享权限", value: WidgetSnapshotStore.isAvailable ? "可用" : "不可用")
                Button("同步小组件") { session.changed() }
                    .disabled(!WidgetSnapshotStore.isAvailable)
            }
            Section("提醒") {
                if push.buildSupportsPush {
                    Text(session.pushMessage ?? push.status)
                        .foregroundStyle(.secondary)
                    Button(push.optedIn ? "重新注册提醒" : "开启 iPhone 提醒") {
                        Task {
                            await push.enable()
                            if let token = push.token { await session.syncPush(token, environment: push.environment) }
                        }
                    }
                    if push.optedIn {
                        Button("关闭本机提醒") {
                            Task { if await session.disablePush() { push.disableLocally() } }
                        }
                    }
                } else {
                    Label("此构建未启用 Apple 远程推送", systemImage: "bell.badge")
                        .foregroundStyle(.secondary)
                    Text(push.localStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let api = session.api {
                        Button(push.localReminderEnabled ? "立即同步本机提醒" : "开启本机提醒") {
                            Task { await push.enableLocalReminders(api: api) }
                        }
                        if push.localReminderEnabled {
                            Button("关闭本机提醒") { push.disableLocalReminders() }
                        }
                    }
                }
            }
            Section {
                if let message = session.message { Text(message).foregroundStyle(.red) }
                Button("退出登录", role: .destructive) { signingOut = true }
                    .disabled(session.loading)
            }
        }
        .navigationTitle("设置")
        .confirmationDialog("退出当前工作台？", isPresented: $signingOut, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                Task { await session.signOut() }
            }
        }
    }
}

struct InlineError: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .foregroundStyle(.red)
            .font(.callout)
    }
}

struct ItemRow: View {
    let item: Item

    private var isOverdue: Bool {
        item.fields.kind == .task && item.fields.status != .completed
            && (item.fields.dueAt.map { $0 < Date() } ?? false)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.fields.kind.icon)
                .foregroundStyle(item.fields.status == .completed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 23)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fields.title)
                    .font(.body.weight(.medium))
                    .strikethrough(item.fields.status == .completed)
                    .foregroundStyle(item.fields.status == .completed ? .secondary : .primary)
                if let target = item.fields.targetAt {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(BeijingDates.remaining(until: target, from: context.date))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    let labels = [item.fields.status?.label, item.fields.category?.label,
                                  item.fields.dueAt.map { BeijingDates.format($0) }, item.fields.date]
                        .compactMap { $0 }
                    if !labels.isEmpty {
                        Text(labels.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(isOverdue ? Color.red : Color.secondary)
                    }
                    if item.fields.status == .waiting, let waiting = item.fields.waitingFor, !waiting.isEmpty {
                        Text("等：\(waiting)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                if item.fields.priority == .urgent && item.fields.status != .completed {
                    Text("紧急").foregroundStyle(.red).font(.caption.weight(.semibold))
                }
                if isOverdue {
                    Text("已逾期").foregroundStyle(.red).font(.caption2.weight(.semibold))
                } else if item.fields.impact == .severe && item.fields.status != .completed {
                    Text("严重").foregroundStyle(.orange).font(.caption2.weight(.semibold))
                }
            }
        }
        .padding(.vertical, 3)
    }
}
