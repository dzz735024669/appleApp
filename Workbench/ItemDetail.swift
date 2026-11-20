import SwiftUI

@MainActor
struct ItemDetail: View {
    let api: WorkbenchAPI
    let id: UUID
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var current: Item?
    @State private var related: [Item] = []
    @State private var relatedHasMore = false
    @State private var error: String?
    @State private var working = false
    @State private var editor: EditorRoute?
    @State private var confirmDelete = false

    private var isTask: Bool { current?.fields.kind == .task }

    var body: some View {
        List {
            if let error { InlineError(message: error) }
            if let current {
                if isTask { taskContent(current) }
                else { content(current) }
            }
            else if error == nil { ProgressView() }
        }
        .listStyle(.plain)
        .scrollContentBackground(isTask ? .hidden : .visible)
        .background(isTask ? WorkbenchTheme.canvas : Color(uiColor: .systemBackground))
        .navigationTitle(isTask ? "待办详情" : current?.fields.kind.label ?? "详情")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let current, isTask { taskActionBar(current) }
        }
        .toolbar {
            if let current {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("编辑", systemImage: "pencil") { editor = .init(fields: current.fields, existing: current) }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("删除", systemImage: "trash") }
                    } label: { Label("更多", systemImage: "ellipsis.circle") }
                    .disabled(working)
                }
            }
        }
        .task(id: session.refreshVersion) { await load() }
        .refreshable { await load() }
        .sheet(item: $editor) { route in
            NavigationStack {
                ItemEditor(api: api, draft: route.fields, existing: route.existing) { saved in
                    if saved.id == id { current = saved }
                    session.changed()
                }
            }
        }
        .confirmationDialog("删除这条内容？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("确认删除", role: .destructive) { Task { await delete() } }
        } message: {
            Text("关联附件也会被删除。")
        }
    }

    @ViewBuilder private func taskContent(_ item: Item) -> some View {
        let fields = item.fields
        VStack(alignment: .leading, spacing: 10) {
            Text(fields.title)
                .font(.largeTitle.bold())
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let overdue = fields.status != .completed && (fields.dueAt.map { $0 < context.date } ?? false)
                let urgent = fields.status != .completed && fields.priority == .urgent
                let status = [urgent ? "紧急" : nil, overdue ? "已逾期" : nil, fields.status?.label]
                    .compactMap { $0 }.joined(separator: " · ")
                Text(status)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(urgent || overdue ? Color.red : Color.secondary)
            }
            if let description = fields.description, !description.isEmpty {
                Text(description).textSelection(.enabled)
            }
        }
        .padding(.vertical, 16)
        .listRowBackground(Color.clear)

        Button {
            editor = .init(fields: fields, existing: item)
        } label: {
            taskDetailRow("截止时间", icon: "calendar",
                          value: fields.dueAt.map { BeijingDates.format($0) } ?? "未设置",
                          actionable: true)
        }
        .buttonStyle(.plain)
        .disabled(working)
        .listRowBackground(Color.clear)

        let reminder = fields.status == .waiting ? fields.followUpAt : fields.remindAt
        let reminderTitle = fields.status == .waiting ? "跟进提醒" : "提醒"
        Group {
            if fields.status == .completed {
                taskDetailRow(reminderTitle, icon: "bell",
                              value: reminder.map { BeijingDates.format($0) } ?? "未设置")
            } else {
                Menu {
                    snoozeActions(item)
                    Button("编辑提醒", systemImage: "pencil") {
                        editor = .init(fields: fields, existing: item)
                    }
                } label: {
                    taskDetailRow(reminderTitle, icon: "bell",
                                  value: reminder.map { BeijingDates.format($0) } ?? "稍后提醒",
                                  actionable: true)
                }
                .disabled(working)
                .accessibilityHint("选择稍后提醒或编辑时间")
            }
        }
        .listRowBackground(Color.clear)

        DisclosureGroup("更多信息") {
            if let category = fields.category { LabeledContent("分类", value: category.label) }
            if let priority = fields.priority { LabeledContent("优先级", value: priority.label) }
            if let impact = fields.impact { LabeledContent("影响程度", value: impact.label) }
            if fields.status == .waiting {
                if let note = fields.waitingFor, !note.isEmpty { LabeledContent("等待", value: note) }
                if let remind = fields.remindAt { LabeledContent("待办提醒", value: BeijingDates.format(remind)) }
            }
            relatedRows(item)
            Button("添加关联文档", systemImage: "doc.badge.plus") { openLinkedDocument(from: item) }
                .disabled(working)
        }
        .listRowBackground(Color.clear)
        AttachmentSection(api: api, itemID: id)
    }

    private func taskDetailRow(_ title: String, icon: String, value: String, actionable: Bool = false) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: icon).foregroundStyle(.primary)
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(.secondary)
            if actionable {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func taskActionBar(_ item: Item) -> some View {
        let isCompleted = item.fields.status == .completed
        return Button {
            Task { await changeTask(item, completed: !isCompleted) }
        } label: {
            Text(isCompleted ? "重新打开" : "标记完成")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(WorkbenchTheme.action)
        .disabled(working)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    @ViewBuilder private func snoozeActions(_ item: Item) -> some View {
        Button("15 分钟后") { Task { await changeTask(item, snoozeUntil: Date().addingTimeInterval(900)) } }
        Button("1 小时后") { Task { await changeTask(item, snoozeUntil: Date().addingTimeInterval(3600)) } }
        Button("3 小时后") { Task { await changeTask(item, snoozeUntil: Date().addingTimeInterval(3 * 3600)) } }
        Button("明天上午 9:00") { Task { await changeTask(item, snoozeUntil: BeijingDates.nextMorning()) } }
    }

    @ViewBuilder private func content(_ item: Item) -> some View {
        let fields = item.fields
        Section {
            Text(fields.title).font(.title2.bold()).textSelection(.enabled)
            if let category = fields.category { LabeledContent("分类", value: category.label) }
            if let status = fields.status { LabeledContent("状态", value: status.label) }
            if let priority = fields.priority { LabeledContent("优先级", value: priority.label) }
            if let impact = fields.impact { LabeledContent("影响程度", value: impact.label) }
            if let type = fields.noteType { LabeledContent("类型", value: type.label) }
            if let body = fields.body, !body.isEmpty { Text(body).textSelection(.enabled) }
            if let info = fields.description, !info.isEmpty { Text(info).textSelection(.enabled) }
        }
        if fields.dueAt != nil || fields.remindAt != nil || fields.targetAt != nil || fields.date != nil || fields.status == .waiting {
            Section("时间 · 北京时间") {
                if let day = fields.date { LabeledContent("日期", value: "\(day) · 全天") }
                if let due = fields.dueAt { LabeledContent("截止", value: BeijingDates.format(due)) }
                if let target = fields.targetAt {
                    LabeledContent("目标", value: BeijingDates.format(target))
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(BeijingDates.remaining(until: target, from: context.date)).foregroundStyle(.tint)
                    }
                }
                if let remind = fields.remindAt { LabeledContent("提醒", value: BeijingDates.format(remind)) }
                if fields.status == .waiting {
                    if let note = fields.waitingFor, !note.isEmpty { LabeledContent("等待", value: note) }
                    if let follow = fields.followUpAt { LabeledContent("跟进提醒", value: BeijingDates.format(follow)) }
                }
            }
        }
        if fields.kind == .paper || fields.kind == .award {
            Section("归档信息") {
                if let date = fields.publishedOn { LabeledContent("发表日期", value: date) }
                if let date = fields.awardedOn { LabeledContent("获奖日期", value: date) }
                if let value = fields.authors, !value.isEmpty { LabeledContent("作者", value: value) }
                if let value = fields.venue, !value.isEmpty { LabeledContent("期刊或会议", value: value) }
                if let value = fields.issuer, !value.isEmpty { LabeledContent("颁发单位", value: value) }
                if let value = fields.level, !value.isEmpty { LabeledContent("级别", value: value) }
                if let value = fields.publicationURL, let url = URL(string: value),
                   url.scheme == "https" || url.scheme == "http" {
                    Link("打开发表链接", destination: url)
                }
            }
        }
        if fields.kind == .note || fields.kind == .duty || fields.kind == .project || fields.kind == .paper || fields.kind == .award {
            Section {
                actions(for: item)
            }
            .disabled(working)
        }
        if fields.projectID != nil || fields.sourceID != nil || fields.kind == .project || fields.kind == .note || fields.kind == .duty || !related.isEmpty {
            Section("关联内容") {
                relatedRows(item)
                if fields.projectID == nil && fields.sourceID == nil && related.isEmpty {
                    Text("暂无关联内容").foregroundStyle(.secondary)
                }
            }
        }
        AttachmentSection(api: api, itemID: id)
    }

    @ViewBuilder private func relatedRows(_ item: Item) -> some View {
        if let project = item.fields.projectID {
            NavigationLink("查看关联项目") { ItemDetail(api: api, id: project) }
        }
        if let source = item.fields.sourceID {
            NavigationLink("查看来源") { ItemDetail(api: api, id: source) }
        }
        ForEach(related) { child in
            NavigationLink { ItemDetail(api: api, id: child.id) } label: { ItemRow(item: child) }
        }
        if relatedHasMore {
            Button("加载更多") { Task { await loadRelated(for: item, append: true) } }.disabled(working)
        }
    }

    @ViewBuilder private func actions(for item: Item) -> some View {
        if item.fields.kind == .project {
            Menu("添加关联内容", systemImage: "plus.circle") {
                ForEach([ItemKind.task, .note, .event, .document, .paper, .award], id: \.self) { kind in
                    Button("新建\(kind.label)", systemImage: kind.icon) {
                        var draft = ItemFields.new(kind, category: item.fields.category)
                        draft.projectID = item.id
                        editor = .init(fields: draft)
                    }
                }
            }
        } else if item.fields.kind == .paper || item.fields.kind == .award {
            Button("添加关联文档", systemImage: "doc.badge.plus") { openLinkedDocument(from: item) }
        } else {
            Button(item.fields.kind == .note ? "转为待办" : "添加后续待办", systemImage: "plus.circle") {
                var draft = ItemFields.new(.task, category: item.fields.category)
                draft.title = item.fields.kind == .note ? item.fields.title : "补写值班记录"
                draft.projectID = item.fields.projectID
                draft.sourceID = item.id
                draft.impact = item.fields.impact
                editor = .init(fields: draft)
            }
        }
    }

    private func openLinkedDocument(from item: Item) {
        var draft = ItemFields.new(.document, category: item.fields.category)
        draft.projectID = item.fields.projectID
        draft.sourceID = item.id
        editor = .init(fields: draft)
    }

    private func load() async {
        do {
            let item = try await api.item(id)
            guard !Task.isCancelled else { return }
            current = item
            error = nil
            await loadRelated(for: item)
        } catch { if !Task.isCancelled { self.error = session.handleError(error) } }
    }

    private func loadRelated(for item: Item, append: Bool = false) async {
        let type = item.fields.kind
        guard type != .document else { return }
        if append { working = true }
        defer { if append { working = false } }
        do {
            let page = try await api.items(projectID: type == .project ? item.id : nil,
                                           sourceID: type != .project ? item.id : nil, offset: append ? related.count : 0)
            guard !Task.isCancelled else { return }
            if append {
                let known = Set(related.map(\.id))
                related += page.items.filter { !known.contains($0.id) }
            } else { related = page.items }
            relatedHasMore = page.hasMore
        } catch { if !Task.isCancelled { self.error = session.handleError(error) } }
    }

    private func changeTask(_ item: Item, completed: Bool? = nil, snoozeUntil: Date? = nil) async {
        guard !working else { return }
        working = true
        defer { working = false }
        var fields = item.fields
        if let snoozeUntil {
            if fields.status == .waiting { fields.followUpAt = snoozeUntil }
            else { fields.remindAt = snoozeUntil }
        } else if completed == true { fields.status = .completed }
        else { fields.status = .pending }
        do {
            current = try await api.update(item, with: fields)
            error = nil
            session.changed()
        } catch { self.error = session.handleError(error) }
    }

    private func delete() async {
        guard let current, !working else { return }
        working = true
        defer { working = false }
        do {
            try await api.delete(current)
            session.changed()
            dismiss()
        } catch { self.error = session.handleError(error) }
    }

    private struct EditorRoute: Identifiable {
        let id = UUID()
        let fields: ItemFields
        var existing: Item? = nil
    }
}
