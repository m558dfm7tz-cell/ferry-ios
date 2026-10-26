import SwiftUI
import Photos
import UIKit

/// WeChat-style photo picker, presented from the composer's 相册 button.
///
/// This build ships the grid page only:
/// - album-switch capsule (top) + a tap-away album list,
/// - a 4-column thumbnail grid sorted newest-first,
/// - a sequence-numbered selection circle on each selectable cell,
/// - per-cell video duration and Live Photo ("实况") badges,
/// - a bottom bar of 预览 / 原图 / 发送(N), with 原图 on by default,
/// - limited / denied photo-library permission handling, and
/// - `PHCachingImageManager` thumbnail caching.
///
/// Sending reuses the existing `Uploader.enqueue` path for still images:
/// original bytes when 原图 is checked, otherwise a downscaled JPEG. Videos and
/// the full-screen 大图预览 (tap-to-preview, swipe, edit, Live Photo switch)
/// are a later step and are deliberately not wired here.
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
    @State private var imageManager = PHCachingImageManager()
    @State private var libraryObserver: LibraryChangeObserver?

    private let columns = [GridItem](repeating: GridItem(.flexible(), spacing: 1), count: 4)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
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
        .statusBarHidden()
        .task { await resolvePermission() }
        .alert("发送失败", isPresented: sendErrorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(sendError ?? "")
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
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            Button { dismiss() } label: {
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
        Button { showAlbumList = true } label: {
            HStack(spacing: 6) {
                Text(currentAlbum?.title ?? "最近项目")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                Image(systemName: "chevron.down")
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
                        onTapCircle: { toggle(asset) }
                    )
                }
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            // 大图预览 is the next step; the button is already laid out and
            // greys out while nothing is selected, matching the spec.
            Button {
                // Preview page is wired in a later build.
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
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { showAlbumList = false }

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

    // MARK: - Send

    private func send() {
        guard !selected.isEmpty, !isSending else { return }
        isSending = true
        let picks = selected
        let original = sendOriginal
        Task { @MainActor in
            for asset in picks {
                guard let loaded = await loadSendData(for: asset, manager: imageManager, sendOriginal: original) else {
                    continue
                }
                if let error = model.uploader.enqueue(data: loaded.data, name: loaded.name, mediaType: loaded.mime) {
                    sendError = error
                    isSending = false
                    return
                }
            }
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
        .overlay(alignment: .topTrailing) {
            if isSelectable { selectionCircle }
        }
        .overlay(alignment: .bottomLeading) { bottomBadges }
        .onAppear(perform: loadThumbnail)
    }

    private var selectionCircle: some View {
        Button(action: onTapCircle) {
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
        }
        .buttonStyle(.plain)
        .padding(4)
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
