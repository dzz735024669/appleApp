import SwiftUI
import WidgetKit

struct WorkbenchEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct WorkbenchWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WorkbenchEntry {
        WorkbenchEntry(date: Date(), snapshot: Self.sampleSnapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (WorkbenchEntry) -> Void) {
        let snapshot = WidgetSnapshotStore.load() ?? (context.isPreview ? Self.sampleSnapshot : .signedOut)
        completion(WorkbenchEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WorkbenchEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshotStore.load() ?? .signedOut
        let todayStart = BeijingDates.calendar.startOfDay(for: now)
        let nextMidnight = BeijingDates.calendar.date(byAdding: .day, value: 1, to: todayStart)
            ?? now.addingTimeInterval(3600 * 6)
        let periodicRefresh = now.addingTimeInterval(30 * 60)
        let reloadAt = min(nextMidnight, periodicRefresh)

        var entries = [WorkbenchEntry(date: now, snapshot: snapshot)]
        if nextMidnight > now {
            entries.append(WorkbenchEntry(date: nextMidnight, snapshot: snapshot))
        }
        completion(Timeline(entries: entries, policy: .after(reloadAt)))
    }

    private static let sampleSnapshot = WidgetSnapshot(
        updatedAt: Date(),
        signedIn: true,
        nextDuty: .init(id: UUID(), date: BeijingDates.key(Date()), title: "个人值班"),
        urgentTasks: [
            .init(id: UUID(), title: "提交模块修改", dueAt: Date().addingTimeInterval(7200), isUrgent: true, isWaiting: false),
            .init(id: UUID(), title: "修复导出乱码", dueAt: Date().addingTimeInterval(14400), isUrgent: false, isWaiting: true)
        ],
        overdueCount: 0,
        dueTodayCount: 2,
        waitingCount: 1
    )
}

private enum WidgetLinks {
    static let home = URL(string: "workbench://home")!
    static let duty = URL(string: "workbench://duty")!
    static let tasks = URL(string: "workbench://tasks")!
    static func item(_ id: UUID) -> URL {
        URL(string: "workbench://item/\(id.uuidString.lowercased())") ?? home
    }
}

struct WorkbenchWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WorkbenchEntry

    private let accent = Color(red: 0.10, green: 0.49, blue: 0.38)

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                smallView
            case .systemMedium:
                mediumView
            case .accessoryCircular:
                circularView
            case .accessoryRectangular:
                rectangularView
            case .accessoryInline:
                inlineView
            default:
                smallView
            }
        }
        .containerBackground(.background, for: .widget)
    }

    // MARK: - Home Screen: Small

    private var smallView: some View {
        let duty = entry.snapshot.activeDuty(at: entry.date)
        let firstTask = entry.snapshot.urgentTasks.first
        let targetURL: URL = {
            if let duty, duty.daysRemaining == 0 { return WidgetLinks.item(duty.summary.id) }
            if let firstTask { return WidgetLinks.item(firstTask.id) }
            return duty != nil ? WidgetLinks.duty : WidgetLinks.home
        }()

        return VStack(alignment: .leading, spacing: 8) {
            if !entry.snapshot.signedIn {
                notSignedInView
            } else {
                dutyBadge(duty)
                Spacer(minLength: 0)
                if let firstTask {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(firstTask.isUrgent || firstTask.isOverdue(at: entry.date) ? Color.red : accent)
                                .frame(width: 6, height: 6)
                            Text(firstTask.isUrgent ? "紧急待办" : (firstTask.isOverdue(at: entry.date) ? "已逾期" : "今日到期"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(firstTask.isUrgent || firstTask.isOverdue(at: entry.date) ? Color.red : .secondary)
                        }
                        Text(firstTask.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                        if entry.snapshot.urgentTasks.count > 1 {
                            Text("另有 \(entry.snapshot.urgentTasks.count - 1) 项重点待办")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Label("暂无紧急待办", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(targetURL)
    }

    // MARK: - Home Screen: Medium

    private var mediumView: some View {
        let duty = entry.snapshot.activeDuty(at: entry.date)

        return Group {
            if !entry.snapshot.signedIn {
                notSignedInView
                    .widgetURL(WidgetLinks.home)
            } else {
                HStack(spacing: 12) {
                    Link(destination: duty.map { WidgetLinks.item($0.summary.id) } ?? WidgetLinks.duty) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(duty?.daysRemaining == 0 ? "今日值班" : "个人值班",
                                  systemImage: "calendar.badge.clock")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(duty?.daysRemaining == 0 ? Color.white : accent)
                            Spacer(minLength: 0)
                            if let duty {
                                if duty.daysRemaining == 0 {
                                    Text("今天")
                                        .font(.title2.bold())
                                        .foregroundStyle(.white)
                                    Text("\(shortDate(duty.summary.date)) · 全天")
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.9))
                                } else {
                                    Text("还有 \(duty.daysRemaining) 天")
                                        .font(.title3.bold())
                                        .foregroundStyle(.primary)
                                    Text(shortDate(duty.summary.date))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text("暂无排班")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: 118, maxHeight: .infinity, alignment: .leading)
                        .background(
                            duty?.daysRemaining == 0 ? accent : accent.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("重点待办")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if entry.snapshot.overdueCount > 0 {
                                Text("逾期 \(entry.snapshot.overdueCount)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.red)
                            } else if entry.snapshot.waitingCount > 0 {
                                Text("等待 \(entry.snapshot.waitingCount)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if entry.snapshot.urgentTasks.isEmpty {
                            Spacer(minLength: 0)
                            Link(destination: WidgetLinks.tasks) {
                                Label("当前无紧急或今日待办", systemImage: "checkmark.circle")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        } else {
                            ForEach(entry.snapshot.urgentTasks.prefix(3)) { task in
                                Link(destination: WidgetLinks.item(task.id)) {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(task.isUrgent || task.isOverdue(at: entry.date) ? Color.red : accent)
                                            .frame(width: 6, height: 6)
                                        Text(task.title)
                                            .font(.footnote.weight(.medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                        if let due = task.dueAt {
                                            Text(BeijingDates.format(due, pattern: "M/d HH:mm"))
                                                .font(.caption2)
                                                .foregroundStyle(task.isOverdue(at: entry.date) ? .red : .secondary)
                                        }
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Lock Screen: Circular / Rectangular / Inline

    private var circularView: some View {
        let duty = entry.snapshot.activeDuty(at: entry.date)
        return ZStack {
            AccessoryWidgetBackground()
            if !entry.snapshot.signedIn {
                Image(systemName: "square.grid.2x2")
            } else if let duty {
                VStack(spacing: 1) {
                    if duty.daysRemaining == 0 {
                        Image(systemName: "calendar.badge.clock").font(.caption)
                        Text("值班").font(.caption2.bold())
                    } else {
                        Text("\(duty.daysRemaining)天").font(.headline.bold()).minimumScaleFactor(0.7)
                        Text("值班").font(.caption2)
                    }
                }
            } else {
                VStack(spacing: 1) {
                    Text("\(entry.snapshot.urgentTasks.count)").font(.headline.bold())
                    Text("待办").font(.caption2)
                }
            }
        }
        .widgetURL(duty.map { WidgetLinks.item($0.summary.id) } ?? WidgetLinks.tasks)
    }

    private var rectangularView: some View {
        let duty = entry.snapshot.activeDuty(at: entry.date)
        let topTasks = Array(entry.snapshot.urgentTasks.prefix(2))
        return VStack(alignment: .leading, spacing: 2) {
            if !entry.snapshot.signedIn {
                Text("个人工作台").font(.headline)
                Text("打开 App 登录同步").font(.caption)
            } else {
                if let duty {
                    let header = duty.daysRemaining == 0
                        ? "今日值班 · \(shortDate(duty.summary.date))"
                        : "\(duty.daysRemaining)天后值班 · \(shortDate(duty.summary.date))"
                    Text(header)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                } else {
                    Text("个人工作台").font(.caption.weight(.bold))
                }
                if topTasks.isEmpty {
                    Text("暂无紧急或今日待办").font(.caption2).foregroundStyle(.secondary)
                } else {
                    ForEach(topTasks) { task in
                        Text("• \(task.title)")
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(topTasks.first.map { WidgetLinks.item($0.id) } ?? WidgetLinks.duty)
    }

    private var inlineView: some View {
        let duty = entry.snapshot.activeDuty(at: entry.date)
        let count = entry.snapshot.urgentTasks.count
        let label: String = {
            guard entry.snapshot.signedIn else { return "个人工作台 · 未登录" }
            var parts: [String] = []
            if let duty {
                parts.append(duty.daysRemaining == 0 ? "今日值班" : "\(duty.daysRemaining)天后值班")
            }
            if count > 0 {
                parts.append("\(count)项重点待办")
            }
            return parts.isEmpty ? "暂无值班与紧急待办" : parts.joined(separator: " · ")
        }()
        return Label(label, systemImage: duty?.daysRemaining == 0 ? "calendar.badge.clock" : "checklist")
            .widgetURL(duty?.daysRemaining == 0 ? WidgetLinks.duty : WidgetLinks.tasks)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func dutyBadge(_ duty: (summary: WidgetSnapshot.DutySummary, daysRemaining: Int)?) -> some View {
        if let duty {
            let isToday = duty.daysRemaining == 0
            HStack(spacing: 4) {
                Image(systemName: "calendar.badge.clock")
                    .font(.caption2)
                Text(isToday ? "今日值班" : "\(duty.daysRemaining)天后值班")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text(shortDate(duty.summary.date))
                    .font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(isToday ? Color.white : accent)
            .background(isToday ? accent : accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Label("个人工作台", systemImage: "square.grid.2x2.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
        }
    }

    private var notSignedInView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("个人工作台", systemImage: "square.grid.2x2.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
            Text("打开 App 登录后显示值班与紧急待办")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func shortDate(_ key: String) -> String {
        guard let date = BeijingDates.parse(key) else { return key }
        return BeijingDates.format(date, pattern: "M月d日")
    }
}

@main
struct WorkbenchWidget: Widget {
    let kind = "WorkbenchOverviewWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WorkbenchWidgetProvider()) { entry in
            WorkbenchWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("值班与重点待办")
        .description("在主屏幕或锁屏查看今日/下次值班与紧急、逾期和今日待办。")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}
