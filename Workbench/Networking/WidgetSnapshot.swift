import Foundation

struct WidgetSnapshot: Codable, Equatable {
    struct DutySummary: Codable, Equatable {
        let id: UUID
        let date: String
        let title: String

        func daysRemaining(from now: Date = Date()) -> Int? {
            guard let target = BeijingDates.parse(date) else { return nil }
            let todayStart = BeijingDates.calendar.startOfDay(for: now)
            return BeijingDates.calendar.dateComponents([.day], from: todayStart, to: target).day
        }
    }

    struct TaskSummary: Codable, Equatable, Identifiable {
        let id: UUID
        let title: String
        let dueAt: Date?
        let isUrgent: Bool
        let isWaiting: Bool

        func isOverdue(at now: Date = Date()) -> Bool {
            guard let dueAt else { return false }
            return dueAt < now
        }
    }

    let updatedAt: Date
    let signedIn: Bool
    let nextDuty: DutySummary?
    let urgentTasks: [TaskSummary]
    let overdueCount: Int
    let dueTodayCount: Int
    let waitingCount: Int

    static let signedOut = WidgetSnapshot(
        updatedAt: Date(),
        signedIn: false,
        nextDuty: nil,
        urgentTasks: [],
        overdueCount: 0,
        dueTodayCount: 0,
        waitingCount: 0
    )

    static func from(home: HomeData, now: Date = Date()) -> WidgetSnapshot {
        let duty: DutySummary? = home.nextDuty.flatMap { item in
            guard let date = item.fields.date else { return nil }
            return DutySummary(id: item.id, date: date, title: item.fields.title)
        }

        var seen: Set<UUID> = []
        var tasks: [TaskSummary] = []
        let urgentIDs = Set(home.urgent.map(\.id))

        func appendItems(_ list: [Item]) {
            for item in list where item.fields.status != .completed && !seen.contains(item.id) {
                seen.insert(item.id)
                tasks.append(TaskSummary(
                    id: item.id,
                    title: item.fields.title,
                    dueAt: item.fields.dueAt,
                    isUrgent: urgentIDs.contains(item.id) || item.fields.priority == .urgent,
                    isWaiting: item.fields.status == .waiting
                ))
            }
        }

        appendItems(home.urgent)
        appendItems(home.overdue)
        appendItems(home.dueToday)

        return WidgetSnapshot(
            updatedAt: now,
            signedIn: true,
            nextDuty: duty,
            urgentTasks: Array(tasks.prefix(5)),
            overdueCount: home.overdue.count,
            dueTodayCount: home.dueToday.count,
            waitingCount: home.waiting.count
        )
    }

    func activeDuty(at now: Date = Date()) -> (summary: DutySummary, daysRemaining: Int)? {
        guard let nextDuty, let days = nextDuty.daysRemaining(from: now), days >= 0 else { return nil }
        return (nextDuty, days)
    }
}

enum WidgetSnapshotStore {
    static let appGroupID = "group.top.mcdkf.dzz.workbench"
    static let storageKey = "workbench.widget.snapshot.v1"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func save(_ snapshot: WidgetSnapshot, to defaults: UserDefaults? = nil) {
        guard let store = defaults ?? Self.defaults,
              let data = try? WorkbenchAPI.encoder().encode(snapshot) else { return }
        store.set(data, forKey: storageKey)
    }

    static func load(from defaults: UserDefaults? = nil) -> WidgetSnapshot? {
        guard let store = defaults ?? Self.defaults,
              let data = store.data(forKey: storageKey) else { return nil }
        return try? WorkbenchAPI.decoder().decode(WidgetSnapshot.self, from: data)
    }
}
