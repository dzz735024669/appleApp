import Foundation

protocol NamedChoice: RawRepresentable, Hashable, CaseIterable where RawValue == String {
    var label: String { get }
}

enum Category: String, Codable, NamedChoice {
    case work, life
    var label: String { self == .work ? "工作" : "生活" }
}

enum ItemKind: String, Codable, NamedChoice {
    case task, note, event, duty, project, document, paper, award

    var label: String {
        switch self {
        case .task: return "待办"
        case .note: return "记录"
        case .event: return "倒计时"
        case .duty: return "值班"
        case .project: return "项目"
        case .document: return "文档"
        case .paper: return "论文"
        case .award: return "奖项"
        }
    }

    var icon: String {
        switch self {
        case .task: return "checklist"
        case .note: return "note.text"
        case .event: return "timer"
        case .duty: return "calendar"
        case .project: return "folder"
        case .document: return "doc"
        case .paper: return "book.closed"
        case .award: return "rosette"
        }
    }
}

enum ItemStatus: String, Codable, NamedChoice {
    case pending, waiting, completed
    case notStarted = "not_started"
    case inProgress = "in_progress"

    static let taskStatuses: [Self] = [.pending, .inProgress, .waiting, .completed]
    static let projectStatuses: [Self] = [.notStarted, .inProgress, .completed]

    var label: String {
        switch self {
        case .pending: return "待处理"
        case .waiting: return "等待中"
        case .completed: return "已完成"
        case .notStarted: return "未开始"
        case .inProgress: return "进行中"
        }
    }
}

enum Priority: String, Codable, NamedChoice {
    case normal, high, urgent
    var label: String {
        switch self {
        case .normal: return "普通"
        case .high: return "高"
        case .urgent: return "紧急"
        }
    }
}

enum Impact: String, Codable, NamedChoice {
    case minor, moderate, severe
    var label: String {
        switch self {
        case .minor: return "轻微"
        case .moderate: return "中等"
        case .severe: return "严重"
        }
    }
}

enum NoteType: String, Codable, NamedChoice {
    case note, issue, reflection, meeting
    var label: String {
        switch self {
        case .note: return "随手记"
        case .issue: return "问题"
        case .reflection: return "心得"
        case .meeting: return "会议纪要"
        }
    }
}

struct ItemFields: Codable {
    var kind: ItemKind
    var title: String = ""
    var category: Category?
    var projectID: UUID?
    var sourceID: UUID?
    var description: String?
    var status: ItemStatus?
    var priority: Priority?
    var impact: Impact?
    var noteType: NoteType?
    var body: String?
    var dueAt: Date?
    var remindAt: Date?
    var followUpAt: Date?
    var waitingFor: String?
    var targetAt: Date?
    var date: String?
    var reminderEnabled: Bool?
    var authors: String?
    var venue: String?
    var publishedOn: String?
    var publicationURL: String?
    var issuer: String?
    var level: String?
    var awardedOn: String?

    enum CodingKeys: String, CodingKey {
        case kind, title, category, description, status, priority, impact, body, date, authors, venue, issuer, level
        case projectID = "project_id"
        case sourceID = "source_id"
        case noteType = "note_type"
        case dueAt = "due_at"
        case remindAt = "remind_at"
        case followUpAt = "follow_up_at"
        case waitingFor = "waiting_for"
        case targetAt = "target_at"
        case reminderEnabled = "reminder_enabled"
        case publishedOn = "published_on"
        case publicationURL = "publication_url"
        case awardedOn = "awarded_on"
    }

    static func new(_ kind: ItemKind, category: Category? = nil) -> Self {
        var result = Self(kind: kind, category: category)
        switch kind {
        case .task: result.status = .pending; result.priority = .normal
        case .note: result.noteType = .note
        case .event: result.targetAt = Date().addingTimeInterval(3600)
        case .project: result.status = .notStarted
        case .duty:
            result.title = "个人值班"
            result.category = .work
            result.date = BeijingDates.key(Date())
            result.reminderEnabled = true
        case .paper: result.publishedOn = BeijingDates.key(Date())
        case .award: result.awardedOn = BeijingDates.key(Date())
        case .document: break
        }
        return result
    }
}

struct Item: Decodable, Identifiable {
    let id: UUID
    let revision: Int
    let fields: ItemFields
    let daysRemaining: Int?

    private enum CodingKeys: String, CodingKey {
        case id, revision
        case daysRemaining = "days_remaining"
    }

    init(from decoder: Decoder) throws {
        let metadata = try decoder.container(keyedBy: CodingKeys.self)
        id = try metadata.decode(UUID.self, forKey: .id)
        revision = try metadata.decode(Int.self, forKey: .revision)
        daysRemaining = try metadata.decodeIfPresent(Int.self, forKey: .daysRemaining)
        fields = try ItemFields(from: decoder)
    }
}

struct HomeData: Decodable {
    let urgent: [Item]
    let overdue: [Item]
    let dueToday: [Item]
    let waiting: [Item]
    let countdowns: [Item]
    let recent: [Item]
    let nextDuty: Item?

    enum CodingKeys: String, CodingKey {
        case urgent, overdue, waiting, countdowns, recent
        case dueToday = "due_today"
        case nextDuty = "next_duty"
    }
}

struct ItemPage: Decodable {
    let items: [Item]
    let hasMore: Bool
    enum CodingKeys: String, CodingKey { case items; case hasMore = "has_more" }
}

struct Attachment: Decodable, Identifiable {
    let id: UUID
    let filename: String
    let mime: String
    let size: Int
}

struct DutyRule: Encodable, Equatable {
    var anchor: String
    var start: String
    var end: String
    var replace = false
}

struct DutyPreview: Decodable {
    let dates: [String]
    let remove: [String]
}

enum BeijingDates {
    static let timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    static var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = timeZone
        result.firstWeekday = 2
        return result
    }

    static func key(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func parse(_ value: String) -> Date? {
        let pieces = value.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        let parts = DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])
        guard let result = calendar.date(from: parts), key(result) == value else { return nil }
        return result
    }

    static func monthInterval(_ month: Date) -> DateInterval {
        calendar.dateInterval(of: .month, for: month) ?? DateInterval(start: month, duration: 86400)
    }

    static func previousEvening(_ day: Date) -> Date {
        calendar.startOfDay(for: day).addingTimeInterval(-4 * 3600)
    }

    static func format(_ date: Date, pattern: String = "M月d日 HH:mm") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    static func remaining(until date: Date, from now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "已到期" }
        let hours = Int(seconds / 3600)
        if hours >= 24 { return "还有 \(hours / 24) 天 \(hours % 24) 小时" }
        if hours > 0 { return "还有 \(hours) 小时" }
        return "还有 \(Int(ceil(seconds / 60))) 分钟"
    }
}
