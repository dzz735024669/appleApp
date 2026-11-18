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
    }

    private func reload() async {
        do {
            let result = try await api.attachments(for: itemID)
            if !Task.isCancelled { files = result; error = nil }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func download(_ file: Attachment) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let data = try await api.download(file, from: itemID)
            preview = try DownloadedFile(filename: file.filename, data: data)
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

    private func importPhoto(_ photo: PhotosPickerItem) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false; self.photo = nil }
        do {
            guard let data = try await photo.loadTransferable(type: Data.self) else { throw APIError.emptyFile }
            let ext = photo.supportedContentTypes.first?.preferredFilenameExtension ?? "image"
            let name = "照片-\(BeijingDates.format(.now, pattern: "yyyyMMdd-HHmmss")).\(ext)"
            let uploaded = try await api.upload(data, filename: name, to: itemID)
            files.append(uploaded)
        } catch { self.error = error.localizedDescription }
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

    private final class DownloadedFile: Identifiable {
        let id: UUID
        let url: URL

        init(filename: String, data: Data) throws {
            let identifier = UUID()
            id = identifier
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(identifier.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let safeName = (filename as NSString).lastPathComponent
            url = directory.appendingPathComponent(["", ".", ".."].contains(safeName) ? "附件" : safeName)
            do { try data.write(to: url, options: [.atomic, .completeFileProtection]) }
            catch { try? FileManager.default.removeItem(at: directory); throw error }
        }

        deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
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
