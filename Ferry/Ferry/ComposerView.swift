import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// Mobile-web style input bar: album picker + paste on the left, plus/send on
/// the right, with a WeChat-style panel (文件 / 拍摄) and per-item upload queue.
struct ComposerView: View {
    @Bindable var model: AppModel
    var focused: FocusState<Bool>.Binding

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPreview = false
    @State private var showPlus = false
    @State private var showFileImporter = false
    @State private var showCamera = false
    @State private var pasted = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 8) {
            statusArea
            uploadQueue
            inputBar
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
        .onChange(of: photoItems) { _, items in
            if !items.isEmpty { showPhotoPreview = true }
        }
        .sheet(isPresented: $showPhotoPreview) {
            PhotoPreviewSheet(items: photoItems) { loaded in
                photoItems = []
                enqueue(loaded)
            } onCancel: {
                photoItems = []
            }
        }
        .sheet(isPresented: $showPlus) {
            PlusPanel(onFile: { showFileImporter = true }, onCamera: { openCamera() })
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.data],
                      allowsMultipleSelection: true) { result in
            handleFiles(result)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(mediaTypes: [UTType.image.identifier, UTType.movie.identifier]) { result in
                showCamera = false
                switch result {
                case .success(let capture): handleCapture(capture)
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
        }
        .alert("发送失败", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var statusArea: some View {
        Group {
            if let warning = model.credentialWarning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
            }
            if let message = model.statusMessage {
                Label(message, systemImage: model.phase == .offline ? "wifi.exclamationmark" : "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(model.phase == .offline ? .orange : .red)
            }
            if model.phase == .offline {
                Button("更换服务器", systemImage: "network") { model.disconnect() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var uploadQueue: some View {
        Group {
            if !model.uploader.items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.uploader.items) { item in
                        HStack(spacing: 8) {
                            switch item.phase {
                            case .waiting, .uploading:
                                ProgressView(value: item.progress).progressViewStyle(.circular)
                                    .frame(width: 18, height: 18)
                                Text(item.name).font(.footnote).lineLimit(1)
                                Text("\(Int(item.progress * 100))%").font(.caption2).foregroundStyle(.secondary)
                            case .done:
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text(item.name).font(.footnote).lineLimit(1)
                            case .failed:
                                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).font(.footnote).lineLimit(1)
                                    if let error = item.error {
                                        Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
                                    }
                                }
                            }
                            Spacer(minLength: 4)
                            if item.phase == .done || item.phase == .failed {
                                Button { model.uploader.remove(item.id) } label: {
                                    Image(systemName: "xmark").font(.caption2)
                                }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            HStack(spacing: 6) {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 9, matching: .images) {
                    Image(systemName: "photo.on.rectangle.angled")
                }
                .accessibilityLabel("相册")

                PasteButton(payloadType: String.self) { strings in
                    if let text = strings.first { model.draft += text; flashPaste() }
                }
                .labelStyle(.iconOnly)
                .tint(pasted ? .green : .accentColor)
                .accessibilityLabel("粘贴")
            }
            TextField("消息", text: $model.draft, axis: .vertical)
                .lineLimit(1...5)
                .focused(focused)
                .padding(.horizontal, 4).padding(.vertical, 8)
            if model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                plusButton
            } else {
                sendButton
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var plusButton: some View {
        Button { showPlus = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.15), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("添加")
    }

    private var sendButton: some View {
        Button {
            focused.wrappedValue = false
            Task { await model.send() }
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.borderedProminent)
        .clipShape(Circle())
        .disabled(!model.canSend)
        .accessibilityLabel("发送")
    }

    private func openCamera() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            showCamera = true
        } else {
            errorMessage = "此设备没有可用的相机。"
        }
    }

    private func flashPaste() {
        pasted = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            pasted = false
        }
    }

    private func enqueue(_ list: [(Data, String, String)]) {
        for (data, mime, name) in list {
            if let error = model.uploader.enqueue(data: data, name: name, mediaType: mime) {
                errorMessage = error
            }
        }
    }

    private func handleFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                if let loaded = MediaLoader.file(from: url) {
                    if let error = model.uploader.enqueue(data: loaded.data, name: loaded.name, mediaType: loaded.mime) {
                        errorMessage = error
                    }
                }
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func handleCapture(_ capture: Capture) {
        switch capture {
        case .photo(let image):
            if let loaded = MediaLoader.capturedImage(image) {
                if let error = model.uploader.enqueue(data: loaded.data, name: loaded.name, mediaType: loaded.mime) {
                    errorMessage = error
                }
            }
        case .video(let url):
            if let loaded = MediaLoader.capturedVideo(from: url) {
                if let error = model.uploader.enqueue(data: loaded.data, name: loaded.name, mediaType: loaded.mime) {
                    errorMessage = error
                }
            }
        }
    }
}

/// Preview sheet for picked photos with a top-right 发送 button that uploads
/// the photos directly (not into the text box).
struct PhotoPreviewSheet: View {
    let items: [PhotosPickerItem]
    let onSend: ([(Data, String, String)]) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var loaded: [LoadedPhoto] = []
    @State private var sending = false

    struct LoadedPhoto: Identifiable {
        let id = UUID()
        let data: Data
        let mime: String
        let name: String
        var image: UIImage? { UIImage(data: data) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if loaded.isEmpty {
                    ProgressView().padding(.top, 120)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], spacing: 6) {
                    ForEach(loaded) { photo in
                        if let image = photo.image {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: 100, height: 100).clipped()
                        } else {
                            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                                .frame(width: 100, height: 100).overlay { ProgressView() }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("已选照片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { onCancel(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("发送") { send() }
                        .fontWeight(.semibold)
                        .disabled(loaded.isEmpty || sending)
                }
            }
        }
        .task { await loadAll() }
    }

    private func loadAll() async {
        var result: [LoadedPhoto] = []
        for item in items {
            if let loaded = await MediaLoader.photo(from: item) {
                result.append(LoadedPhoto(data: loaded.data, mime: loaded.mime, name: loaded.name))
            }
        }
        loaded = result
    }

    private func send() {
        sending = true
        let payload = loaded.map { ($0.data, $0.mime, $0.name) }
        onSend(payload)
        dismiss()
    }
}

/// WeChat-style attachment panel with only 文件 and 拍摄 slots.
struct PlusPanel: View {
    let onFile: () -> Void
    let onCamera: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 16) {
            panelButton("文件", systemImage: "folder") {
                dismiss(); onFile()
            }
            panelButton("拍摄", systemImage: "camera") {
                dismiss(); onCamera()
            }
        }
        .padding(24)
        .presentationDetents([.height(180)])
        .presentationDragIndicator(.visible)
    }

    private func panelButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: systemImage).font(.title2)
                Text(title).font(.footnote)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}
