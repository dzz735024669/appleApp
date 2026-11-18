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

    var body: some View {
        List {
            if let error { InlineError(message: error) }
            if let current { content(current) }
            else if error == nil { ProgressView() }
        }
        .navigationTitle(current?.fields.kind.label ?? "详情")
        .navigationBarTitleDisplayMode(.inline)
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
        if fields.kind == .task || fields.kind == .note || fields.kind == .duty {
            Section {
                actions(for: item)
            }
            .disabled(working)
        }
        if fields.projectID != nil || fields.sourceID != nil || fields.kind == .project || fields.kind == .note || fields.kind == .duty {
            Section("关联内容") {
                if let project = fields.projectID {
                    NavigationLink("查看关联项目") { ItemDetail(api: api, id: project) }
                }
                if let source = fields.sourceID {
                    NavigationLink("查看来源") { ItemDetail(api: api, id: source) }
                }
                ForEach(related) { child in
                    NavigationLink { ItemDetail(api: api, id: child.id) } label: { ItemRow(item: child) }
                }
                if relatedHasMore {
                    Button("加载更多") { Task { await loadRelated(for: item, append: true) } }.disabled(working)
                }
                if fields.projectID == nil && fields.sourceID == nil && related.isEmpty {
                    Text("暂无关联内容").foregroundStyle(.secondary)
                }
            }
        }
        AttachmentSection(api: api, itemID: id)
    }

    @ViewBuilder private func actions(for item: Item) -> some View {
        if item.fields.kind == .task {
            if item.fields.status != .completed {
                Button("标记完成", systemImage: "checkmark.circle") { Task { await changeTask(item, completed: true) } }
                Menu("稍后提醒", systemImage: "bell.badge") {
                    Button("15 分钟后") { Task { await changeTask(item, snooze: 900) } }
                    Button("1 小时后") { Task { await changeTask(item, snooze: 3600) } }
                }
            } else {
                Button("重新打开", systemImage: "arrow.uturn.backward") { Task { await changeTask(item) } }
            }
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

    private func load() async {
        do {
            let item = try await api.item(id)
            guard !Task.isCancelled else { return }
            current = item
            error = nil
            await loadRelated(for: item)
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func loadRelated(for item: Item, append: Bool = false) async {
        let type = item.fields.kind
        guard type == .project || type == .note || type == .duty else { return }
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
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func changeTask(_ item: Item, completed: Bool? = nil, snooze: TimeInterval? = nil) async {
        guard !working else { return }
        working = true
        defer { working = false }
        var fields = item.fields
        if let snooze {
            let date = Date().addingTimeInterval(snooze)
            if fields.status == .waiting { fields.followUpAt = date }
            else { fields.remindAt = date }
        } else if completed == true { fields.status = .completed }
        else { fields.status = .pending }
        do {
            current = try await api.update(item, with: fields)
            error = nil
            session.changed()
        } catch { self.error = error.localizedDescription }
    }

    private func delete() async {
        guard let current, !working else { return }
        working = true
        defer { working = false }
        do {
            try await api.delete(current)
            session.changed()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private struct EditorRoute: Identifiable {
        let id = UUID()
        let fields: ItemFields
        var existing: Item? = nil
    }
}
