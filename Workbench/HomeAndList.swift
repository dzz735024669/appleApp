import SwiftUI

@MainActor
struct HomeView: View {
    let api: WorkbenchAPI
    @EnvironmentObject private var session: SessionStore
    @State private var category: Category?
    @State private var data: HomeData?
    @State private var error: String?
    @State private var creation: ItemKind?
    @State private var clipboardPresented = false
    @StateObject private var clipboard = ClipboardImportModel()

    var body: some View {
        List {
            Section {
                Picker("首页分类", selection: $category) {
                    Text("全部").tag(Optional<Category>.none)
                    ForEach(Category.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                Button { creation = .note } label: { Label("快速记录", systemImage: "square.and.pencil") }
                Button { clipboardPresented = true } label: { Label("从剪贴板识别", systemImage: "doc.on.clipboard") }
            }
            if let error { InlineError(message: error) }
            if let data {
                if let duty = data.nextDuty, duty.daysRemaining == 0 { dutySection(duty) }
                itemSection("紧急待办", data.urgent)
                let urgent = Set(data.urgent.map(\.id))
                itemSection("逾期事项", data.overdue.filter { !urgent.contains($0.id) })
                itemSection("今日到期", data.dueToday.filter { !urgent.contains($0.id) })
                let shown = urgent.union(data.overdue.map(\.id)).union(data.dueToday.map(\.id))
                itemSection("等待中", data.waiting.filter { !shown.contains($0.id) })
                if let duty = data.nextDuty, duty.daysRemaining != 0 { dutySection(duty) }
                Section("关注的倒计时") {
                    Button { creation = .event } label: { Label("新建倒计时", systemImage: "plus.circle") }
                    ForEach(data.countdowns) { itemLink($0) }
                }
                itemSection("最近记录", data.recent)
            } else {
                Section("关注的倒计时") {
                    Button { creation = .event } label: { Label("新建倒计时", systemImage: "plus.circle") }
                }
                if error == nil { ProgressView() }
            }
        }
        .navigationTitle("今天")
        .task(id: "\(category?.rawValue ?? "all"):\(session.refreshVersion)") { await load() }
        .onChange(of: category) { _, _ in data = nil }
        .refreshable { await load() }
        .sheet(isPresented: $clipboardPresented) {
            NavigationStack { ClipboardImportView(api: api, model: clipboard) }
        }
        .sheet(isPresented: Binding(get: { creation != nil }, set: { if !$0 { creation = nil } })) {
            if let creation {
                NavigationStack {
                    ItemEditor(api: api, draft: .new(creation, category: category)) { _ in session.changed() }
                }
            }
        }
    }

    @ViewBuilder private func itemSection(_ title: String, _ items: [Item]) -> some View {
        if !items.isEmpty { Section(title) { ForEach(items) { itemLink($0) } } }
    }

    private func dutySection(_ duty: Item) -> some View {
        Section(duty.daysRemaining == 0 ? "今日值班" : "下一次值班") {
            NavigationLink {
                ItemDetail(api: api, id: duty.id)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(duty.fields.date ?? "全天值班", systemImage: "calendar.badge.clock")
                    Text(duty.daysRemaining == 0 ? "全天" : "还有 \(duty.daysRemaining ?? 0) 天 · 全天")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func itemLink(_ item: Item) -> some View {
        NavigationLink { ItemDetail(api: api, id: item.id) } label: { ItemRow(item: item) }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if item.fields.kind == .task && item.fields.status != .completed {
                    Button { Task { await completeTask(item) } } label: {
                        Label("完成", systemImage: "checkmark.circle")
                    }
                    .tint(.green)
                }
            }
    }

    private func completeTask(_ item: Item) async {
        var fields = item.fields
        fields.status = .completed
        do {
            _ = try await api.update(item, with: fields)
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
            error = nil
        } catch { if !Task.isCancelled { self.error = session.handleError(error) } }
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
