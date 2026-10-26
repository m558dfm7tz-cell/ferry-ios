import CoreImage
import SwiftUI
import UIKit

// MARK: - Annotation model

enum EditorAnnotationKind {
    case pen
    case arrow
    case mosaic
    case text
}

/// One annotation added on top of the working image.
///
/// `points` are **normalized** (0...1) against the working image, so the same
/// annotation renders identically in the on-screen preview and in the
/// full-resolution export. `thickness` is a fraction of the image **width** for
/// pen/arrow/mosaic and a fraction of the image **height** for text (where it
/// is the font size).
struct EditorAnnotation {
    var kind: EditorAnnotationKind
    var points: [CGPoint]
    var text: String
    var colorIndex: Int
    var thickness: CGFloat
}

/// Fixed palette: indices are stored in annotations, so they stay `Equatable`
/// and stable across renders.
enum EditorPalette {
    static let colors: [UIColor] = [
        .white, .black, .systemRed, .systemOrange,
        .systemYellow, .systemGreen, .systemBlue, .systemPurple
    ]

    static func color(_ index: Int) -> UIColor {
        guard colors.indices.contains(index) else { return .systemRed }
        return colors[index]
    }

    static func swiftUIColor(_ index: Int) -> Color {
        Color(uiColor: color(index))
    }
}

// MARK: - Painting

/// Draws annotations into the **current** UIKit graphics context. The same call
/// is used by the on-screen canvas (`draw(_:)`) and by the export renderer
/// (`UIGraphicsImageRenderer`), so preview and result can never diverge.
enum AnnotationPainter {
    static func paint(_ items: [EditorAnnotation], pixellated: UIImage?, in size: CGSize) {
        for item in items {
            switch item.kind {
            case .mosaic:
                paintMosaic(item, pixellated: pixellated, in: size)
            case .pen:
                paintPen(item, in: size)
            case .arrow:
                paintArrow(item, in: size)
            case .text:
                paintText(item, in: size)
            }
        }
    }

    private static func paintMosaic(_ item: EditorAnnotation, pixellated: UIImage?, in size: CGSize) {
        guard let pixellated, let path = outlinePath(for: item, in: size) else { return }
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        path.addClip()
        pixellated.draw(in: CGRect(origin: .zero, size: size))
        context.restoreGState()
    }

    private static func paintPen(_ item: EditorAnnotation, in size: CGSize) {
        guard let path = strokePath(for: item, in: size) else { return }
        let color = EditorPalette.color(item.colorIndex)
        let width = max(1, item.thickness * size.width)
        if item.points.count <= 1 {
            color.setFill()
            path.fill()
        } else {
            color.setStroke()
            path.lineWidth = width
            path.stroke()
        }
    }

    private static func paintArrow(_ item: EditorAnnotation, in size: CGSize) {
        guard item.points.count >= 2 else { return }
        let a = CGPoint(x: item.points[0].x * size.width, y: item.points[0].y * size.height)
        let b = CGPoint(x: item.points[1].x * size.width, y: item.points[1].y * size.height)
        let dx = b.x - a.x
        let dy = b.y - a.y
        guard dx * dx + dy * dy > 1 else { return }
        let color = EditorPalette.color(item.colorIndex)
        let width = max(1, item.thickness * size.width)
        let line = UIBezierPath()
        line.move(to: a)
        line.addLine(to: b)
        line.lineWidth = width
        line.lineCapStyle = .round
        color.setStroke()
        line.stroke()

        let angle = atan2(dy, dx)
        let head = max(width * 3.2, 12)
        let spread = CGFloat.pi / 7
        let triangle = UIBezierPath()
        triangle.move(to: b)
        triangle.addLine(to: CGPoint(x: b.x - head * cos(angle - spread), y: b.y - head * sin(angle - spread)))
        triangle.addLine(to: CGPoint(x: b.x - head * cos(angle + spread), y: b.y - head * sin(angle + spread)))
        triangle.close()
        color.setFill()
        triangle.fill()
    }

    private static func paintText(_ item: EditorAnnotation, in size: CGSize) {
        guard let anchor = item.points.first else { return }
        let text = item.text
        guard !text.isEmpty else { return }
        let fontSize = max(10, item.thickness * size.height)
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let fill = EditorPalette.color(item.colorIndex)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        let luminance = fill.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            ? 0.299 * red + 0.587 * green + 0.114 * blue
            : 0
        // Outline in the opposite brightness so text stays readable on any photo.
        let outline: UIColor = luminance > 0.6 ? .black : .white
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fill,
            .strokeColor: outline,
            .strokeWidth: -3,
            .paragraphStyle: style
        ]
        let measured = (text as NSString).size(withAttributes: attributes)
        var origin = CGPoint(x: anchor.x * size.width - measured.width / 2,
                             y: anchor.y * size.height - measured.height / 2)
        origin.x = min(max(0, origin.x), max(0, size.width - measured.width))
        origin.y = min(max(0, origin.y), max(0, size.height - measured.height))
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }

    /// The poly-line (or dot) of an annotation, in the given pixel/point size.
    private static func strokePath(for item: EditorAnnotation, in size: CGSize) -> UIBezierPath? {
        guard !item.points.isEmpty else { return nil }
        let path = UIBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        if item.points.count == 1 {
            let center = CGPoint(x: item.points[0].x * size.width, y: item.points[0].y * size.height)
            let radius = max(1, item.thickness * size.width / 2)
            path.addArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
            path.close()
            return path
        }
        for (index, point) in item.points.enumerated() {
            let mapped = CGPoint(x: point.x * size.width, y: point.y * size.height)
            if index == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
        }
        return path
    }

    /// The stroked outline turned into a fillable path, used as the mosaic clip.
    /// `addClip()` clips to the *enclosed* area, so a thin poly-line would clip
    /// to nothing without this conversion.
    private static func outlinePath(for item: EditorAnnotation, in size: CGSize) -> UIBezierPath? {
        guard let base = strokePath(for: item, in: size) else { return nil }
        // A single tap already produces a closed oval, which clips as a disc.
        if item.points.count <= 1 { return base }
        let width = max(2, item.thickness * size.width)
        let stroked = base.cgPath.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 2)
        return UIBezierPath(cgPath: stroked)
    }
}

// MARK: - Image operations

enum EditorImageOps {
    /// Editing resolution cap. Photos are downscaled to this longest side so a
    /// full-res 48 MP image never has to be kept several times in memory.
    static let maxDimension: CGFloat = 3200

    private static let ciContext = CIContext()

    static func pixelSize(of image: UIImage) -> CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    /// Normalize an arbitrary `UIImage` (any orientation/scale) into an
    /// orientation-up, scale-1 bitmap bounded by `maxDimension`.
    static func prepare(_ image: UIImage) -> UIImage {
        let pixel = pixelSize(of: image)
        guard pixel.width > 0, pixel.height > 0 else { return image }
        let factor = max(pixel.width, pixel.height) <= maxDimension
            ? 1
            : maxDimension / max(pixel.width, pixel.height)
        let size = CGSize(width: max(1, (pixel.width * factor).rounded()),
                          height: max(1, (pixel.height * factor).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func rotated(_ image: UIImage, clockwise: Bool) -> UIImage {
        let size = pixelSize(of: image)
        let target = CGSize(width: size.height, height: size.width)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: target.width / 2, y: target.height / 2)
            cg.rotate(by: clockwise ? .pi / 2 : -.pi / 2)
            cg.translateBy(x: -size.width / 2, y: -size.height / 2)
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Crop by a normalized rect against the image's own pixel grid. The base
    /// image is always orientation-up/scale-1, so `cgImage` pixels and
    /// `size * scale` pixels agree here.
    static func cropped(_ image: UIImage, normalizedRect rect: CGRect) -> UIImage {
        let pixel = pixelSize(of: image)
        guard pixel.width > 1, pixel.height > 1, let cgImage = image.cgImage else { return image }
        var crop = CGRect(x: rect.minX * pixel.width,
                          y: rect.minY * pixel.height,
                          width: rect.width * pixel.width,
                          height: rect.height * pixel.height)
            .integral
            .intersection(CGRect(origin: .zero, size: pixel))
        guard crop.width >= 1, crop.height >= 1 else { return image }
        crop = crop.integral
        guard let cropped = cgImage.cropping(to: crop) else { return image }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }

    /// Whole-image `CIPixellate` pass used as the mosaic source. Blocks are
    /// sized relative to the image so the effect looks the same on every photo.
    static func pixellated(_ image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let extent = input.extent
        guard extent.width > 1, extent.height > 1 else { return nil }
        let block = min(80, max(10, min(extent.width, extent.height) / 45))
        let output = input.applyingFilter("CIPixellate", parameters: [
            kCIInputScaleKey: block,
            kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY)
        ])
        guard let cgImage = ciContext.createCGImage(output, from: extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    /// Bake every annotation into the image at full resolution.
    static func flattened(image: UIImage, annotations: [EditorAnnotation], pixellated: UIImage?) -> UIImage {
        guard !annotations.isEmpty else { return image }
        let size = pixelSize(of: image)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
            AnnotationPainter.paint(annotations, pixellated: pixellated, in: size)
        }
    }
}

/// Encoding of an edited image for sending / saving.
enum EditedImageExport {
    /// PNG is only kept when the source was PNG (to preserve transparency);
    /// everything else — including HEIC originals — is re-encoded as JPEG.
    static func encode(_ image: UIImage, originalMediaType: String) -> (data: Data, mime: String)? {
        if originalMediaType == "image/png", let data = image.pngData() {
            return (data, "image/png")
        }
        guard let data = image.jpegData(compressionQuality: 0.92) else { return nil }
        return (data, "image/jpeg")
    }

    static func name(for originalName: String, mime: String) -> String {
        let base = (originalName as NSString).deletingPathExtension
        let stem = base.isEmpty ? "编辑" : base
        return "\(stem)_编辑.\(MediaLoader.fileExtension(mime: mime))"
    }
}

// MARK: - Editor state

/// Working state of one editing session.
///
/// `base` holds the pixels after every destructive step (rotation, crop, and
/// every flatten caused by them); `annotations` holds everything drawn since the
/// last flatten. Rotating or cropping flattens the annotations into `base`
/// first, which keeps every recorded normalized point valid.
///
/// Deliberately **not** `@MainActor`: the model is built inside
/// `ImageEditorView.init`, which is not main-actor isolated. It is only ever
/// touched from the editor's own UI, i.e. on the main thread in practice.
@Observable
final class ImageEditorModel {
    private struct Snapshot {
        let base: UIImage
        let annotations: [EditorAnnotation]
    }

    private static let historyLimit = 6

    private let preparedOriginal: UIImage
    private(set) var base: UIImage
    private(set) var annotations: [EditorAnnotation] = []
    private var history: [Snapshot] = []
    private var pixellatedCache: UIImage?

    init(image: UIImage) {
        let prepared = EditorImageOps.prepare(image)
        self.preparedOriginal = prepared
        self.base = prepared
    }

    var canUndo: Bool { !history.isEmpty }

    var isUnmodified: Bool { annotations.isEmpty && base === preparedOriginal }

    /// Lazily built pixellated copy of `base`, shared by the preview and the
    /// export so they always agree.
    var pixellated: UIImage? {
        if let cached = pixellatedCache { return cached }
        let made = EditorImageOps.pixellated(base)
        pixellatedCache = made
        return made
    }

    func add(_ item: EditorAnnotation) {
        pushHistory()
        annotations.append(item)
    }

    func undo() {
        guard let last = history.popLast() else { return }
        base = last.base
        annotations = last.annotations
        pixellatedCache = nil
    }

    func reset() {
        guard !isUnmodified else { return }
        pushHistory()
        base = preparedOriginal
        annotations = []
        pixellatedCache = nil
    }

    func rotateClockwise() {
        pushHistory()
        base = EditorImageOps.rotated(flattened(), clockwise: true)
        annotations = []
        pixellatedCache = nil
    }

    func applyCrop(_ rect: CGRect) {
        pushHistory()
        base = EditorImageOps.cropped(flattened(), normalizedRect: rect)
        annotations = []
        pixellatedCache = nil
    }

    func flattened() -> UIImage {
        EditorImageOps.flattened(image: base, annotations: annotations, pixellated: pixellated)
    }

    private func pushHistory() {
        history.append(Snapshot(base: base, annotations: annotations))
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }
}

// MARK: - Canvas

final class EditorCanvasUIView: UIView {
    var baseImage: UIImage? {
        didSet { setNeedsDisplay() }
    }
    var annotations: [EditorAnnotation] = [] {
        didSet { setNeedsDisplay() }
    }
    var pixellatedImage: UIImage? {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        clearsContextBeforeDrawing = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Aspect-fit rect that centres `imageSize` inside `container`. This is the
    /// single source of truth for the on-screen offset/scale: the canvas draws
    /// with it and the SwiftUI layer uses the same math to map gestures, so a
    /// finger and the drawn stroke always agree — and the full-res export (which
    /// paints 1:1 into pixel space) stays consistent with the screen.
    static func aspectFitRect(for imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: (container.width - width) / 2,
                      y: (container.height - height) / 2,
                      width: width, height: height)
    }

    override func draw(_ rect: CGRect) {
        guard let baseImage, bounds.width > 0, bounds.height > 0 else { return }
        // Centre the image inside the view (aspect-fit) instead of blindly
        // filling `bounds`; the letterbox offset/scale are then applied to the
        // annotations so strokes land exactly where the finger is.
        let fitted = Self.aspectFitRect(for: baseImage.size, in: bounds.size)
        baseImage.draw(in: fitted)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.translateBy(x: fitted.minX, y: fitted.minY)
        AnnotationPainter.paint(annotations, pixellated: pixellatedImage, in: fitted.size)
        context.restoreGState()
    }
}

struct EditorCanvas: UIViewRepresentable {
    let base: UIImage
    let annotations: [EditorAnnotation]
    let pixellated: UIImage?

    func makeUIView(context: Context) -> EditorCanvasUIView {
        EditorCanvasUIView()
    }

    func updateUIView(_ view: EditorCanvasUIView, context: Context) {
        view.baseImage = base
        view.annotations = annotations
        view.pixellatedImage = pixellated
    }
}

// MARK: - Tools

enum EditorTool: String, CaseIterable, Identifiable {
    case crop
    case pen
    case arrow
    case text
    case mosaic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crop: return "裁剪"
        case .pen: return "画笔"
        case .arrow: return "箭头"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        }
    }

    var symbol: String {
        switch self {
        case .crop: return "crop"
        case .pen: return "pencil"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .mosaic: return "grid"
        }
    }

    var annotationKind: EditorAnnotationKind {
        switch self {
        case .crop, .pen: return .pen
        case .arrow: return .arrow
        case .text: return .text
        case .mosaic: return .mosaic
        }
    }
}

// MARK: - Crop overlay

/// `GeometryReader` crop overlay: dims the area outside the selection, shows
/// thirds grid lines and four corner handles, and supports drag-to-move plus
/// drag-a-corner-to-resize. `rect` is normalized against the image.
private struct CropOverlay: View {
    @Binding var rect: CGRect

    private static let minimumSize: CGFloat = 0.05
    private let handleSize: CGFloat = 30

    @State private var dragStart: CGRect?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let frame = CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                               width: rect.width * size.width, height: rect.height * size.height)
            let selection = rect
            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in
                    var path = Path(CGRect(origin: .zero, size: canvasSize))
                    path.addRect(CGRect(x: selection.minX * canvasSize.width,
                                        y: selection.minY * canvasSize.height,
                                        width: selection.width * canvasSize.width,
                                        height: selection.height * canvasSize.height))
                    context.fill(path, with: .color(Color.black.opacity(0.55)),
                                 style: FillStyle(eoFill: true))
                    let line = Color.white.opacity(0.5)
                    let fractions: [CGFloat] = [1.0 / 3.0, 2.0 / 3.0]
                    for fraction in fractions {
                        var vertical = Path()
                        vertical.move(to: CGPoint(x: frame.minX + frame.width * fraction, y: frame.minY))
                        vertical.addLine(to: CGPoint(x: frame.minX + frame.width * fraction, y: frame.maxY))
                        context.stroke(vertical, with: .color(line), lineWidth: 1)
                        var horizontal = Path()
                        horizontal.move(to: CGPoint(x: frame.minX, y: frame.minY + frame.height * fraction))
                        horizontal.addLine(to: CGPoint(x: frame.maxX, y: frame.minY + frame.height * fraction))
                        context.stroke(horizontal, with: .color(line), lineWidth: 1)
                    }
                }
                .allowsHitTesting(false)

                Rectangle()
                    .stroke(Color.white, lineWidth: 1.5)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .allowsHitTesting(false)

                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(Color.white)
                        .frame(width: handleSize, height: handleSize)
                        .shadow(radius: 2)
                        .offset(x: cornerPoint(index, frame: frame).x - handleSize / 2,
                                y: cornerPoint(index, frame: frame).y - handleSize / 2)
                        .gesture(cornerDrag(index: index, size: size))
                }
            }
            .contentShape(Rectangle())
            .gesture(moveDrag(size: size))
        }
    }

    private func cornerPoint(_ index: Int, frame: CGRect) -> CGPoint {
        switch index {
        case 0: return CGPoint(x: frame.minX, y: frame.minY)
        case 1: return CGPoint(x: frame.maxX, y: frame.minY)
        case 2: return CGPoint(x: frame.maxX, y: frame.maxY)
        default: return CGPoint(x: frame.minX, y: frame.maxY)
        }
    }

    private func moveDrag(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil { dragStart = rect }
                guard let start = dragStart, size.width > 0, size.height > 0 else { return }
                let dx = value.translation.width / size.width
                let dy = value.translation.height / size.height
                rect = CGRect(
                    x: min(max(0, start.minX + dx), max(0, 1 - start.width)),
                    y: min(max(0, start.minY + dy), max(0, 1 - start.height)),
                    width: start.width,
                    height: start.height
                )
            }
            .onEnded { _ in dragStart = nil }
    }

    private func cornerDrag(index: Int, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil { dragStart = rect }
                guard let start = dragStart, size.width > 0, size.height > 0 else { return }
                rect = Self.resized(start, corner: index, translation: value.translation, size: size)
            }
            .onEnded { _ in dragStart = nil }
    }

    private static func resized(_ start: CGRect, corner: Int,
                                translation: CGSize, size: CGSize) -> CGRect {
        let dx = translation.width / size.width
        let dy = translation.height / size.height
        var x0 = start.minX
        var y0 = start.minY
        var x1 = start.maxX
        var y1 = start.maxY
        switch corner {
        case 0: x0 += dx; y0 += dy
        case 1: x1 += dx; y0 += dy
        case 2: x1 += dx; y1 += dy
        default: x0 += dx; y1 += dy
        }
        x0 = min(max(x0, 0), 1)
        x1 = min(max(x1, 0), 1)
        y0 = min(max(y0, 0), 1)
        y1 = min(max(y1, 0), 1)
        var result = CGRect(x: min(x0, x1), y: min(y0, y1),
                            width: abs(x1 - x0), height: abs(y1 - y0))
        if result.width < minimumSize {
            result.size.width = minimumSize
            result.origin.x = min(result.origin.x, 1 - minimumSize)
        }
        if result.height < minimumSize {
            result.size.height = minimumSize
            result.origin.y = min(result.origin.y, 1 - minimumSize)
        }
        result.origin.x = max(0, result.origin.x)
        result.origin.y = max(0, result.origin.y)
        return result
    }
}

// MARK: - Editor screen

/// Full-screen image editor: 裁剪 / 旋转 / 画笔 / 箭头 / 文字 / 马赛克.
///
/// Editing always produces a **copy**; the original queued/received image is
/// untouched unless the user confirms. 发送 hands the edited image back through
/// `onFinish`, 保存到相册 writes it to the photo library.
struct ImageEditorView: View {
    @State private var model: ImageEditorModel
    let confirmTitle: String
    let onFinish: (UIImage) -> Void
    let onCancel: () -> Void

    @State private var tool: EditorTool = .pen
    @State private var isCropping = false
    @State private var cropRect = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
    @State private var colorIndex = 2
    @State private var penThickness: CGFloat = 0.008
    @State private var mosaicThickness: CGFloat = 0.035
    @State private var textScale: CGFloat = 0.05
    @State private var draft: EditorAnnotation?
    @State private var textAnchor: CGPoint?
    @State private var textValue = ""
    @FocusState private var textFocused: Bool
    @State private var showToast = false
    @State private var toastText = ""

    init(image: UIImage,
         confirmTitle: String = "发送",
         onFinish: @escaping (UIImage) -> Void,
         onCancel: @escaping () -> Void) {
        _model = State(initialValue: ImageEditorModel(image: image))
        self.confirmTitle = confirmTitle
        self.onFinish = onFinish
        self.onCancel = onCancel
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                canvasArea
                toolBar
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .overlay { if showToast { toastView } }
        .overlay { if textAnchor != nil { textComposer } }
        .statusBarHidden()
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { model.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.canUndo ? .white : .white.opacity(0.35))
            .disabled(!model.canUndo)
            .accessibilityLabel("撤销")
            .accessibilityIdentifier("editor-undo")

            Spacer()

            Text(isCropping ? "裁剪" : "编辑图片")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)

            Spacer()

            Button { model.reset() } label: {
                Text("重置")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(model.isUnmodified ? .white.opacity(0.35) : .white)
            }
            .buttonStyle(.plain)
            .disabled(model.isUnmodified)
            .accessibilityLabel("重置")
            .accessibilityIdentifier("editor-reset")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var canvasArea: some View {
        GeometryReader { geo in
            let frame = Self.fittedRect(for: model.base.size, in: geo.size)
            let layer = canvasLayer(frame: frame, container: geo.size)
            Group {
                if isCropping {
                    layer
                } else if tool == .text {
                    layer.gesture(textGesture(frame: frame))
                } else {
                    layer.gesture(drawGesture(frame: frame))
                }
            }
        }
        .padding(.horizontal, 12)
        .accessibilityIdentifier("editor-canvas")
    }

    /// The canvas fills the whole available area (so drags starting on the
    /// letterbox still register) while the image itself is centred inside it by
    /// `EditorCanvasUIView`'s own aspect-fit draw. `frame` is only needed here
    /// for the crop overlay, which lives in the SwiftUI layer.
    private func canvasLayer(frame: CGRect, container: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            EditorCanvas(base: model.base,
                         annotations: model.annotations + (draft.map { [$0] } ?? []),
                         pixellated: model.pixellated)
                .frame(width: container.width, height: container.height)
            if isCropping {
                CropOverlay(rect: $cropRect)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: container.width, height: container.height)
        .contentShape(Rectangle())
    }

    private var toolBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(EditorTool.allCases) { item in
                    Button { select(item) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 16, weight: .medium))
                            Text(item.title).font(.caption2)
                        }
                        .frame(width: 56, height: 48)
                        .background(isToolActive(item)
                                    ? Color.white.opacity(0.24)
                                    : Color.white.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundStyle(isToolActive(item) ? .yellow : .white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title)
                    .accessibilityIdentifier("editor-tool-\(item.rawValue)")
                }
                Button { model.rotateClockwise() } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "rotate.right")
                            .font(.system(size: 16, weight: .medium))
                        Text("旋转").font(.caption2)
                    }
                    .frame(width: 56, height: 48)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("旋转")
                .accessibilityIdentifier("editor-rotate")
            }

            if isCropping {
                HStack(spacing: 12) {
                    Button("取消") { exitCrop() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("全选") { cropRect = CGRect(x: 0, y: 0, width: 1, height: 1) }
                        .buttonStyle(.bordered)
                    Button("完成") { applyCrop() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("editor-crop-apply")
                }
                .tint(.yellow)
                .foregroundStyle(.white)
            } else {
                colorPicker
                if tool == .text {
                    HStack(spacing: 10) {
                        Text("大小").font(.caption).foregroundStyle(.white.opacity(0.8))
                        Slider(value: $textScale, in: 0.02...0.12)
                            .tint(.white)
                    }
                } else {
                    HStack(spacing: 10) {
                        Text("粗细").font(.caption).foregroundStyle(.white.opacity(0.8))
                        Slider(value: thicknessBinding, in: 0.004...0.06)
                            .tint(.white)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var colorPicker: some View {
        HStack(spacing: 10) {
            ForEach(0..<EditorPalette.colors.count, id: \.self) { index in
                Circle()
                    .fill(EditorPalette.swiftUIColor(index))
                    .frame(width: 26, height: 26)
                    .overlay {
                        Circle()
                            .stroke(index == colorIndex ? Color.yellow : Color.white.opacity(0.28),
                                    lineWidth: index == colorIndex ? 3 : 1)
                    }
                    .contentShape(Circle())
                    .onTapGesture { colorIndex = index }
                    .accessibilityLabel("颜色 \(index + 1)")
                    .accessibilityIdentifier("editor-color-\(index)")
            }
            Spacer(minLength: 0)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            capsuleButton("取消", systemImage: "xmark") { onCancel() }
                .accessibilityIdentifier("editor-cancel")

            capsuleButton("保存到相册", systemImage: "square.and.arrow.down") {
                Task { await self.saveToAlbum() }
            }
            .accessibilityIdentifier("editor-save")

            capsuleButton(confirmTitle, systemImage: "arrow.up", isPrimary: true) { finish() }
                .accessibilityIdentifier("editor-confirm")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
        .colorScheme(.dark)
    }

    /// Unified bottom-bar capsule button: icon + title in a capsule on a
    /// frosted-glass bar. Primary uses a solid yellow fill (matches the
    /// editor's existing accent); secondary uses a subtle white tint that
    /// reads as etched glass on the dark bar.
    private func capsuleButton(_ title: String,
                                systemImage: String,
                                isPrimary: Bool = false,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Capsule().fill(isPrimary ? Color.yellow : Color.white.opacity(0.14)))
                .foregroundStyle(isPrimary ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    private var textComposer: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { textAnchor = nil }
            VStack(spacing: 12) {
                Text("输入文字").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                TextField("文字", text: $textValue)
                    .textFieldStyle(.roundedBorder)
                    .focused($textFocused)
                    .submitLabel(.done)
                    .onSubmit { commitText() }
                HStack(spacing: 12) {
                    Button("取消") { textAnchor = nil }
                        .buttonStyle(.bordered)
                    Button("添加") { commitText() }
                        .buttonStyle(.borderedProminent)
                        .disabled(textValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 40)
        }
        .accessibilityIdentifier("editor-text-composer")
    }

    private var toastView: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(toastText).foregroundStyle(.white).font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.black.opacity(0.85), in: Capsule())
            .padding(.bottom, 90)
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    // MARK: Actions

    private func isToolActive(_ item: EditorTool) -> Bool {
        isCropping ? item == .crop : tool == item
    }

    private var thicknessBinding: Binding<CGFloat> {
        Binding(
            get: { tool == .mosaic ? mosaicThickness : penThickness },
            set: { value in
                if tool == .mosaic { mosaicThickness = value } else { penThickness = value }
            }
        )
    }

    private func select(_ item: EditorTool) {
        if item == .crop {
            cropRect = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
            isCropping = true
            tool = .crop
        } else {
            isCropping = false
            tool = item
        }
    }

    private func exitCrop() {
        isCropping = false
        tool = .pen
    }

    private func applyCrop() {
        model.applyCrop(cropRect)
        isCropping = false
        tool = .pen
    }

    private func commitText() {
        guard let anchor = textAnchor else { return }
        let trimmed = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.add(EditorAnnotation(kind: .text, points: [anchor], text: trimmed,
                                   colorIndex: colorIndex, thickness: textScale))
        textAnchor = nil
        textValue = ""
    }

    private func finish() {
        onFinish(model.flattened())
    }

    private func saveToAlbum() async {
        let image = model.flattened()
        guard let encoded = EditedImageExport.encode(image, originalMediaType: "image/jpeg") else {
            flashToast("保存失败")
            return
        }
        let name = EditedImageExport.name(for: "图片", mime: encoded.mime)
        do {
            try await PhotoSaver.save(encoded.data, mediaType: encoded.mime, name: name)
            flashToast("已保存到相册")
        } catch {
            flashToast("保存失败")
        }
    }

    private func flashToast(_ text: String) {
        toastText = text
        withAnimation(.easeIn(duration: 0.15)) { showToast = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.15)) { showToast = false }
        }
    }

    // MARK: Gestures

    /// A tap on the canvas places the text anchor. Modelled as a zero-distance
    /// drag so the location comes from `DragGesture.Value.location`.
    private func textGesture(frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                textAnchor = Self.normalize(value.startLocation, in: frame)
                textValue = ""
                textFocused = true
            }
    }

    private func drawGesture(frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = Self.normalize(value.location, in: frame)
                if var current = draft {
                    if tool == .arrow, let first = current.points.first {
                        current.points = [first, point]
                    } else {
                        current.points.append(point)
                    }
                    draft = current
                } else {
                    draft = EditorAnnotation(kind: tool.annotationKind, points: [point], text: "",
                                             colorIndex: colorIndex, thickness: currentThickness)
                }
            }
            .onEnded { _ in
                guard let finished = draft else { return }
                draft = nil
                model.add(finished)
            }
    }

    private var currentThickness: CGFloat {
        tool == .mosaic ? mosaicThickness : penThickness
    }

    // MARK: Geometry helpers

    private static func fittedRect(for imageSize: CGSize, in container: CGSize) -> CGRect {
        EditorCanvasUIView.aspectFitRect(for: imageSize, in: container)
    }

    private static func normalize(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGPoint(x: min(max((point.x - frame.minX) / frame.width, 0), 1),
                       y: min(max((point.y - frame.minY) / frame.height, 0), 1))
    }
}
