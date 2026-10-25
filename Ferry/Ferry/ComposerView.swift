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
    @State private var showPlus = false
    @State private var showFileImporter = false
    @State private var showCamera = false
    @State private var showEditor = false
    @State private var pasted = false
    @State private var errorMessage: String?
    @State private var textFieldHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 8) {
            statusArea
            uploadQueue
            inputBar
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            let picked = items
            photoItems = []
            Task { await loadAndEnqueue(picked) }
        }
        .sheet(isPresented: $showPlus) {
            PlusPanel(onFile: { showFileImporter = true }, onCamera: { openCamera() })
        }
        .sheet(isPresented: $showEditor) {
            ExpandEditorView(text: $model.draft) {
                focused.wrappedValue = false
                Task { await model.send() }
            }
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
                case .failure(let error):
                    if (error as? CameraPicker.CameraError) == .cancelled { return }
                    errorMessage = error.localizedDescription
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

    private var capsuleColor: Color {
        Color(uiColor: UIColor(red: 44/255, green: 44/255, blue: 46/255, alpha: 1))
    }

    /// Fixed frame for the plus/send (and icon) buttons so switching between
    /// them never changes the input bar height.
    private var barButtonSize: CGFloat { 36 }

    /// Approximate line count of the growing text field, used to reveal the
    /// expand button once the draft exceeds ~3 lines.
    private var expandLineHeight: CGFloat {
        UIFont.preferredFont(forTextStyle: .body).lineHeight
    }
    private var estimatedLineCount: Int {
        guard textFieldHeight > 0, expandLineHeight > 0 else { return 1 }
        return max(1, Int((textFieldHeight / expandLineHeight).rounded(.up)))
    }
    private var shouldShowExpand: Bool {
        estimatedLineCount > 3
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
        let visible = model.uploader.items.filter { $0.phase != .done }
        return Group {
            if !visible.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(visible) { item in
                        HStack(spacing: 8) {
                            if item.phase == .failed {
                                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).font(.footnote).lineLimit(1)
                                    if let error = item.error {
                                        Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
                                    }
                                }
                            } else {
                                ProgressView(value: item.progress).progressViewStyle(.circular)
                                    .frame(width: 18, height: 18)
                                Text(item.name).font(.footnote).lineLimit(1)
                                Text("\(Int(item.progress * 100))%").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if item.phase == .failed {
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
        HStack(spacing: 10) {
            PhotosPicker(selection: $photoItems, maxSelectionCount: 9, matching: .any(of: [.images, .videos])) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.white)
                    .frame(width: barButtonSize, height: barButtonSize)
            }
            .accessibilityLabel("相册")

            PasteButton(payloadType: String.self) { strings in
                if let text = strings.first { model.draft += text; flashPaste() }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .tint(.white)
            .foregroundStyle(.white)
            .frame(width: barButtonSize, height: barButtonSize)
            .accessibilityLabel("粘贴")

            TextField("输入消息...", text: $model.draft, axis: .vertical)
                .lineLimit(1...5)
                .focused(focused)
                .foregroundStyle(.white)
                .tint(.white)
                .padding(.horizontal, 4)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { newHeight in
                    textFieldHeight = newHeight
                }
                .overlay(alignment: .topTrailing) {
                    if shouldShowExpand {
                        Button { showEditor = true } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("展开")
                    }
                }

            if model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                plusButton
            } else {
                sendButton
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(capsuleColor, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var plusButton: some View {
        Button { showPlus = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .semibold))
                .frame(width: barButtonSize, height: barButtonSize)
                .foregroundStyle(.white)
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
                .font(.system(size: 20, weight: .semibold))
                .frame(width: barButtonSize, height: barButtonSize)
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
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

    private func loadAndEnqueue(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let loaded = await MediaLoader.media(from: item) {
                if let error = model.uploader.enqueue(data: loaded.data, name: loaded.name, mediaType: loaded.mime) {
                    errorMessage = error
                }
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

/// WeChat-style full-screen editor for long messages. The text is bound to the
/// draft, so collapsing or swiping down to dismiss never discards text; only
/// 发送 sends and (on success) clears it. Focus + keyboard come up on appear
/// with the caret at the end of the existing text.
struct ExpandEditorView: View {
    @Binding var text: String
    let onSend: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("输入消息...", text: $text, axis: .vertical)
                    .lineLimit(1...50)
                    .focused($focused)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                HStack {
                    Spacer()
                    Button("发送") { send() }
                        .buttonStyle(.borderedProminent)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("发送")
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            .background(Color.chatBackground.ignoresSafeArea())
            .navigationTitle("编辑消息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                    }
                    .accessibilityLabel("收起")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                focused = true
            }
        }
    }

    private func send() {
        dismiss()
        onSend()
    }
}
