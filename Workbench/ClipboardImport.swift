import SwiftUI

@MainActor
final class ClipboardImportModel: ObservableObject {
    struct Draft: Identifiable {
        let id: UUID
        var fields: ItemFields
        let evidence: String
        let warnings: [String]
        let missingFields: [String]
        var reviewed: Bool
        var selected: Bool
        var created: Item?
        var error: String?
        var creationKey = UUID()
        var attemptedBody: Data?

        var canCreate: Bool {
            guard !fields.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  fields.kind != .event || fields.targetAt != nil else { return false }
            if let remind = fields.remindAt, let target = fields.targetAt, fields.kind == .event, remind >= target { return false }
            return reviewed || (missingFields.isEmpty && warnings.isEmpty)
        }
    }

    @Published var text = ""
    @Published var entries: [Draft] = []
    @Published private(set) var response: ClipboardParse?
    @Published private(set) var parsing = false
    @Published private(set) var creating = false
    @Published private(set) var error: String?
    private var parsedText: String?
    private var requestText: String?
    private var requestID = UUID()

    var busy: Bool { parsing || creating }
    var currentPreview: Bool { parsedText == normalizedText }
    var normalizedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var characterCount: Int { text.unicodeScalars.count }
    var selectedCount: Int { entries.filter { $0.selected && $0.created == nil && $0.canCreate }.count }
    var selectedIDs: [UUID] { entries.filter { $0.selected && $0.created == nil && $0.canCreate }.map(\.id) }

    func parse(api: WorkbenchAPI) async {
        guard !busy, !normalizedText.isEmpty, characterCount <= 6000 else { return }
        parsing = true
        error = nil
        defer { parsing = false }
        let source = normalizedText
        if requestText != source { requestID = UUID(); requestText = source }
        do {
            let output = try await api.parseClipboard(source, requestID: requestID)
            let previous = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            response = output
            parsedText = source
            entries = output.candidates.map { candidate in
                if let old = previous[candidate.id], old.created != nil { return old }
                return Draft(id: candidate.id, fields: candidate.fields, evidence: candidate.evidence,
                             warnings: candidate.warnings, missingFields: candidate.missingFields,
                             reviewed: candidate.status != "needs_details", selected: candidate.status == "ready")
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func edit(_ id: UUID, fields: ItemFields) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].created == nil else { return }
        entries[index].fields = fields
        entries[index].reviewed = true
        entries[index].selected = entries[index].canCreate
        entries[index].error = nil
    }

    func useAsNote() {
        guard !busy, !normalizedText.isEmpty else { return }
        var fields = ItemFields.new(.note)
        fields.title = String(normalizedText.prefix(60))
        fields.body = normalizedText
        entries = [Draft(id: UUID(), fields: fields, evidence: normalizedText, warnings: [], missingFields: [],
                         reviewed: true, selected: true)]
        parsedText = normalizedText
        error = nil
    }

    func create(api: WorkbenchAPI, session: SessionStore) async {
        guard !busy, currentPreview else { return }
        creating = true
        error = nil
        defer { creating = false }
        let selected = selectedIDs
        for id in selected {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { continue }
            var payload = entries[index].fields
            if payload.kind == .note {
                let body = payload.body ?? ""
                if !body.contains(entries[index].evidence) {
                    payload.body = (body.isEmpty ? "" : body + "\n\n") + entries[index].evidence
                }
            } else {
                let description = payload.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                payload.description = (description.isEmpty ? "" : description + "\n\n") + "原文片段\n" + entries[index].evidence
            }
            do {
                let encoder = WorkbenchAPI.encoder()
                encoder.outputFormatting = [.sortedKeys]
                let body = try encoder.encode(payload)
                if let previous = entries[index].attemptedBody, previous != body { entries[index].creationKey = UUID() }
                entries[index].attemptedBody = body
                entries[index].error = nil
                let saved = try await api.create(payload, key: entries[index].creationKey)
                entries[index].created = saved
                entries[index].selected = false
                session.changed()
            } catch { entries[index].error = error.localizedDescription }
        }
    }
}

@MainActor
struct ClipboardImportView: View {
    let api: WorkbenchAPI
    @ObservedObject var model: ClipboardImportModel
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var editID: ItemRoute?
    @State private var confirming = false

    var body: some View {
        Form {
            Section {
                PasteButton(payloadType: String.self) { strings in model.text = strings.joined(separator: "\n") }
                    .disabled(model.busy)
                TextEditor(text: $model.text)
                    .frame(minHeight: 140)
                    .accessibilityLabel("待识别的剪贴板文字")
                    .disabled(model.busy)
                Text("\(model.characterCount) / 6000 字").font(.caption)
                    .foregroundStyle(model.characterCount > 6000 ? Color.red : Color.secondary)
                Button(model.parsing ? "正在识别…" : "AI 识别") { Task { await model.parse(api: api) } }
                    .disabled(model.busy || model.normalizedText.isEmpty || model.characterCount > 6000
                              || (model.currentPreview && !model.entries.isEmpty))
            } header: {
                Text("粘贴或输入文字")
            } footer: {
                Text("点击 AI 识别后，文字将经工作台服务器发送给 MiMo。结果供你编辑并确认创建。")
            }
            if let error = model.error { InlineError(message: error) }
            if model.parsing { ProgressView() }
            if !model.currentPreview && (!model.entries.isEmpty || model.response != nil) {
                Text("原文已改变，请重新识别后创建。").foregroundStyle(.secondary)
            }
            if model.currentPreview {
                if let result = model.response {
                    Section {
                        if !result.reason.isEmpty { Text(result.reason) }
                        Text("时间基准 · \(BeijingDates.format(result.referenceTime, pattern: "yyyy年M月d日 HH:mm")) · 北京时间")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach($model.entries) { $entry in
                    Section {
                        if let created = entry.created {
                            Label("已创建", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            NavigationLink(created.fields.title) { ItemDetail(api: api, id: created.id) }
                        } else {
                            Toggle(isOn: $entry.selected) {
                                Label(entry.fields.title, systemImage: entry.fields.kind.icon)
                            }
                            .disabled(model.busy || !entry.canCreate)
                            draftSummary(entry)
                            if !entry.reviewed {
                                ForEach(entry.warnings, id: \.self) { Text($0).font(.callout).foregroundStyle(.orange) }
                                if !entry.missingFields.isEmpty {
                                    Text("需要确认 · " + entry.missingFields.map(fieldLabel).joined(separator: "、"))
                                        .font(.callout).foregroundStyle(.orange)
                                }
                            }
                            Text("原文片段\n" + entry.evidence).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                            if let error = entry.error { InlineError(message: error) }
                            Button(entry.reviewed ? "编辑" : "补充信息并确认") { editID = ItemRoute(id: entry.id) }
                                .disabled(model.busy)
                        }
                    }
                }
                if model.selectedCount > 0 {
                    Section {
                        Button(model.creating ? "正在创建…" : "创建选中的 \(model.selectedCount) 项") { confirming = true }
                            .disabled(model.busy)
                    }
                }
            }
            if model.entries.allSatisfy({ $0.created == nil }) && model.characterCount <= 6000 {
                Section {
                    Button("保存为普通记录") { model.useAsNote() }
                        .disabled(model.busy || model.normalizedText.isEmpty)
                }
            }
        }
        .navigationTitle("剪贴板识别")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(model.busy) } }
        .interactiveDismissDisabled(model.busy)
        .confirmationDialog("创建选中的 \(model.selectedCount) 项？", isPresented: $confirming, titleVisibility: .visible) {
            Button("确认创建") { Task { await model.create(api: api, session: session) } }
        }
        .sheet(item: $editID) { route in
            if let draft = model.entries.first(where: { $0.id == route.id }) {
                NavigationStack {
                    ItemEditor(api: api, draft: draft.fields,
                               onDraftSave: { model.edit(route.id, fields: $0) }, onSave: { _ in })
                }
            }
        }
    }

    @ViewBuilder private func draftSummary(_ draft: ClipboardImportModel.Draft) -> some View {
        LabeledContent("类型", value: draft.fields.kind.label)
        if let category = draft.fields.category { LabeledContent("分类", value: category.label) }
        if let status = draft.fields.status { LabeledContent("状态", value: status.label) }
        if let priority = draft.fields.priority { LabeledContent("优先级", value: priority.label) }
        if let impact = draft.fields.impact { LabeledContent("影响程度", value: impact.label) }
        if let text = draft.fields.description, !text.isEmpty { Text(text) }
        if let text = draft.fields.body, !text.isEmpty { Text(text) }
        if let text = draft.fields.waitingFor, !text.isEmpty { LabeledContent("等待", value: text) }
        if let date = draft.fields.dueAt { LabeledContent("截止", value: BeijingDates.format(date, pattern: "yyyy-MM-dd HH:mm")) }
        if let date = draft.fields.targetAt { LabeledContent("目标", value: BeijingDates.format(date, pattern: "yyyy-MM-dd HH:mm")) }
        if let date = draft.fields.remindAt { LabeledContent("提醒", value: BeijingDates.format(date, pattern: "yyyy-MM-dd HH:mm")) }
        if let date = draft.fields.followUpAt { LabeledContent("跟进", value: BeijingDates.format(date, pattern: "yyyy-MM-dd HH:mm")) }
    }

    private func fieldLabel(_ field: String) -> String {
        ["due_at": "截止时间", "target_at": "目标时间", "remind_at": "提醒时间", "follow_up_at": "跟进时间"][field] ?? field
    }
}
