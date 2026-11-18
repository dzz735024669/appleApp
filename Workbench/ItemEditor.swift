import SwiftUI

@MainActor
struct ItemEditor: View {
    let api: WorkbenchAPI
    let existing: Item?
    let onSave: (Item) -> Void
    let onDraftSave: ((ItemFields) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var fields: ItemFields
    @State private var projects: [Item] = []
    @State private var saving = false
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var customDutyReminder: Bool

    init(api: WorkbenchAPI, draft: ItemFields, existing: Item? = nil,
         onDraftSave: ((ItemFields) -> Void)? = nil, onSave: @escaping (Item) -> Void) {
        self.api = api
        self.existing = existing
        self.onSave = onSave
        self.onDraftSave = onDraftSave
        _fields = State(initialValue: draft)
        let defaultTime = draft.date.flatMap(BeijingDates.parse).map(BeijingDates.previousEvening)
        _customDutyReminder = State(initialValue: draft.kind == .duty && draft.remindAt != nil && draft.remindAt != defaultTime)
    }

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $fields.title, axis: .vertical)
                    .lineLimit(1...3)
                if fields.kind != .duty { choice("分类", $fields.category, empty: "未分类") }
                if fields.kind != .project && fields.kind != .duty { projectPicker }
            }
            kindFields
            if fields.kind != .note {
                Section("说明") {
                    TextField("可选", text: string($fields.description), axis: .vertical)
                        .lineLimit(2...6)
                }
            }
            if let error { Section { InlineError(message: error) } }
        }
        .navigationTitle(existing == nil ? "新建\(fields.kind.label)" : "编辑\(fields.kind.label)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "保存中…" : (onDraftSave == nil ? "保存" : "确认修改")) { Task { await save() } }
                    .disabled(saving || fields.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .interactiveDismissDisabled(saving)
        .task {
            guard fields.kind != .duty && fields.kind != .project else { return }
            var offset = 0
            do {
                repeat {
                    let page = try await api.items(kind: .project, offset: offset)
                    projects.append(contentsOf: page.items)
                    offset += page.items.count
                    if !page.hasMore { break }
                } while !Task.isCancelled
            } catch {
                if !Task.isCancelled { self.error = "项目列表加载失败：\(error.localizedDescription)" }
            }
        }
    }

    private var projectPicker: some View {
        Picker("关联项目", selection: $fields.projectID) {
            Text("无").tag(Optional<UUID>.none)
            if let id = fields.projectID, !projects.contains(where: { $0.id == id }) {
                Text("已关联的项目").tag(Optional(id))
            }
            ForEach(projects) { Text($0.fields.title).tag(Optional($0.id)) }
        }
    }

    @ViewBuilder private var kindFields: some View {
        switch fields.kind {
        case .note:
            Section("记录") {
                requiredChoice("类型", $fields.noteType, fallback: .note)
                choice("影响程度", $fields.impact)
                TextField("正文或补充说明", text: string($fields.body), axis: .vertical).lineLimit(3...10)
            }
        case .task:
            Section("处理") {
                requiredChoice("状态", $fields.status, fallback: .pending, choices: ItemStatus.taskStatuses)
                requiredChoice("优先级", $fields.priority, fallback: .normal)
                choice("影响程度", $fields.impact)
            }
            Section("时间 · 北京时间") {
                optionalDate("截止时间", $fields.dueAt)
                optionalDate("iPhone 提醒", $fields.remindAt)
                if fields.status == .waiting {
                    TextField("在等什么", text: string($fields.waitingFor))
                    optionalDate("跟进提醒", $fields.followUpAt)
                }
            }
        case .event:
            Section("时间 · 北京时间") {
                if fields.targetAt == nil {
                    Button("设置目标时间") { fields.targetAt = .now.addingTimeInterval(3600) }
                } else {
                    DatePicker("目标时间", selection: requiredDate($fields.targetAt))
                }
                optionalDate("提前提醒", $fields.remindAt)
                choice("影响程度", $fields.impact)
            }
        case .duty:
            Section("值班安排 · 北京时间") {
                DatePicker("全天日期", selection: day($fields.date), displayedComponents: .date)
                Toggle("发送提醒", isOn: Binding(get: { fields.reminderEnabled ?? true }, set: { fields.reminderEnabled = $0 }))
                if fields.reminderEnabled ?? true {
                    Toggle("自定提醒时间", isOn: $customDutyReminder)
                    if customDutyReminder {
                        DatePicker("提醒时间", selection: requiredDate($fields.remindAt, default: dutyDefault))
                    } else {
                        LabeledContent("默认提醒", value: BeijingDates.format(dutyDefault))
                    }
                }
            }
        case .project:
            Section("项目") {
                requiredChoice("项目状态", $fields.status, fallback: .notStarted, choices: ItemStatus.projectStatuses)
            }
        case .paper:
            Section("发表信息") {
                TextField("作者", text: string($fields.authors))
                TextField("期刊或会议", text: string($fields.venue))
                DatePicker("发表日期", selection: day($fields.publishedOn), displayedComponents: .date)
                TextField("发表链接", text: string($fields.publicationURL))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        case .award:
            Section("获奖信息") {
                TextField("颁发单位", text: string($fields.issuer))
                TextField("级别", text: string($fields.level))
                DatePicker("获奖日期", selection: day($fields.awardedOn), displayedComponents: .date)
            }
        case .document:
            Section { Text("保存后可在详情页上传原件。").foregroundStyle(.secondary) }
        }
    }

    private var dutyDefault: Date {
        BeijingDates.previousEvening(fields.date.flatMap(BeijingDates.parse) ?? .now)
    }

    private func string(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0 })
    }

    private func day(_ value: Binding<String?>) -> Binding<Date> {
        Binding(get: { value.wrappedValue.flatMap(BeijingDates.parse) ?? .now },
                set: { value.wrappedValue = BeijingDates.key($0) })
    }

    private func requiredDate(_ value: Binding<Date?>, default fallback: Date = .now) -> Binding<Date> {
        Binding(get: { value.wrappedValue ?? fallback }, set: { value.wrappedValue = $0 })
    }

    @ViewBuilder private func optionalDate(_ title: String, _ value: Binding<Date?>) -> some View {
        Toggle(title, isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? Date().addingTimeInterval(3600) : nil }))
        if value.wrappedValue != nil { DatePicker(title, selection: requiredDate(value)) }
    }

    private func choice<T: NamedChoice>(_ title: String, _ selected: Binding<T?>,
                                         empty: String = "未设置", choices: [T] = Array(T.allCases)) -> some View {
        Picker(title, selection: selected) {
            Text(empty).tag(Optional<T>.none)
            ForEach(choices, id: \.self) { Text($0.label).tag(Optional($0)) }
        }
    }

    private func requiredChoice<T: NamedChoice>(_ title: String, _ selected: Binding<T?>, fallback: T,
                                                 choices: [T] = Array(T.allCases)) -> some View {
        Picker(title, selection: Binding(get: { selected.wrappedValue ?? fallback }, set: { selected.wrappedValue = $0 })) {
            ForEach(choices, id: \.self) { Text($0.label).tag($0) }
        }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        var payload = fields
        payload.title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.kind == .task {
            payload.status = payload.status ?? .pending
            payload.priority = payload.priority ?? .normal
        }
        if payload.kind == .project { payload.status = payload.status ?? .notStarted }
        if payload.kind == .note { payload.noteType = payload.noteType ?? .note }
        if payload.kind == .duty {
            payload.remindAt = customDutyReminder && payload.reminderEnabled != false ? (payload.remindAt ?? dutyDefault) : nil
        }
        if let url = payload.publicationURL {
            let cleaned = url.trimmingCharacters(in: .whitespacesAndNewlines)
            payload.publicationURL = cleaned.isEmpty ? nil : cleaned
        }
        if payload.kind == .event, let reminder = payload.remindAt, let target = payload.targetAt, reminder >= target {
            error = "提前提醒需早于目标时间。"
            return
        }
        if payload.kind == .event && payload.targetAt == nil {
            error = "请设置倒计时的目标时间。"
            return
        }
        if let onDraftSave {
            onDraftSave(payload)
            dismiss()
            return
        }
        do {
            let saved: Item
            if let existing { saved = try await api.update(existing, with: payload) }
            else { saved = try await api.create(payload, key: requestID) }
            onSave(saved)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
