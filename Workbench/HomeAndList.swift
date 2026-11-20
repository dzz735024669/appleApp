import SwiftUI

@MainActor
struct HomeView: View {
    let api: WorkbenchAPI
    let showTasks: () -> Void
    @EnvironmentObject private var session: SessionStore
    @State private var category: Category?
    @State private var data: HomeData?
    @State private var error: String?
    @State private var newItemPresented = false
    @State private var creation: Creation?
    @State private var completing: Set<UUID> = []
    @State private var completed: Set<UUID> = []
    @StateObject private var clipboard = ClipboardImportModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Picker("首页分类", selection: $category) {
                    Text("全部").tag(Optional<Category>.none)
                    ForEach(Category.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                if let error { InlineError(message: error) }
                if let data {
                    if let duty = data.nextDuty { dutyBanner(duty) }
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        taskList(data, now: context.date)
                    }
                    if !data.countdowns.isEmpty { countdowns(data.countdowns) }
                } else if error == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(WorkbenchTheme.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { newItemPresented = true } label: {
                Label("新建", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(WorkbenchTheme.action)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .background(.regularMaterial)
        }
        .task(id: "\(category?.rawValue ?? "all"):\(session.refreshVersion)") { await load() }
        .onChange(of: category) { _, _ in data = nil }
        .refreshable { await load() }
        .sheet(isPresented: $newItemPresented, onDismiss: { creation = nil }) {
            NavigationStack {
                if let creation {
                    if let kind = creation.kind {
                        ItemEditor(api: api, draft: .new(kind, category: category)) { _ in session.changed() }
                    } else {
                        ClipboardImportView(api: api, model: clipboard)
                    }
                } else {
                    creationMenu
                }
            }
            .presentationDetents(creation == nil ? [.medium, .large] : [.large])
            .presentationDragIndicator(creation == nil ? .visible : .hidden)
        }
    }

    private var creationMenu: some View {
        List {
            ForEach(Creation.allCases) { choice in
                Button { creation = choice } label: {
                    Label(choice.title, systemImage: choice.icon)
                        .foregroundStyle(.primary)
                        .frame(minHeight: 44)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("新建")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { newItemPresented = false } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("关闭")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(BeijingDates.format(context.date, pattern: "M月d日 · EEEE"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Text("今天").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            }
            Spacer()
            NavigationLink {
                SettingsView().toolbar(.visible, for: .navigationBar)
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("设置")
        }
    }

    private func dutyBanner(_ duty: Item) -> some View {
        let today = duty.daysRemaining == 0
        return NavigationLink {
            destination(duty)
        } label: {
            HStack {
                Label(today ? "今日值班" : "下次值班", systemImage: "calendar")
                    .font(.headline)
                Spacer()
                Text(today ? "全天" : [duty.fields.date, duty.daysRemaining.map { "还有 \($0) 天" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(minHeight: 48)
            .background(WorkbenchTheme.blue.opacity(today ? 0.13 : 0.06), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func taskList(_ data: HomeData, now: Date) -> some View {
        let followUps = data.waiting.filter {
            $0.fields.followUpAt.map { $0 <= now || BeijingDates.calendar.isDate($0, inSameDayAs: now) } ?? false
        }
        var seen = Set<UUID>()
        let tasks = (data.urgent + data.overdue + data.dueToday + followUps).filter {
            !completed.contains($0.id) && seen.insert($0.id).inserted
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("需要处理").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                if tasks.count > 5 { Button("查看全部", action: showTasks).font(.subheadline) }
            }
            .padding(.bottom, 8)
            if tasks.isEmpty {
                Text("今天暂无需要处理的待办").foregroundStyle(.secondary).padding(.vertical, 12)
            }
            ForEach(tasks.prefix(5)) { item in
                HStack(spacing: 4) {
                    Button { Task { await completeTask(item) } } label: {
                        if completing.contains(item.id) {
                            ProgressView().frame(width: 44, height: 44)
                        } else {
                            Image(systemName: "circle").font(.title3)
                                .foregroundStyle(.secondary).frame(width: 44, height: 44)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(completing.contains(item.id))
                    .accessibilityLabel("完成\(item.fields.title)")
                    NavigationLink { destination(item) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.fields.title).font(.headline)
                                let summary = taskSummary(item, now: now)
                                Text(summary.text).font(.footnote)
                                    .foregroundStyle(summary.alert ? Color.red : Color.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 7)
                Divider()
            }
        }
    }

    private func taskSummary(_ item: Item, now: Date) -> (text: String, alert: Bool) {
        let fields = item.fields
        let urgent = fields.priority == .urgent
        let overdue = fields.dueAt.map { $0 < now } ?? false
        var labels: [String] = []
        if urgent { labels.append("紧急") }
        if overdue { labels.append("已逾期") }
        else if let due = fields.dueAt, BeijingDates.calendar.isDate(due, inSameDayAs: now) {
            labels.append("今天 \(BeijingDates.format(due, pattern: "HH:mm")) 截止")
        }
        if fields.status == .waiting {
            if let follow = fields.followUpAt, follow <= now {
                labels.append("待跟进")
            } else if let follow = fields.followUpAt, BeijingDates.calendar.isDate(follow, inSameDayAs: now) {
                labels.append("\(BeijingDates.format(follow, pattern: "HH:mm")) 跟进")
            }
            labels.append("等待中")
        }
        return (labels.joined(separator: " · "), urgent || overdue)
    }

    @ViewBuilder private func countdowns(_ items: [Item]) -> some View {
        if let nearest = items.first {
            VStack(alignment: .leading, spacing: 8) {
                countdownLink(nearest)
                if items.count > 1 {
                    DisclosureGroup("更多倒计时") {
                        ForEach(items.dropFirst()) { countdownLink($0) }
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private func countdownLink(_ item: Item) -> some View {
        NavigationLink { destination(item) } label: {
            HStack {
                Label(item.fields.title, systemImage: "timer")
                Spacer()
                if let target = item.fields.targetAt {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(BeijingDates.remaining(until: target, from: context.date))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func destination(_ item: Item) -> some View {
        ItemDetail(api: api, id: item.id).toolbar(.visible, for: .navigationBar)
    }

    private func completeTask(_ item: Item) async {
        guard completing.insert(item.id).inserted else { return }
        defer { completing.remove(item.id) }
        var fields = item.fields
        fields.status = .completed
        do {
            _ = try await api.update(item, with: fields)
            completed.insert(item.id)
            session.changed()
        } catch {
            self.error = session.handleError(error)
        }
    }

    private func load() async {
        do {
            let result = try await api.home(category: category)
            guard !Task.isCancelled else { return }
            data = result
            completed.removeAll()
            error = nil
        } catch { if !Task.isCancelled { self.error = session.handleError(error) } }
    }

    private enum Creation: String, CaseIterable, Identifiable {
        case note, task, clipboard, event

        var id: Self { self }

        var kind: ItemKind? {
            switch self {
            case .note: return .note
            case .task: return .task
            case .clipboard: return nil
            case .event: return .event
            }
        }

        var title: String {
            switch self {
            case .note: return "随手记"
            case .task: return "待办"
            case .clipboard: return "识别剪贴板"
            case .event: return "倒计时"
            }
        }

        var icon: String { kind?.icon ?? "doc.on.clipboard" }
    }
}

@MainActor
struct ItemListView: View {
    enum Mode { case tasks, library }
    let api: WorkbenchAPI
    let mode: Mode
    @EnvironmentObject private var session: SessionStore
    @State private var items: [Item] = []
    @State private var hasMore = false
    @State private var loading = true
    @State private var paging = false
    @State private var error: String?
    @State private var query = ""
    @State private var year = ""
    @State private var category: Category?
    @State private var status: ItemStatus?
    @State private var kind: ItemKind? = nil
    @State private var creation: ItemKind?
    @State private var createdDocument: ItemRoute?

    private let libraryKinds: [ItemKind] = [.note, .project, .document, .paper, .award]
    private var filterByYear: Bool { mode == .library && (kind == .paper || kind == .award) }
    private var cleanedYear: String? {
        let digits = year.filter { $0.isASCII && $0.isNumber }
        return filterByYear && digits.count == 4 ? digits : nil
    }
    private var loadID: String {
        "\(kind?.rawValue ?? "all")|\(category?.rawValue ?? "")|\(status?.rawValue ?? "")|\(query)|\(cleanedYear ?? "")|\(session.refreshVersion)"
    }

    var body: some View {
        List {
            Section {
                if mode == .tasks {
                    Picker("分类", selection: $category) {
                        Text("全部").tag(Optional<Category>.none)
                        ForEach(Category.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }
                    .pickerStyle(.segmented)
                    Picker("状态", selection: $status) {
                        Text("全部状态").tag(Optional<ItemStatus>.none)
                        ForEach(ItemStatus.taskStatuses, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }
                } else {
                    Picker("资料类型", selection: $kind) {
                        Text("全部类型").tag(Optional<ItemKind>.none)
                        ForEach(libraryKinds, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }
                    if filterByYear {
                        HStack {
                            TextField("年份（例如 2026）", text: $year)
                                .keyboardType(.numberPad)
                            if !year.isEmpty {
                                Button { year = "" } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("清除年份")
                            }
                        }
                    }
                }
            }
            if let error { InlineError(message: error) }
            if loading && items.isEmpty { ProgressView() }
            if !loading && items.isEmpty && error == nil {
                ContentUnavailableView(mode == .tasks ? "暂无待办" : "暂无资料", systemImage: "tray")
            }
            ForEach(items) { item in
                NavigationLink { ItemDetail(api: api, id: item.id) } label: { ItemRow(item: item) }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if item.fields.kind == .task {
                            let done = item.fields.status == .completed
                            Button { Task { await toggleTask(item) } } label: {
                                Label(done ? "重开" : "完成",
                                      systemImage: done ? "arrow.uturn.backward" : "checkmark.circle")
                            }
                            .tint(done ? .orange : .green)
                        }
                    }
            }
            if hasMore {
                Button(paging ? "正在加载…" : "加载更多") { Task { await load(more: true) } }
                    .disabled(paging || loading)
            }
        }
        .navigationTitle(mode == .tasks ? "待办" : "资料")
        .searchable(text: $query, prompt: mode == .tasks ? "搜索待办" : "搜索标题、文件名或正文")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if mode == .tasks {
                    Button { creation = .task } label: { Label("新建", systemImage: "plus") }
                } else if let selectedKind = kind {
                    Button { creation = selectedKind } label: { Label("新建", systemImage: "plus") }
                } else {
                    Menu {
                        ForEach(libraryKinds, id: \.self) { choice in
                            Button(choice.label, systemImage: choice.icon) { creation = choice }
                        }
                    } label: { Label("新建", systemImage: "plus") }
                }
            }
        }
        .onChange(of: kind) { _, newKind in
            if newKind != .paper && newKind != .award { year = "" }
        }
        .task(id: loadID) { await load() }
        .refreshable { await load() }
        .sheet(isPresented: Binding(get: { creation != nil }, set: { if !$0 { creation = nil } })) {
            if let creation {
                NavigationStack {
                    ItemEditor(api: api, draft: .new(creation, category: mode == .tasks ? category : nil)) { saved in
                        session.changed()
                        if saved.fields.kind == .document {
                            createdDocument = ItemRoute(id: saved.id)
                        }
                    }
                }
            }
        }
        .navigationDestination(item: $createdDocument) { route in
            ItemDetail(api: api, id: route.id)
        }
    }

    private func toggleTask(_ item: Item) async {
        var fields = item.fields
        fields.status = fields.status == .completed ? .pending : .completed
        do {
            _ = try await api.update(item, with: fields)
            session.changed()
        } catch {
            self.error = session.handleError(error)
        }
    }

    private func load(more: Bool = false) async {
        let current = loadID
        if more {
            guard !paging && hasMore else { return }
            paging = true
        } else {
            loading = true
            hasMore = false
            error = nil
        }
        defer {
            if more { paging = false }
            else if current == loadID { loading = false }
        }
        do {
            if !more && !query.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
            let result = try await api.items(kind: mode == .tasks ? .task : kind,
                                             category: mode == .tasks ? category : nil,
                                             status: mode == .tasks ? status : nil,
                                             keyword: query,
                                             year: cleanedYear,
                                             offset: more ? items.count : 0)
            guard !Task.isCancelled, current == loadID else { return }
            if more {
                let known = Set(items.map(\.id))
                items += result.items.filter { !known.contains($0.id) }
            } else { items = result.items }
            hasMore = result.hasMore
            error = nil
        } catch {
            if !Task.isCancelled, current == loadID { self.error = session.handleError(error) }
        }
    }
}
