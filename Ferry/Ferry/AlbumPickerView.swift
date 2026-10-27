import SwiftUI
import Photos
import UIKit

/// WeChat-style photo picker, presented from the composer's 相册 button.
///
/// Grid page:
/// - album-switch capsule (top) + a tap-away album list,
/// - a 4-column thumbnail grid sorted newest-first,
/// - a sequence-numbered selection circle on each selectable cell,
/// - per-cell video duration and Live Photo ("实况") badges,
/// - a bottom bar of 预览 / 原图 / 发送(N), with 原图 on by default,
/// - limited / denied photo-library permission handling, and
/// - `PHCachingImageManager` thumbnail caching.
///
/// Full-screen 大图预览 (`AlbumPreviewView`): tap a thumbnail to open from that
/// image and page left/right through the whole album; the 预览 button pages
/// through only the selected assets. It shares selection / 原图 / edited-image
/// / 实况 state with the grid, and single-tap hides/shows the bars. A 实况
/// toggle appears next to 原图 when the current photo is a Live Photo.
///
/// Sending reuses the existing `Uploader.enqueue` path for still images:
/// original bytes when 原图 is checked, otherwise a downscaled JPEG. A Live
/// Photo with 实况 on additionally sends its paired video as a separate
/// `video/mp4` message right after the still (extracted via the
/// `.pairedVideo` resource, MOV transcoded by `AVAssetExportSession`).
struct AlbumPickerView: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss

    @State private var albums: [PickerAlbum] = []
    @State private var currentAlbum: PickerAlbum?
    @State private var assets: [PHAsset] = []
    /// Selected assets in tap order; the badge number is its 1-based index.
    @State private var selected: [PHAsset] = []
    @State private var sendOriginal = true
    @State private var showAlbumList = false
    @State private var permission: PickerPermission = .loading
    @State private var isSending = false
    @State private var sendError: String?
    /// Confirm dialog shown when closing with a non-empty selection.
    @State private var showDiscardConfirm = false
    /// Whether the grid's scroll view is at the very top (used to gate the
    /// pull-down-to-close gesture so it never fights normal scrolling).
    @State private var gridAtTop = true
    /// Vertical translation of the whole grid page while it is being pulled
    /// down to close.
    @State private var dismissDrag: CGFloat = 0
    @State private var gridDragStartedAtTop = false
    @State private var gridDragInProgress = false
    @State private var imageManager = PHCachingImageManager()
    @State private var libraryObserver: LibraryChangeObserver?
    /// Full-screen preview state; nil shows the grid.
    @State private var previewContext: PickerPreviewContext?
    /// Edited replacements keyed by asset localIdentifier. When present for a
    /// selected asset, the edited image is sent instead of the original bytes.
    @State private var editedImages: [String: UIImage] = [:]
    /// Live Photo 实况 switches keyed by asset localIdentifier. When true the
    /// paired video is sent as a separate message right after the still.
    /// Default off, set per-asset, auto-off when the photo is edited.
    @State private var liveEnabled: [String: Bool] = [:]

    private let columns = [GridItem](repeating: GridItem(.flexible(), spacing: 1), count: 4)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let context = previewContext {
                AlbumPreviewView(displayAssets: context.assets,
                                 startIndex: context.startIndex,
                                 selected: $selected,
                                 sendOriginal: $sendOriginal,
                                 editedImages: $editedImages,
                                 liveEnabled: $liveEnabled,
                                 imageManager: imageManager,
                                 onSend: send,
                                 onClose: { previewContext = nil })
                    .zIndex(1)
            } else {
                switch permission {
                case .loading:
                    ProgressView().tint(.white)
                case .denied:
                    deniedView
                case .limited, .ready:
                    content
                }
                if showAlbumList { albumListOverlay }
            }
        }
        .statusBarHidden()
        .task { await resolvePermission() }
        .alert("发送失败", isPresented: sendErrorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(sendError ?? "")
        }
        .alert("放弃已选的 \(selected.count) 项？", isPresented: $showDiscardConfirm) {
            Button("放弃", role: .destructive) { dismiss() }
            Button("继续选择", role: .cancel) {}
        } message: {
            Text("关闭后将不再发送这些照片。")
        }
    }

    private var sendErrorBinding: Binding<Bool> {
        Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            topBar
            if permission == .limited { limitedBanner }
            grid
            bottomBar
        }
        // The whole page follows the finger down during a pull-down-to-close.
        .offset(y: dismissDrag)
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            Button { requestClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")

            Spacer()

            albumCapsule

            Spacer()

            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.top, 4)
    }

    private var albumCapsule: some View {
        Button { showAlbumList.toggle() } label: {
            HStack(spacing: 6) {
                Text(currentAlbum?.title ?? "最近项目")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                Image(systemName: showAlbumList ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.white.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("切换相册")
    }

    private var limitedBanner: some View {
        HStack(spacing: 8) {
            Text("仅可访问部分照片")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Button("管理") { presentLimitedLibraryPicker() }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(pickerGreen)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.white.opacity(0.08))
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 1) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    PickerGridCell(
                        asset: asset,
                        sequence: selectionIndex(for: asset),
                        isSelectable: isSelectable(asset),
                        imageManager: imageManager,
                        onTapCircle: { toggle(asset) },
                        onTapThumbnail: { openPreview(at: asset) }
                    )
                }
            }
        }
        // Track the top edge so pull-to-close only engages at the very top;
        // anywhere else a downward drag is ordinary scrolling.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y <= 0
        } action: { _, isAtTop in
            gridAtTop = isAtTop
        }
        .simultaneousGesture(dismissDragGesture)
    }

    /// Pull-down-to-close: when the grid is at the top, a downward drag moves
    /// the whole page with the finger; releasing past the threshold (or a fast
    /// flick) closes it, otherwise it springs back. When the grid is not at the
    /// top the gesture is a no-op so the scroll view scrolls normally.
    private var dismissDragGesture: some Gesture {
        // A small minimum distance keeps cell taps / circle buttons crisp (a
        // tap is not a drag) while still tracking the pull the moment it moves.
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if !gridDragInProgress {
                    gridDragInProgress = true
                    gridDragStartedAtTop = gridAtTop
                }
                guard gridDragStartedAtTop, gridAtTop, value.translation.height > 0 else {
                    if dismissDrag != 0 { dismissDrag = 0 }
                    return
                }
                dismissDrag = value.translation.height
            }
            .onEnded { value in
                defer {
                    gridDragStartedAtTop = false
                    gridDragInProgress = false
                }
                let shouldClose = gridDragStartedAtTop && (dismissDrag > 140 || value.predictedEndTranslation.height > 240)
                withAnimation(.easeOut(duration: 0.25)) { dismissDrag = 0 }
                if shouldClose { requestClose() }
            }
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            Button {
                guard !selected.isEmpty else { return }
                // 预览 only shows the already-selected assets.
                previewContext = PickerPreviewContext(assets: selected, startIndex: 0)
            } label: {
                Text("预览")
                    .font(.system(size: 15))
                    .foregroundStyle(selected.isEmpty ? Color.white.opacity(0.4) : Color.white)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)

            Button { sendOriginal.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: sendOriginal ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(sendOriginal ? pickerGreen : Color.white.opacity(0.8))
                    Text("原图")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            sendButton
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Color.black.opacity(0.9))
    }

    private var sendButton: some View {
        Button(action: send) {
            Text(selected.isEmpty ? "发送" : "发送(\(selected.count))")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected.isEmpty ? Color.white.opacity(0.5) : Color.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected.isEmpty ? Color.white.opacity(0.15) : pickerGreen,
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(selected.isEmpty || isSending)
        .accessibilityLabel(selected.isEmpty ? "发送" : "发送\(selected.count)张")
    }

    // MARK: - Album list

    private var albumListOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { showAlbumList = false }

            VStack(spacing: 0) {
                // The capsule stays above the dim so tapping it again collapses
                // the list (its chevron flips up while open), instead of being
                // buried under the scrim.
                albumCapsule
                    .padding(.top, 4)

                Spacer()

                VStack(spacing: 0) {
                    Text("选择相册")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(albums) { album in
                                Button { select(album) } label: {
                                    HStack(spacing: 10) {
                                        Text(album.title)
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white)
                                        Spacer()
                                        if album.id == currentAlbum?.id {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(pickerGreen)
                                        }
                                    }
                                    .padding(.horizontal, 20).padding(.vertical, 13)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 380)
                }
                .frame(maxWidth: .infinity)
                .background(Color(red: 0.13, green: 0.13, blue: 0.14))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
            }
        }
    }

    // MARK: - Close

    /// Close the picker, confirming first when there are selected photos.
    /// Used by the × button and by the pull-down-to-close gesture.
    private func requestClose() {
        if selected.isEmpty {
            dismiss()
        } else {
            showDiscardConfirm = true
        }
    }

    // MARK: - Permission

    private var deniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 46))
                .foregroundStyle(.white.opacity(0.6))
            Text("无法访问相册")
                .font(.headline)
                .foregroundStyle(.white)
            Text("请在 设置 → 隐私与安全性 → 照片 中允许 Ferry 访问照片。")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(pickerGreen)
            Button("关闭") { dismiss() }
                .foregroundStyle(.white)
        }
    }

    @MainActor
    private func resolvePermission() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .notDetermined:
            apply(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
        case .authorized, .limited:
            apply(status)
        case .denied, .restricted:
            permission = .denied
        @unknown default:
            permission = .denied
        }
    }

    @MainActor
    private func apply(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized:
            permission = .ready
        case .limited:
            permission = .limited
            registerLibraryObserverIfNeeded()
        default:
            permission = .denied
            return
        }
        loadAlbums()
    }

    private func presentLimitedLibraryPicker() {
        guard let top = Self.topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }

    private func registerLibraryObserverIfNeeded() {
        guard libraryObserver == nil else { return }
        libraryObserver = LibraryChangeObserver { self.reloadFromLibraryChange() }
    }

    private func reloadFromLibraryChange() {
        loadAlbums()
    }

    // MARK: - Albums & assets

    private func loadAlbums() {
        var list: [PickerAlbum] = []
        let smart = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
        smart.enumerateObjects { collection, _, _ in list.append(PickerAlbum(collection: collection)) }
        let user = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        user.enumerateObjects { collection, _, _ in list.append(PickerAlbum(collection: collection)) }

        list.sort { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a.title < b.title
        }
        albums = list.filter { Self.assetCount(in: $0.collection) > 0 }

        let previousID = currentAlbum?.id
        if let previousID, let kept = albums.first(where: { $0.id == previousID }) {
            currentAlbum = kept
            loadAssets(for: kept)
        } else if let first = albums.first {
            currentAlbum = first
            loadAssets(for: first)
        } else {
            currentAlbum = nil
            assets = []
        }
    }

    private func rank(_ album: PickerAlbum) -> Int {
        switch album.collection.assetCollectionSubtype {
        case .smartAlbumUserLibrary: return 0
        case .smartAlbumFavorites: return 1
        default: break
        }
        if album.collection.assetCollectionType == .album { return 2 }
        return 3
    }

    private static func assetCount(in collection: PHAssetCollection) -> Int {
        PHAsset.fetchAssets(in: collection, options: nil).count
    }

    private func select(_ album: PickerAlbum) {
        currentAlbum = album
        showAlbumList = false
        loadAssets(for: album)
    }

    private func loadAssets(for album: PickerAlbum) {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(in: album.collection, options: options)
        var list: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in list.append(asset) }

        imageManager.stopCachingImagesForAllAssets()
        assets = list
        // Warm the thumbnail cache for the whole album so scrolling is smooth.
        let thumb = CGSize(width: 200, height: 200)
        imageManager.startCachingImages(for: list, targetSize: thumb, contentMode: .aspectFill, options: nil)
    }

    // MARK: - Selection

    private func isSelectable(_ asset: PHAsset) -> Bool {
        // This build sends still images only; videos are shown (with their
        // duration) but become selectable in the next step.
        asset.mediaType == .image
    }

    private func selectionIndex(for asset: PHAsset) -> Int? {
        guard let index = selected.firstIndex(where: { $0.localIdentifier == asset.localIdentifier }) else {
            return nil
        }
        return index + 1
    }

    private func toggle(_ asset: PHAsset) {
        guard isSelectable(asset) else { return }
        if let index = selected.firstIndex(where: { $0.localIdentifier == asset.localIdentifier }) {
            selected.remove(at: index)
        } else {
            selected.append(asset)
        }
    }

    /// Open the full-screen preview starting at `asset`, paging through the
    /// whole current album.
    private func openPreview(at asset: PHAsset) {
        guard let index = assets.firstIndex(where: { $0.localIdentifier == asset.localIdentifier }) else { return }
        previewContext = PickerPreviewContext(assets: assets, startIndex: index)
    }

    // MARK: - Send

    private func send() {
        guard !selected.isEmpty, !isSending else { return }
        isSending = true
        let picks = selected
        let original = sendOriginal
        let edited = editedImages
        let live = liveEnabled
        Task { @MainActor in
            for asset in picks {
                let id = asset.localIdentifier
                let loaded: (data: Data, mime: String, name: String)?
                if let editedImage = edited[id],
                   let data = editedImage.jpegData(compressionQuality: 0.92) {
                    loaded = (data, "image/jpeg", MediaLoader.generatedName(prefix: "照片", mime: "image/jpeg"))
                } else {
                    loaded = await loadSendData(for: asset, manager: imageManager, sendOriginal: original)
                }
                guard let loaded else { continue }
                if let error = model.uploader.enqueue(data: loaded.data, name: loaded.name, mediaType: loaded.mime) {
                    sendError = error
                    isSending = false
                    return
                }
                // Live Photo: with 实况 on (and the still not replaced by an
                // edit), send the paired video as its own message right after.
                if live[id] == true, edited[id] == nil,
                   let mp4 = await loadLivePhotoVideoMP4(for: asset) {
                    defer { try? FileManager.default.removeItem(at: mp4) }
                    let name = MediaLoader.generatedName(prefix: "实况", mime: "video/mp4")
                    if let error = model.uploader.enqueue(fileURL: mp4, name: name, mediaType: "video/mp4") {
                        sendError = error
                        isSending = false
                        return
                    }
                }
            }
            // Sending succeeded: close and tell the timeline to re-anchor to the
            // newest message (the messages arrive asynchronously via the upload
            // queue, so the scroll lands on them once they appear).
            model.requestScrollToBottom()
            dismiss()
        }
    }
}

// MARK: - Models & helpers

private enum PickerPermission: Equatable {
    case loading, denied, limited, ready
}

private let pickerGreen = Color(red: 0.06, green: 0.78, blue: 0.35)

private struct PickerAlbum: Identifiable {
    let collection: PHAssetCollection
    var id: String { collection.localIdentifier }
    var title: String { collection.localizedTitle ?? "相册" }
}

/// Reloads the grid when the photo library changes (e.g. the user added photos
/// through the system "limited" picker).
private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: () -> Void
    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
        PHPhotoLibrary.shared().register(self)
    }
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async(execute: onChange)
    }
    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }
}

/// One selectable thumbnail cell.
private struct PickerGridCell: View {
    let asset: PHAsset
    let sequence: Int?
    let isSelectable: Bool
    let imageManager: PHCachingImageManager
    let onTapCircle: () -> Void
    let onTapThumbnail: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            Color(uiColor: .systemGray5)
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(perform: onTapThumbnail)
        .overlay(alignment: .topTrailing) {
            if isSelectable { selectionCircle }
        }
        .overlay(alignment: .bottomLeading) { bottomBadges }
        .onAppear(perform: loadThumbnail)
    }

    private var selectionCircle: some View {
        PickerSelectionCircle(sequence: sequence, action: onTapCircle)
            .padding(2)
    }

    @ViewBuilder private var bottomBadges: some View {
        HStack(spacing: 4) {
            if asset.mediaType == .video {
                Text(TimeText.mmss(asset.duration))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
            }
            if asset.mediaSubtypes.contains(.photoLive) {
                Text("实况")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
            }
        }
        .padding(4)
    }

    private func loadThumbnail() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let target = CGSize(width: 200, height: 200)
        _ = imageManager.requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: options) { image, _ in
            guard let image else { return }
            DispatchQueue.main.async { thumbnail = image }
        }
    }
}

/// Numbered selection circle shared by the grid and the full-screen preview.
private struct PickerSelectionCircle: View {
    let sequence: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(sequence != nil ? pickerGreen : Color.black.opacity(0.35))
                Circle().strokeBorder(Color.white, lineWidth: 1.5)
                if let sequence {
                    Text("\(sequence)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 24, height: 24)
            .frame(width: 42, height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Full-screen preview

/// Which assets the full-screen preview pages through, and where it starts.
private struct PickerPreviewContext {
    let assets: [PHAsset]
    let startIndex: Int
}

/// WeChat-style full-screen preview: paging through `displayAssets`, with a
/// top bar (`<` back + numbered selection circle), a bottom bar
/// (编辑 / 原图 / 实况(when Live Photo) / 发送(N)), and single-tap to hide/show
/// the bars. Selection, 原图, edited images and 实况 are shared with the grid
/// through bindings.
private struct AlbumPreviewView: View {
    let displayAssets: [PHAsset]
    let startIndex: Int
    @Binding var selected: [PHAsset]
    @Binding var sendOriginal: Bool
    @Binding var editedImages: [String: UIImage]
    @Binding var liveEnabled: [String: Bool]
    let imageManager: PHCachingImageManager
    let onSend: () -> Void
    let onClose: () -> Void

    @State private var currentID: String?
    @State private var chromeVisible = true
    @State private var editorInput: EditorInput?
    /// Vertical translation of the preview while it is pulled down to shrink
    /// back into the grid.
    @State private var dismissDragY: CGFloat = 0
    /// Asset the current edge-swipe gesture began on, so a page that settles
    /// onto the first image mid-swipe cannot turn a normal page-back into a
    /// close.
    @State private var edgeSwipeStartAssetID: String?

    private struct EditorInput: Identifiable {
        let asset: PHAsset
        let image: UIImage
        var id: String { asset.localIdentifier }
    }

    init(displayAssets: [PHAsset],
         startIndex: Int,
         selected: Binding<[PHAsset]>,
         sendOriginal: Binding<Bool>,
         editedImages: Binding<[String: UIImage]>,
         liveEnabled: Binding<[String: Bool]>,
         imageManager: PHCachingImageManager,
         onSend: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.displayAssets = displayAssets
        self.startIndex = startIndex
        self._selected = selected
        self._sendOriginal = sendOriginal
        self._editedImages = editedImages
        self._liveEnabled = liveEnabled
        self.imageManager = imageManager
        self.onSend = onSend
        self.onClose = onClose
        let initial = displayAssets.indices.contains(startIndex)
            ? displayAssets[startIndex].localIdentifier
            : displayAssets.first?.localIdentifier
        self._currentID = State(initialValue: initial)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            pager.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
            .opacity(chromeVisible ? 1 : 0)
            .allowsHitTesting(chromeVisible)
            .animation(.easeInOut(duration: 0.18), value: chromeVisible)
        }
        // Pull-down-to-shrink: the whole preview follows the finger down and
        // shrinks/fades, revealing the grid behind; past the threshold it pops
        // back to the grid, otherwise it springs back.
        .scaleEffect(dragScale)
        .offset(y: dismissDragY)
        .opacity(dragOpacity)
        .simultaneousGesture(verticalDismissDrag)
        .simultaneousGesture(edgeSwipeBackDrag)
        .statusBarHidden()
        .fullScreenCover(item: $editorInput) { input in
            ImageEditorView(image: input.image, confirmTitle: "完成",
                            onFinish: { edited in
                                editedImages[input.asset.localIdentifier] = edited
                                // Editing produces a static image, so the
                                // paired video no longer matches: auto-off 实况.
                                liveEnabled.removeValue(forKey: input.asset.localIdentifier)
                                editorInput = nil
                            },
                            onCancel: { editorInput = nil })
        }
    }

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(displayAssets, id: \.localIdentifier) { asset in
                    PreviewPage(asset: asset,
                                editedImage: editedImages[asset.localIdentifier],
                                imageManager: imageManager,
                                onToggleChrome: { chromeVisible.toggle() })
                        .containerRelativeFrame(.horizontal)
                        .id(asset.localIdentifier)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentID)
        .scrollIndicators(.hidden)
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            Button { onClose() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")

            Spacer()

            if let asset = currentAsset, isSelectable(asset) {
                PickerSelectionCircle(sequence: selectionIndex(for: asset)) { toggle(asset) }
                    .padding(.trailing, 4)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.6), Color.clear],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            Button { startEditing() } label: {
                Text("编辑")
                    .font(.system(size: 15))
                    .foregroundStyle(canEdit ? Color.white : Color.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(!canEdit)
            .accessibilityLabel("编辑")

            Button { sendOriginal.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: sendOriginal ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(sendOriginal ? pickerGreen : Color.white.opacity(0.8))
                    Text("原图")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            if let asset = currentAsset, isLivePhoto(asset) {
                Button { toggleLive() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isLiveOn(asset) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(isLiveOn(asset) ? pickerGreen : Color.white.opacity(0.8))
                        Text("实况")
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("实况")
            }

            sendButton
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Color.black.opacity(0.9))
    }

    private var sendButton: some View {
        Button { onSend() } label: {
            Text(selected.isEmpty ? "发送" : "发送(\(selected.count))")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected.isEmpty ? Color.white.opacity(0.5) : Color.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected.isEmpty ? Color.white.opacity(0.15) : pickerGreen,
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(selected.isEmpty)
        .accessibilityLabel(selected.isEmpty ? "发送" : "发送\(selected.count)张")
    }

    // MARK: Preview helpers

    /// Shrink factor while the preview is being pulled down.
    private var dragScale: CGFloat {
        guard dismissDragY > 0 else { return 1 }
        return max(0.45, 1 - dismissDragY / (UIScreen.main.bounds.height * 1.6))
    }

    /// Fade-out while the preview is being pulled down (reveals the grid).
    private var dragOpacity: Double {
        guard dismissDragY > 0 else { return 1 }
        let progress = dismissDragY / (UIScreen.main.bounds.height * 0.85)
        return Double(max(0, 1 - progress))
    }

    /// Pull the image down to shrink it back into the grid, like the
    /// `ImageViewer` drag-to-dismiss: the preview tracks the finger, and on
    /// release past the threshold (or a fast flick) it returns to the grid.
    private var verticalDismissDrag: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                let horizontal = abs(value.translation.width)
                guard value.translation.height > 16,
                      value.translation.height > horizontal * 1.5 else {
                    if dismissDragY != 0 { dismissDragY = 0 }
                    return
                }
                dismissDragY = value.translation.height
            }
            .onEnded { value in
                let shouldClose = dismissDragY > 150 || (dismissDragY > 50 && value.predictedEndTranslation.height > 300)
                if shouldClose {
                    dismissDragY = 0
                    onClose()
                } else {
                    withAnimation(.easeOut(duration: 0.22)) { dismissDragY = 0 }
                }
            }
    }

    /// Swipe right from the screen's left edge to return to the grid. Only
    /// fires when the gesture started on the first asset, so swiping back from
    /// a later page keeps paging instead of closing.
    private var edgeSwipeBackDrag: some Gesture {
        // Minimum distance keeps button/tap handling crisp; a swipe is longer.
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if edgeSwipeStartAssetID == nil {
                    edgeSwipeStartAssetID = currentAsset?.localIdentifier
                }
            }
            .onEnded { value in
                defer { edgeSwipeStartAssetID = nil }
                guard value.startLocation.x < 30 else { return }
                guard value.translation.width > 70 || value.predictedEndTranslation.width > 160 else { return }
                guard let startedID = edgeSwipeStartAssetID,
                      displayAssets.first?.localIdentifier == startedID else { return }
                onClose()
            }
    }

    private var currentAsset: PHAsset? {
        if let id = currentID, let asset = displayAssets.first(where: { $0.localIdentifier == id }) {
            return asset
        }
        return displayAssets.indices.contains(startIndex) ? displayAssets[startIndex] : displayAssets.first
    }

    private var canEdit: Bool {
        guard let asset = currentAsset else { return false }
        return isSelectable(asset)
    }

    private func isSelectable(_ asset: PHAsset) -> Bool {
        asset.mediaType == .image
    }

    private func selectionIndex(for asset: PHAsset) -> Int? {
        guard let index = selected.firstIndex(where: { $0.localIdentifier == asset.localIdentifier }) else {
            return nil
        }
        return index + 1
    }

    private func toggle(_ asset: PHAsset) {
        guard isSelectable(asset) else { return }
        if let index = selected.firstIndex(where: { $0.localIdentifier == asset.localIdentifier }) {
            selected.remove(at: index)
        } else {
            selected.append(asset)
        }
    }

    private func isLivePhoto(_ asset: PHAsset) -> Bool {
        asset.mediaType == .image && asset.mediaSubtypes.contains(.photoLive)
    }

    private func isLiveOn(_ asset: PHAsset) -> Bool {
        liveEnabled[asset.localIdentifier] ?? false
    }

    private func toggleLive() {
        guard let asset = currentAsset, isLivePhoto(asset) else { return }
        let id = asset.localIdentifier
        if liveEnabled[id] == true {
            liveEnabled.removeValue(forKey: id)
        } else {
            liveEnabled[id] = true
        }
    }

    private func startEditing() {
        guard let asset = currentAsset, isSelectable(asset) else { return }
        let base = editedImages[asset.localIdentifier]
        Task { @MainActor in
            // `?? await …` is not allowed (the `??` autoclosure is not async),
            // so resolve the edited/loaded image in two explicit branches.
            let image: UIImage?
            if let base {
                image = base
            } else {
                image = await loadFullImage(for: asset, manager: imageManager)
            }
            guard let image else { return }
            editorInput = EditorInput(asset: asset, image: image)
        }
    }
}

/// One full-screen page: loads (or shows the edited) image for its asset.
private struct PreviewPage: View {
    let asset: PHAsset
    let editedImage: UIImage?
    let imageManager: PHCachingImageManager
    let onToggleChrome: () -> Void

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.clear
            if let editedImage {
                Image(uiImage: editedImage)
                    .resizable()
                    .scaledToFit()
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
            if asset.mediaType == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleChrome)
        .task(id: asset.localIdentifier) {
            guard editedImage == nil else { return }
            let maxDimension = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale
            image = await loadImage(for: asset, manager: imageManager, maxDimension: maxDimension)
        }
    }
}

// MARK: - Asset → send data

private func loadSendData(for asset: PHAsset,
                          manager: PHCachingImageManager,
                          sendOriginal: Bool) async -> (data: Data, mime: String, name: String)? {
    if sendOriginal {
        guard let data = await loadOriginalData(for: asset, manager: manager), !data.isEmpty else { return nil }
        let mime = MediaLoader.imageMime(from: data)
        return (data, mime, MediaLoader.generatedName(prefix: "照片", mime: mime))
    }
    guard let image = await loadImage(for: asset, manager: manager, maxDimension: 2048),
          let data = compressToJPEG(image, maxDimension: 2048) else { return nil }
    return (data, "image/jpeg", MediaLoader.generatedName(prefix: "照片", mime: "image/jpeg"))
}

/// Original bytes of the asset (the still frame for a Live Photo), preserving
/// the container (HEIC/JPEG/PNG) via magic-byte sniffing on the other side.
private func loadOriginalData(for asset: PHAsset, manager: PHCachingImageManager) async -> Data? {
    await withCheckedContinuation { continuation in
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        _ = manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
            continuation.resume(returning: data)
        }
    }
}

private func loadImage(for asset: PHAsset,
                       manager: PHCachingImageManager,
                       maxDimension: CGFloat) async -> UIImage? {
    await withCheckedContinuation { continuation in
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        let size = CGSize(width: maxDimension, height: maxDimension)
        _ = manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, _ in
            continuation.resume(returning: image)
        }
    }
}

/// Full-resolution image for the editor. The editor downscales to its own
/// working resolution (`EditorImageOps.prepare`), so we request the largest
/// available image.
private func loadFullImage(for asset: PHAsset, manager: PHCachingImageManager) async -> UIImage? {
    await withCheckedContinuation { continuation in
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        _ = manager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize,
                                 contentMode: .aspectFit, options: options) { image, _ in
            continuation.resume(returning: image)
        }
    }
}

/// Extract the Live Photo paired video (a MOV) for `asset` and transcode it to
/// MP4 via `AVAssetExportSession`. Returns the MP4 temp URL (caller removes it),
/// or nil when the asset has no paired video or the export fails. The MOV is
/// streamed to a temp file rather than loaded whole into memory.
private func loadLivePhotoVideoMP4(for asset: PHAsset) async -> URL? {
    let resources = PHAssetResource.assetResources(for: asset)
    guard let video = resources.first(where: { $0.type == .pairedVideo }) else { return nil }
    let ext = (video.originalFilename as NSString).pathExtension.lowercased()
    let rawURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("live-\(UUID().uuidString).\(ext.isEmpty ? "mov" : ext)")

    let written: Bool = await withCheckedContinuation { continuation in
        FileManager.default.createFile(atPath: rawURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: rawURL) else {
            continuation.resume(returning: false)
            return
        }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        PHAssetResourceManager.default().requestData(for: video, options: options) { chunk in
            try? handle.write(contentsOf: chunk)
        } completionHandler: { error in
            try? handle.close()
            continuation.resume(returning: error == nil)
        }
    }
    guard written else {
        try? FileManager.default.removeItem(at: rawURL)
        return nil
    }
    let mp4 = await MediaLoader.transcodeToMP4(from: rawURL)
    try? FileManager.default.removeItem(at: rawURL)
    return mp4
}

private func compressToJPEG(_ image: UIImage, maxDimension: CGFloat) -> Data? {
    let maxSide = max(image.size.width, image.size.height)
    var output = image
    if maxSide > maxDimension {
        let scale = maxDimension / maxSide
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        output = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
    return output.jpegData(compressionQuality: 0.85)
}

extension AlbumPickerView {
    /// Topmost presented view controller, used to host the system limited picker.
    static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
