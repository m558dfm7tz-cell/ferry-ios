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
    @State private var textFieldHeight: CGFloat = 44
    @State private var mentionContext: MentionContext?
    @State private var activeTarget: MentionTarget?
    @State private var insertCommand: TextInsertion?
    @State private var pasteAvailable = false
    @AppStorage("ferry.sendOriginalVideo") private var sendOriginalVideo = false

    var body: some View {
        VStack(spacing: 8) {
            statusArea
            uploadQueue
            if mentionContext != nil {
                MentionPickerView(targets: model.catalog.targets,
                                  query: mentionContext?.query ?? "",
                                  activeTarget: activeTarget,
                                  onSelectTarget: selectMentionTarget,
                                  onSelectCommand: selectCommand)
                    .frame(maxWidth: 320, alignment: .leading)
            }
            inputBar
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            let picked = items
            photoItems = []
            Task { await loadAndEnqueue(picked) }
        }
        .onAppear { refreshPasteAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            refreshPasteAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshPasteAvailability()
        }
        .sheet(isPresented: $showPlus) {
            PlusPanel(onFile: { showFileImporter = true }, onCamera: { openCamera() })
        }
        .sheet(isPresented: $showEditor) {
            ExpandEditorView(text: $model.draft,
                             catalog: model.catalog,
                             refreshCatalog: { model.refreshCommandCatalog() },
                             onSend: {
                                 focused.wrappedValue = false
                                 Task { await model.send() }
                             })
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
    /// them never changes the input bar height. Sized to match the taller
    /// composer so all controls stay vertically aligned.
    private var barButtonSize: CGFloat { 44 }

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
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(visible) { item in
                        uploadRow(item)
                    }
                }
                .padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func uploadRow(_ item: Uploader.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if item.phase == .failed {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
                Text(item.name).font(.footnote).lineLimit(1)
                Spacer(minLength: 4)
                if item.phase == .failed {
                    Text("失败").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                    Button { model.uploader.retry(item.id) } label: {
                        Text("重试").font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                } else if item.phase == .transcoding {
                    Text("转码中…").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("\(Int(item.progress * 100))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button { model.uploader.remove(item.id) } label: {
                    Image(systemName: "xmark").font(.caption2)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("取消")
            }
            if item.phase == .failed, let error = item.error {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
            } else if item.phase == .transcoding {
                ProgressView()
                    .progressViewStyle(.linear)
            } else {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $photoItems, maxSelectionCount: 20, matching: .any(of: [.images, .videos, .livePhotos])) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.white)
                    .frame(width: barButtonSize, height: barButtonSize)
            }
            .accessibilityLabel("相册")

            Button { pasteFromClipboard() } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.white)
                    .frame(width: barButtonSize, height: barButtonSize)
            }
            .buttonStyle(.plain)
            .disabled(!pasteAvailable)
            .opacity(pasteAvailable ? 1 : 0.4)
            .accessibilityLabel("粘贴")
            .accessibilityIdentifier("paste-button")

            ComposerTextView(text: $model.draft,
                             height: $textFieldHeight,
                             insertCommand: $insertCommand,
                             placeholder: "输入消息...",
                             isFocused: focused,
                             maxLines: 5,
                             textColor: .white,
                             tintColor: .white,
                             alwaysScrolls: false,
                             minHeight: 44,
                             onMentionChange: { context in
                                 mentionContext = context
                                 activeTarget = nil
                                 if context != nil { model.refreshCommandCatalog() }
                             },
                             accessibilityIdentifier: "composer-input")
                .frame(height: textFieldHeight)
                .padding(.horizontal, 4)
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
                .font(.system(size: 22, weight: .semibold))
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
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: barButtonSize, height: barButtonSize)
                .background(sendButtonFill, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canSend)
        .accessibilityLabel("发送")
    }

    /// Web-style send button: filled near-white circle with a dark up arrow.
    private var sendButtonFill: Color {
        Color(red: 0.93, green: 0.94, blue: 0.96)
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

    // MARK: - Paste from clipboard

    /// The paste button is enabled whenever the general pasteboard carries
    /// text, an image, or a file URL. Re-checked on appear, on pasteboard
    /// change notifications, and when the app returns to the foreground.
    private func refreshPasteAvailability() {
        let pb = UIPasteboard.general
        pasteAvailable = pb.hasStrings || pb.hasImages || pb.hasURLs
    }

    /// Route the clipboard content: text fills the input box, while an image
    /// or a file is sent directly as its own message.
    private func pasteFromClipboard() {
        let pb = UIPasteboard.general
        if pb.hasImages, let image = pb.image {
            if let data = image.jpegData(compressionQuality: 0.9) {
                let name = MediaLoader.generatedName(prefix: "粘贴", mime: "image/jpeg")
                if let error = model.uploader.enqueue(data: data, name: name, mediaType: "image/jpeg") {
                    errorMessage = error
                }
            }
            return
        }
        if pb.hasURLs, let url = pb.url, url.isFileURL {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let info = MediaLoader.fileInfo(from: url) {
                if let error = model.uploader.enqueue(fileURL: url, name: info.name, mediaType: info.mime) {
                    errorMessage = error
                }
            }
            return
        }
        if pb.hasStrings, let text = pb.string {
            model.draft += text
            flashPaste()
        }
    }

    // MARK: - Mention / command picker

    private func selectMentionTarget(_ target: MentionTarget) {
        guard let context = mentionContext else { return }
        if let insertText = target.insertText {
            insertCommand = TextInsertion(id: UUID(), range: context.range, text: insertText)
            mentionContext = nil
            activeTarget = nil
        } else if !target.commands.isEmpty {
            activeTarget = target
        }
    }

    private func selectCommand(_ command: CommandItem) {
        guard let context = mentionContext else { return }
        insertCommand = TextInsertion(id: UUID(), range: context.range, text: command.insertText)
        mentionContext = nil
        activeTarget = nil
    }

    private func loadAndEnqueue(_ items: [PhotosPickerItem]) async {
        for item in items {
            await loadAndEnqueueOne(item)
        }
    }

    private func loadAndEnqueueOne(_ item: PhotosPickerItem) async {
        if MediaLoader.isLivePhoto(item) {
            await enqueueLivePhoto(item)
        } else if MediaLoader.isMovie(item) {
            if let movie = await MediaLoader.movie(from: item) {
                enqueueVideo(from: movie.url, mime: movie.mime, name: movie.name)
            }
        } else {
            if let image = await MediaLoader.image(from: item) {
                enqueueData(image.data, name: image.name, mediaType: image.mime)
            }
        }
    }

    private func enqueueData(_ data: Data, name: String, mediaType: String) {
        if let error = model.uploader.enqueue(data: data, name: name, mediaType: mediaType) {
            errorMessage = error
        }
    }

    /// Live Photo: send the still image plus the paired video as two messages.
    /// The still frame is read from the photo-library resource (`.photo`/
    /// `.fullSizePhoto`), and the video is transcoded to MP4 (or sent as the
    /// original `.mov` when "发送原始视频" is on) so it always renders as a
    /// playable video bubble. Falls back to still-only when the video cannot
    /// be read.
    private func enqueueLivePhoto(_ item: PhotosPickerItem) async {
        if let image = await MediaLoader.livePhotoStillImage(from: item) {
            enqueueData(image.data, name: image.name, mediaType: image.mime)
        }
        guard let videoURL = await MediaLoader.livePhotoVideoURL(from: item) else { return }
        if sendOriginalVideo {
            let name = MediaLoader.generatedName(prefix: "实况照片", mime: "video/quicktime")
            enqueueVideo(from: videoURL, mime: "video/quicktime", name: name)
        } else {
            let name = MediaLoader.generatedName(prefix: "实况照片", mime: "video/mp4")
            enqueueVideo(from: videoURL, mime: "video/mp4", name: name)
        }
    }

    /// Enqueue a source video URL: transcodes to MP4 by default (showing
    /// "转码中…" in the queue), or sends the original container when the
    /// "发送原始视频" setting is enabled — or when transcoding fails. The file
    /// is always streamed into the multipart body, never loaded whole into memory.
    private func enqueueVideo(from url: URL, mime: String, name: String) {
        if sendOriginalVideo {
            if let error = model.uploader.enqueue(fileURL: url, name: name, mediaType: mime) {
                errorMessage = error
            } else {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }
        let mp4Name = MediaLoader.mp4Name(from: name)
        let id = model.uploader.enqueueTranscoding(name: mp4Name)
        Task { @MainActor in
            let output = await MediaLoader.transcodeToMP4(from: url)
            if let output {
                if let error = model.uploader.completeTranscode(id, fileURL: output, name: mp4Name, mediaType: "video/mp4") {
                    errorMessage = error
                }
                try? FileManager.default.removeItem(at: output)
            } else {
                if let error = model.uploader.completeTranscode(id, fileURL: url, name: name, mediaType: mime) {
                    errorMessage = error
                }
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func handleFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                if let info = MediaLoader.fileInfo(from: url) {
                    if let error = model.uploader.enqueue(fileURL: url, name: info.name, mediaType: info.mime) {
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
            let ext = (url.pathExtension.isEmpty ? "mov" : url.pathExtension).lowercased()
            let mime = MediaLoader.mime(forExtension: ext)
            let name = MediaLoader.generatedName(prefix: "拍摄", mime: mime)
            enqueueVideo(from: url, mime: mime, name: name)
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
    let catalog: CommandCatalogStore
    let refreshCatalog: () -> Void
    let onSend: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var mentionContext: MentionContext?
    @State private var activeTarget: MentionTarget?
    @State private var insertCommand: TextInsertion?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ComposerTextView(text: $text,
                                 height: .constant(0),
                                 insertCommand: $insertCommand,
                                 placeholder: "输入消息...",
                                 isFocused: $focused,
                                 maxLines: 50,
                                 textColor: .label,
                                 tintColor: .systemBlue,
                                 alwaysScrolls: true,
                                 onMentionChange: { context in
                                     mentionContext = context
                                     activeTarget = nil
                                     if context != nil { refreshCatalog() }
                                 },
                                 accessibilityIdentifier: "editor-input")
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if mentionContext != nil {
                    MentionPickerView(targets: catalog.targets,
                                      query: mentionContext?.query ?? "",
                                      activeTarget: activeTarget,
                                      onSelectTarget: selectMentionTarget,
                                      onSelectCommand: selectCommand)
                        .frame(maxWidth: 320, alignment: .leading)
                        .padding(.horizontal, 12)
                }

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

    private func selectMentionTarget(_ target: MentionTarget) {
        guard let context = mentionContext else { return }
        if let insertText = target.insertText {
            insertCommand = TextInsertion(id: UUID(), range: context.range, text: insertText)
            mentionContext = nil
            activeTarget = nil
        } else if !target.commands.isEmpty {
            activeTarget = target
        }
    }

    private func selectCommand(_ command: CommandItem) {
        guard let context = mentionContext else { return }
        insertCommand = TextInsertion(id: UUID(), range: context.range, text: command.insertText)
        mentionContext = nil
        activeTarget = nil
    }
}
