import SwiftUI
import UIKit

/// Full-screen image viewer: single tap closes (waits for double-tap to fail),
/// double tap zooms, pinch zooms, and a vertical swipe drags the image away to
/// dismiss (snapping back if the drag is too short). The file name is a large
/// headline at the top; save/share round actions sit at the bottom-right.
struct ImageViewer: View {
    let image: UIImage
    let name: String
    let mediaType: String
    let load: () async -> Data?
    /// Opens the grid of every image and video in this chat. Nil hides the
    /// entry (e.g. when the viewer is already opened from that grid).
    var onOpenGallery: (() -> Void)? = nil
    /// Called with the edited copy when the user finishes editing from the
    /// viewer. Nil hides the 编辑 entry.
    var onEditFinished: ((UIImage) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var showToast = false
    @State private var toastText = ""
    @State private var showOCR = false
    @State private var showEditor = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZoomableImageView(image: image, onDismiss: { dismiss() }).ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            Text(name).font(.headline).foregroundStyle(.white.opacity(0.92))
                .lineLimit(2).padding(20)
        }
        .overlay(alignment: .bottomTrailing) {
            AttachmentActions(name: name, mediaType: mediaType, load: load, tint: .white,
                              onToast: { text in flashToast(text) },
                              onOpenGallery: onOpenGallery)
                .padding(20)
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 14) {
                if onEditFinished != nil {
                    Button { showEditor = true } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 22, weight: .medium))
                            .frame(width: 52, height: 52)
                            .background(Color.white.opacity(0.15), in: Circle())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("编辑")
                    .accessibilityIdentifier("viewer-edit")
                }
                Button { showOCR = true } label: {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 22, weight: .medium))
                        .frame(width: 52, height: 52)
                        .background(Color.white.opacity(0.15), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("识别文字")
            }
            .padding(20)
        }
        .overlay { if showToast { toastView } }
        .sheet(isPresented: $showOCR) {
            OCRView(image: image, name: name)
        }
        .fullScreenCover(isPresented: $showEditor) {
            ImageEditorView(image: image, confirmTitle: "发送",
                            onFinish: { edited in
                                showEditor = false
                                onEditFinished?(edited)
                                dismiss()
                            },
                            onCancel: { showEditor = false })
        }
        .statusBarHidden()
    }

    private var toastView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(toastText).foregroundStyle(.white).font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.black.opacity(0.85), in: Capsule())
        .transition(.opacity)
    }

    private func flashToast(_ text: String) {
        toastText = text
        withAnimation(.easeIn(duration: 0.15)) { showToast = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.15)) { showToast = false }
        }
    }
}

/// A grid of every image message; tapping one opens the full-screen viewer.
struct ImageGridView: View {
    let messages: [MessagePayload]
    let images: [String: UIImage?]
    let loadImage: (MessagePayload) async -> Void
    let loadFile: (MessagePayload) async -> Data?

    @Environment(\.dismiss) private var dismiss
    @State private var selected: MessagePayload?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 3)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if messages.isEmpty {
                    ContentUnavailableView("暂无图片", systemImage: "photo.on.rectangle")
                        .padding(.top, 120)
                }
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(messages) { message in
                        cell(for: message)
                    }
                }
                .padding(3)
            }
            .navigationTitle("图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .fullScreenCover(item: $selected) { message in
            if case .some(.some(let decoded)) = images[message.id] {
                ImageViewer(image: decoded, name: message.file?.name ?? "图片",
                            mediaType: message.file?.mediaType ?? "image/jpeg",
                            load: { await loadFile(message) })
            }
        }
    }

    @ViewBuilder private func cell(for message: MessagePayload) -> some View {
        if case .some(.some(let decoded)) = images[message.id] {
            Image(uiImage: decoded)
                .resizable().scaledToFill()
                .frame(width: 104, height: 104)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { selected = message }
        } else {
            RoundedRectangle(cornerRadius: 0)
                .fill(Color(.systemGray5))
                .frame(width: 104, height: 104)
                .overlay { ProgressView() }
                .task { await loadImage(message) }
        }
    }
}

/// Pinch/pan/double-tap zoom + single-tap close + swipe-to-dismiss wrapper.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> ZoomableImageUIView {
        let view = ZoomableImageUIView()
        view.image = image
        view.onDismiss = onDismiss
        return view
    }

    func updateUIView(_ uiView: ZoomableImageUIView, context: Context) {
        if uiView.image !== image { uiView.image = image }
        uiView.onDismiss = onDismiss
    }
}

final class ZoomableImageUIView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var onDismiss: (() -> Void)?

    var image: UIImage? {
        get { imageView.image }
        set {
            imageView.image = newValue
            setNeedsLayout()
        }
    }

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var dismissPan: UIPanGestureRecognizer!

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = .black
        // At zoom scale 1 the image fits exactly, so pan-scrolling is disabled
        // and the vertical dismiss pan owns dragging. Scrolling is re-enabled
        // once zoomed in (see scrollViewDidZoom).
        scrollView.isScrollEnabled = false
        scrollView.addSubview(imageView)
        addSubview(scrollView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        dismissPan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        dismissPan.delegate = self
        scrollView.addGestureRecognizer(dismissPan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        imageView.frame = scrollView.bounds
        scrollView.contentSize = imageView.frame.size
        centerContent()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        scrollView.isScrollEnabled = scrollView.zoomScale > 1.01
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === dismissPan {
            // Drag-dismiss is disabled while zoomed so pinch/pan keeps working.
            guard scrollView.zoomScale <= 1.01 else { return false }
            let velocity = dismissPan.velocity(in: self)
            // Let the gallery handle left/right paging; dismiss vertically only.
            return abs(velocity.y) > abs(velocity.x) * 1.25
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPan || otherGestureRecognizer === dismissPan else { return false }
        return scrollView.zoomScale <= 1.01
    }

    private func centerContent() {
        let boundsSize = scrollView.bounds.size
        var frame = imageView.frame
        if frame.size.width < boundsSize.width {
            frame.origin.x = (boundsSize.width - frame.size.width) / 2
        } else {
            frame.origin.x = 0
        }
        if frame.size.height < boundsSize.height {
            frame.origin.y = (boundsSize.height - frame.size.height) / 2
        } else {
            frame.origin.y = 0
        }
        imageView.frame = frame
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        onDismiss?()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let width = scrollView.bounds.width / 2.5
            let height = scrollView.bounds.height / 2.5
            let rect = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
            scrollView.zoom(to: rect, animated: true)
        }
    }

    @objc private func handleDismissPan(_ pan: UIPanGestureRecognizer) {
        guard scrollView.zoomScale <= 1.01 else { return }
        let translation = pan.translation(in: self)
        switch pan.state {
        case .changed:
            scrollView.transform = CGAffineTransform(translationX: 0, y: translation.y)
            let progress = min(1, abs(translation.y) / 240)
            imageView.alpha = 1 - progress * 0.75
        case .ended, .cancelled, .failed:
            let velocity = pan.velocity(in: self).y
            let shouldDismiss = abs(translation.y) > 120 || abs(velocity) > 900
            if shouldDismiss {
                onDismiss?()
            } else {
                UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut], animations: {
                    self.scrollView.transform = .identity
                    self.imageView.alpha = 1
                })
            }
        default:
            break
        }
    }
}
