import SwiftUI

@MainActor
struct HomeView: View {
    let api: WorkbenchAPI
    @EnvironmentObject private var session: SessionStore
    @State private var category: Category?
    @State private var data: HomeData?
    @State private var error: String?
    @State private var creation: ItemKind?

    var body: some View {
        List {
            Section {
                Picker("首页分类", selection: $category) {
                    Text("全部").tag(Optional<Category>.none)
                    ForEach(Category.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                Button { creation = .note } label: { Label("快速记录", systemImage: "square.and.pencil") }
            }
            if let error { InlineError(message: error) }
            if let data {
                if let duty = data.nextDuty, duty.daysRemaining == 0 { dutySection(duty) }
                itemSection("紧急待办", data.urgent)
                let urgent = Set(data.urgent.map(\.id))
                itemSection("逾期事项", data.overdue.filter { !urgent.contains($0.id) })
                itemSection("今日到期", data.dueToday.filter { !urgent.contains($0.id) })
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
    }

    private func load() async {
        do {
            let result = try await api.home(category: category)
            guard !Task.isCancelled else { return }
            data = result
            error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
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
    @State private var status: ItemStatus?
    @State private var kind: ItemKind = .note
    @State private var creation: ItemKind?

    private let libraryKinds: [ItemKind] = [.note, .project, .document, .paper, .award]
    private var filterByYear: Bool { mode == .library && (kind == .paper || kind == .award) }
    private var loadID: String { "\(kind.rawValue)|\(status?.rawValue ?? "")|\(query)|\(year)|\(session.refreshVersion)" }

    var body: some View {
        List {
            Section {
                if mode == .tasks {
                    Picker("状态", selection: $status) {
                        Text("全部状态").tag(Optional<ItemStatus>.none)
                        ForEach(ItemStatus.taskStatuses, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }
                } else {
                    Picker("资料类型", selection: $kind) {
                        ForEach(libraryKinds, id: \.self) { Text($0.label).tag($0) }
                    }
                    if filterByYear {
                        TextField("年份（例如 2026）", text: $year)
                            .keyboardType(.numberPad)
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
                Button { creation = mode == .tasks ? .task : kind } label: {
                    Label("新建", systemImage: "plus")
                }
            }
        }
        .task(id: loadID) { await load() }
        .refreshable { await load() }
        .sheet(isPresented: Binding(get: { creation != nil }, set: { if !$0 { creation = nil } })) {
            if let creation {
                NavigationStack {
                    ItemEditor(api: api, draft: .new(creation)) { _ in session.changed() }
                }
            }
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
            let result = try await api.items(kind: mode == .tasks ? .task : kind, status: status, keyword: query,
                                             year: filterByYear && year.count == 4 ? year : nil, offset: more ? items.count : 0)
            guard !Task.isCancelled, current == loadID else { return }
            if more {
                let known = Set(items.map(\.id))
                items += result.items.filter { !known.contains($0.id) }
            } else { items = result.items }
            hasMore = result.hasMore
            error = nil
        } catch {
            if !Task.isCancelled, current == loadID { self.error = error.localizedDescription }
        }
    }
}
