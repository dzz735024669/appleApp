import SwiftUI

@MainActor
struct DutyCalendarView: View {
    let api: WorkbenchAPI
    @EnvironmentObject private var session: SessionStore
    @State private var month = BeijingDates.monthInterval(.now).start
    @State private var shifts: [Item] = []
    @State private var error: String?
    @State private var loading = true
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var saving = false
    @State private var sheet: CalendarSheet?
    @State private var detail: ItemRoute?

    private let columns = Array(repeating: GridItem(.flexible(minimum: 24), spacing: 3), count: 7)
    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
    private var currentMonth: DateInterval { BeijingDates.monthInterval(month) }

    var body: some View {
        List {
            Section {
                HStack {
                    monthButton(-1, title: "上个月", icon: "chevron.left")
                    Spacer()
                    Text(BeijingDates.format(month, pattern: "yyyy年 M月"))
                        .font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    monthButton(1, title: "下个月", icon: "chevron.right")
                }
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(weekdays, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    let calendarDays = days
                    ForEach(calendarDays.indices, id: \.self) { index in
                        if let day = calendarDays[index] { dayButton(day) }
                        else { Color.clear.frame(height: 45).accessibilityHidden(true) }
                    }
                }
                .padding(.vertical, 6)
            } footer: {
                Text("全天轮值 · 默认前一天 20:00 提醒 · 北京时间")
            }
            if selecting {
                Section {
                    Button(saving ? "正在保存…" : "保存所选日期（\(selected.count)）") {
                        Task { await saveSelection() }
                    }
                    .disabled(saving || selected.isEmpty)
                    Button("取消多选") { selecting = false; selected.removeAll() }.disabled(saving)
                }
            }
            if let error { InlineError(message: error) }
            Section("本月值班") {
                if loading && shifts.isEmpty { ProgressView() }
                else if shifts.isEmpty { Text("本月暂无值班").foregroundStyle(.secondary) }
                ForEach(shifts) { shift in
                    NavigationLink { ItemDetail(api: api, id: shift.id) } label: { shiftRow(shift) }
                }
            }
        }
        .navigationTitle("值班日历")
        .toolbar {
            if !isCurrentMonth {
                ToolbarItem(placement: .topBarLeading) {
                    Button("本月") { month = BeijingDates.monthInterval(.now).start }
                        .disabled(saving)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("生成 9 天轮值", systemImage: "calendar.badge.plus") { sheet = .schedule }
                    Button("添加单次值班", systemImage: "plus") { sheet = .single(BeijingDates.key(.now)) }
                    Button("多选日期添加", systemImage: "checkmark.circle") { selecting = true; selected.removeAll() }
                } label: { Label("排班设置", systemImage: "ellipsis.circle") }
                .disabled(saving)
            }
        }
        .task(id: "\(BeijingDates.key(month)):\(session.refreshVersion)") { await load() }
        .refreshable { await load() }
        .sheet(item: $sheet) { route in
            NavigationStack {
                switch route {
                case .schedule: DutyScheduleEditor(api: api, month: month) { session.changed() }
                case .single(let day):
                    ItemEditor(api: api, draft: dutyDraft(day)) { _ in session.changed() }
                }
            }
        }
        .navigationDestination(item: $detail) { route in ItemDetail(api: api, id: route.id) }
    }

    private var days: [Date?] {
        let calendar = BeijingDates.calendar
        let first = currentMonth.start
        let leading = (calendar.component(.weekday, from: first) - 2 + 7) % 7
        let range = calendar.range(of: .day, in: .month, for: first) ?? (1..<2)
        return Array(repeating: nil, count: leading) + range.map { calendar.date(byAdding: .day, value: $0 - 1, to: first) }
    }

    private func dutyDraft(_ day: String) -> ItemFields {
        var draft = ItemFields.new(.duty)
        draft.date = day
        return draft
    }

    private var isCurrentMonth: Bool {
        BeijingDates.key(month) == BeijingDates.key(BeijingDates.monthInterval(.now).start)
    }

    private func shiftRow(_ shift: Item) -> some View {
        let todayKey = BeijingDates.key(.now)
        let dateKey = shift.fields.date ?? ""
        let stateLabel: String
        let stateColor: Color
        if dateKey == todayKey {
            stateLabel = "今日值班"
            stateColor = .accentColor
        } else if dateKey < todayKey {
            stateLabel = "已过去"
            stateColor = .secondary
        } else {
            stateLabel = "即将值班"
            stateColor = .primary
        }
        return HStack {
            ItemRow(item: shift)
            Text(stateLabel)
                .font(.caption.weight(dateKey == todayKey ? .semibold : .regular))
                .foregroundStyle(stateColor)
        }
        .opacity(dateKey < todayKey ? 0.65 : 1)
    }

    private func monthButton(_ offset: Int, title: String, icon: String) -> some View {
        Button {
            if let next = BeijingDates.calendar.date(byAdding: .month, value: offset, to: month) {
                month = next
            }
        } label: {
            Image(systemName: icon).frame(width: 44, height: 44).accessibilityLabel(title)
        }
        .buttonStyle(.borderless)
        .disabled(saving)
    }

    private func dayButton(_ day: Date) -> some View {
        let key = BeijingDates.key(day)
        let todayKey = BeijingDates.key(.now)
        let shift = shifts.first(where: { $0.fields.date == key })
        let isSelected = selected.contains(key)
        let isToday = key == todayKey
        let isPast = key < todayKey
        return Button {
            if selecting {
                guard shift == nil else { return }
                if !selected.insert(key).inserted { selected.remove(key) }
            } else if let shift { detail = ItemRoute(id: shift.id) }
            else { sheet = .single(key) }
        } label: {
            VStack(spacing: 2) {
                Text(BeijingDates.format(day, pattern: "d"))
                    .font(.body.weight(shift == nil && !isToday ? .regular : .semibold))
                if isSelected { Image(systemName: "checkmark").font(.caption2) }
                else if shift != nil { Text(isToday ? "今日" : "值班").font(.caption2) }
                else if isToday { Text("今天").font(.caption2) }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(isSelected ? Color.white
                             : (shift != nil ? (isPast ? Color.secondary : Color.accentColor)
                                : (isPast ? Color.secondary : Color.primary)))
            .background(isSelected ? Color.accentColor
                        : (shift != nil ? Color.accentColor.opacity(isToday ? 0.25 : (isPast ? 0.06 : 0.14))
                           : Color.accentColor.opacity(0.02)),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(isToday && !isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(key)\(shift == nil ? "" : (isPast ? "，已过去的值班" : "，值班"))\(isSelected ? "，已选中" : "")")
        .disabled(saving || (loading && !selecting) || (selecting && shift != nil))
    }

    private func load() async {
        let requested = month
        loading = true
        defer { if requested == month { loading = false } }
        do {
            let interval = currentMonth
            let lastDay = interval.end.addingTimeInterval(-1)
            let result = try await api.shifts(start: BeijingDates.key(interval.start), end: BeijingDates.key(lastDay))
            guard !Task.isCancelled, requested == month else { return }
            shifts = result
            error = nil
        } catch { if !Task.isCancelled, requested == month { self.error = session.handleError(error) } }
    }

    private func saveSelection() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await api.addShifts(selected.sorted())
            selecting = false
            selected.removeAll()
            session.changed()
        } catch { self.error = session.handleError(error) }
    }

    private enum CalendarSheet: Identifiable {
        case schedule, single(String)
        var id: String {
            switch self {
            case .schedule: return "schedule"
            case .single(let date): return date
            }
        }
    }
}

@MainActor
private struct DutyScheduleEditor: View {
    let api: WorkbenchAPI
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var anchor = BeijingDates.parse("2026-11-02") ?? .now
    @State private var start: Date
    @State private var end: Date
    @State private var replace = false
    @State private var preview: DutyPreview?
    @State private var previewedRule: DutyRule?
    @State private var error: String?
    @State private var busy = false

    init(api: WorkbenchAPI, month: Date, onSave: @escaping () -> Void) {
        self.api = api
        self.onSave = onSave
        let interval = BeijingDates.monthInterval(month)
        _start = State(initialValue: interval.start)
        _end = State(initialValue: interval.end.addingTimeInterval(-1))
    }

    private var rule: DutyRule {
        DutyRule(anchor: BeijingDates.key(anchor), start: BeijingDates.key(start), end: BeijingDates.key(end), replace: replace)
    }

    var body: some View {
        Form {
            Section("每隔 9 天 · 北京时间") {
                DatePicker("轮值起始日", selection: $anchor, displayedComponents: .date)
                DatePicker("生成范围起始日", selection: $start, displayedComponents: .date)
                DatePicker("生成范围结束日", selection: $end, displayedComponents: .date)
                Toggle("重排范围内的周期班次", isOn: $replace)
                Button("预览日期") { Task { await fetchPreview() } }
                    .disabled(busy || end < start || anchor > end)
            }
            if let preview, previewedRule == rule {
                Section("将生成或保留的轮值日期") {
                    if preview.dates.isEmpty { Text("此范围没有周期班次").foregroundStyle(.secondary) }
                    ForEach(preview.dates, id: \.self) { Text($0) }
                }
                if !preview.remove.isEmpty {
                    Section("将移除的周期班次") {
                        ForEach(preview.remove, id: \.self) { Text($0) }
                    }
                }
            }
            if let error { InlineError(message: error) }
            if busy { ProgressView() }
        }
        .navigationTitle("排班设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存排班") { Task { await commit() } }
                    .disabled(busy || previewedRule != rule)
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private func fetchPreview() async {
        busy = true
        defer { busy = false }
        let requested = rule
        do {
            preview = try await api.preview(requested)
            previewedRule = requested
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func commit() async {
        guard !busy, previewedRule == rule else { return }
        busy = true
        defer { busy = false }
        do {
            try await api.save(rule)
            onSave()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
