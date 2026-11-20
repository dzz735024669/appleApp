import PhotosUI
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct AttachmentSection: View {
    let api: WorkbenchAPI
    let itemID: UUID
    @State private var files: [Attachment] = []
    @State private var busy = false
    @State private var error: String?
    @State private var importing = false
    @State private var camera = false
    @State private var photo: PhotosPickerItem?
    @State private var preview: DownloadedFile?
    @State private var deleting: Attachment?

    var body: some View {
        Section("附件") {
            ForEach(files) { file in
                Button { Task { await download(file) } } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(file.filename, systemImage: "doc")
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(busy)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { deleting = file } label: { Label("删除", systemImage: "trash") }
                        .disabled(busy)
                }
                .contextMenu {
                    Button(role: .destructive) { deleting = file } label: { Label("删除附件", systemImage: "trash") }
                }
            }
            if let error { InlineError(message: error) }
            if busy { ProgressView() }
            Button("从文件上传", systemImage: "square.and.arrow.up") { importing = true }
                .disabled(busy)
            PhotosPicker(selection: $photo, matching: .images) {
                Label("从照片上传", systemImage: "photo")
            }
            .disabled(busy)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("拍照上传", systemImage: "camera") { camera = true }.disabled(busy)
            }
        }
        .task(id: itemID) { await reload() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): Task { await importFile(url) }
            case .failure(let issue): error = issue.localizedDescription
            }
        }
        .onChange(of: photo) { _, value in
            if let value { Task { await importPhoto(value) } }
        }
        .sheet(item: $preview) { file in
            NavigationStack {
                PreviewController(url: file.url)
                    .navigationTitle(file.url.lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("关闭") { preview = nil } }
                        ToolbarItem(placement: .primaryAction) { ShareLink(item: file.url) }
                    }
            }
        }
        .fullScreenCover(isPresented: $camera) {
            CameraPicker { image in
                camera = false
                if let image { Task { await uploadCameraImage(image) } }
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("删除这个附件？",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            if let file = deleting {
                Button("删除「\(file.filename)」", role: .destructive) { Task { await remove(file) } }
            }
        }
    }

    private func reload() async {
        do {
            let result = try await api.attachments(for: itemID)
            if !Task.isCancelled { files = result; error = nil }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func download(_ file: Attachment) async {
        guard !busy else { return }
        if let cached = DownloadedFile.existing(id: file.id, filename: file.filename) {
            preview = cached
            return
        }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let data = try await api.download(file, from: itemID)
            preview = try DownloadedFile(id: file.id, filename: file.filename, data: data)
        } catch { self.error = error.localizedDescription }
    }

    private func importFile(_ url: URL) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true else { throw APIError.emptyFile }
                if let size = values.fileSize, size > WorkbenchAPI.attachmentLimit { throw APIError.fileTooLarge }
                return try Data(contentsOf: url, options: .mappedIfSafe)
            }.value
            let uploaded = try await api.upload(data, filename: url.lastPathComponent, to: itemID)
            files.append(uploaded)
        } catch { self.error = error.localizedDescription }
    }

    private func remove(_ file: Attachment) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false; deleting = nil }
        do {
            try await api.deleteAttachment(file, from: itemID)
            DownloadedFile.evict(id: file.id)
            files.removeAll { $0.id == file.id }
        } catch { self.error = error.localizedDescription }
    }

    private func importPhoto(_ photo: PhotosPickerItem) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false; self.photo = nil }
        do {
            guard let raw = try await photo.loadTransferable(type: Data.self), !raw.isEmpty else { throw APIError.emptyFile }
            let (payload, ext) = Self.webCompatibleImage(from: raw, suggestedExtension: photo.supportedContentTypes.first?.preferredFilenameExtension)
            let name = "照片-\(BeijingDates.format(.now, pattern: "yyyyMMdd-HHmmss")).\(ext)"
            let uploaded = try await api.upload(payload, filename: name, to: itemID)
            files.append(uploaded)
        } catch { self.error = error.localizedDescription }
    }

    private static func webCompatibleImage(from data: Data, suggestedExtension: String?) -> (Data, String) {
        let bytes = [UInt8](data.prefix(12))
        let isPNG = bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let isJPEG = bytes.starts(with: [0xFF, 0xD8, 0xFF])
        let isGIF = bytes.starts(with: [0x47, 0x49, 0x46, 0x38, 0x37, 0x61]) || bytes.starts(with: [0x47, 0x49, 0x46, 0x38, 0x39, 0x61])
        let isWEBP = bytes.count >= 12 && bytes[0..<4] == [0x52, 0x49, 0x46, 0x46] && bytes[8..<12] == [0x57, 0x45, 0x50, 0x42]
        if isPNG { return (data, "png") }
        if isJPEG { return (data, "jpg") }
        if isGIF { return (data, "gif") }
        if isWEBP { return (data, "webp") }
        if let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.88) {
            return (jpeg, "jpg")
        }
        return (data, suggestedExtension ?? "image")
    }

    private func uploadCameraImage(_ image: UIImage) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            guard let data = image.jpegData(compressionQuality: 0.9) else { throw APIError.emptyFile }
            let filename = "拍照-\(BeijingDates.format(.now, pattern: "yyyyMMdd-HHmmss")).jpg"
            let uploaded = try await api.upload(data, filename: filename, to: itemID)
            files.append(uploaded)
        } catch { self.error = error.localizedDescription }
    }

    private struct DownloadedFile: Identifiable {
        let id: UUID
        let url: URL

        private static var cacheRoot: URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("workbench-attachments", isDirectory: true)
        }

        private static func targetURL(id: UUID, filename: String) -> URL {
            let safeName = (filename as NSString).lastPathComponent
            let name = ["", ".", ".."].contains(safeName) ? "附件" : safeName
            return cacheRoot.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent(name)
        }

        static func existing(id: UUID, filename: String) -> DownloadedFile? {
            let path = targetURL(id: id, filename: filename)
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            return DownloadedFile(id: id, url: path)
        }

        static func evict(id: UUID) {
            try? FileManager.default.removeItem(at: cacheRoot.appendingPathComponent(id.uuidString, isDirectory: true))
        }

        private init(id: UUID, url: URL) {
            self.id = id
            self.url = url
        }

        init(id: UUID, filename: String, data: Data) throws {
            self.id = id
            let fileURL = Self.targetURL(id: id, filename: filename)
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            self.url = fileURL
        }
    }

    private struct PreviewController: UIViewControllerRepresentable {
        let url: URL

        func makeCoordinator() -> Coordinator { Coordinator(url: url) }

        func makeUIViewController(context: Context) -> QLPreviewController {
            let controller = QLPreviewController()
            controller.dataSource = context.coordinator
            return controller
        }

        func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

        final class Coordinator: NSObject, QLPreviewControllerDataSource {
            let url: URL
            init(url: URL) { self.url = url }
            func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
            func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
        }
    }

    private struct CameraPicker: UIViewControllerRepresentable {
        let finished: (UIImage?) -> Void

        func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }

        func makeUIViewController(context: Context) -> UIImagePickerController {
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

        final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
            let finished: (UIImage?) -> Void
            init(finished: @escaping (UIImage?) -> Void) { self.finished = finished }
            func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finished(nil) }
            func imagePickerController(_ picker: UIImagePickerController,
                                       didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
                finished(info[.originalImage] as? UIImage)
            }
        }
    }
}
