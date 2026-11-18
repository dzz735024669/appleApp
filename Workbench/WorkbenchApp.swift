import SwiftUI
import UIKit

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
            .tint(Color(red: 0.10, green: 0.49, blue: 0.38))
            .task { await session.restore() }
        }
    }
}

struct ItemRoute: Identifiable, Hashable {
    let id: UUID
}

@MainActor
struct MainTabs: View {
    let api: WorkbenchAPI
    @EnvironmentObject private var push: PushDelegate
    @EnvironmentObject private var session: SessionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var incoming: ItemRoute?

    var body: some View {
        TabView {
            NavigationStack { HomeView(api: api) }
                .tabItem { Label("首页", systemImage: "house") }
            NavigationStack { ItemListView(api: api, mode: .tasks) }
                .tabItem { Label("待办", systemImage: "checklist") }
            NavigationStack { DutyCalendarView(api: api) }
                .tabItem { Label("值班", systemImage: "calendar") }
            NavigationStack { ItemListView(api: api, mode: .library) }
                .tabItem { Label("资料", systemImage: "folder") }
            NavigationStack { SettingsView() }
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
        .task { await push.registerIfEnabled() }
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
}

@MainActor
private struct SettingsView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var push: PushDelegate
    @State private var signingOut = false

    var body: some View {
        Form {
            Section("连接") {
                LabeledContent("账号", value: session.username)
                LabeledContent("服务器", value: "dzz.mcdkf.top:7736")
                LabeledContent("日历时区", value: "北京时间")
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
                    Label("此构建未启用 Apple 推送", systemImage: "bell.slash")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if let message = session.message { Text(message).foregroundStyle(.red) }
                Button("退出登录", role: .destructive) { signingOut = true }
                    .disabled(session.loading)
            }
        }
        .navigationTitle("我的")
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.fields.kind.icon)
                .foregroundStyle(.tint)
                .frame(width: 23)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fields.title).font(.body.weight(.medium))
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
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if item.fields.priority == .urgent && item.fields.status != .completed {
                Text("紧急").foregroundStyle(.red).font(.caption.weight(.semibold))
            }
        }
        .padding(.vertical, 3)
    }
}
