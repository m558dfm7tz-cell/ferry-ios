import SwiftUI
import UIKit
import Vision

#if canImport(Translation)
import Translation
#endif

/// On-device OCR (Vision) plus Apple Translation for a single image.
///
/// The sheet shows the recognized text (selectable) with 复制全部 / 翻译 /
/// 翻译全图 actions. "翻译全图" re-renders the original image with each text
/// block overlaid by its translation, then presents a save/share viewer.
/// No online or paid service is used anywhere in this file.
struct OCRView: View {
    let image: UIImage
    let name: String

    @Environment(\.dismiss) private var dismiss

    @State private var observations: [VNRecognizedTextObservation] = []
    @State private var recognizedText = ""
    @State private var isRecognizing = true
    @State private var statusMessage: String?
    @State private var translatedText = ""
    @State private var translatedImage: UIImage?
    @State private var showTranslatedImage = false
    @State private var showToast = false
    @State private var toastText = ""
    @State private var translationMode: TranslationMode = .none

    #if canImport(Translation)
    @State private var configuration: TranslationSession.Configuration?
    #endif

    private enum TranslationMode { case none, text, fullImage }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isRecognizing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在识别文字…").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                    } else {
                        Text(recognizedText)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !translatedText.isEmpty {
                            Divider()
                            Text("翻译")
                                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            Text(translatedText)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let statusMessage {
                            Text(statusMessage).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("识别文字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
        }
        .task { await runOCR() }
        #if canImport(Translation)
        .translationTask(configuration) { session in
            await performTranslation(session: session)
        }
        #endif
        .fullScreenCover(isPresented: $showTranslatedImage) {
            if let translatedImage {
                TranslatedImageViewer(image: translatedImage)
            }
        }
        .overlay { if showToast { toastView } }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button { copyAll() } label: {
                Label("复制全部", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(recognizedText.isEmpty)

            Button { startTranslation(.text) } label: {
                Label("翻译", systemImage: "character.bubble")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(recognizedText.isEmpty)

            Button { startTranslation(.fullImage) } label: {
                Label("翻译全图", systemImage: "photo")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(recognizedText.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private var toastView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(toastText).foregroundStyle(.white).font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.black.opacity(0.8), in: Capsule())
        .transition(.opacity)
    }

    private func runOCR() async {
        isRecognizing = true
        defer { isRecognizing = false }
        observations = OCRRecognizer.recognize(image)
        recognizedText = observations
            .map { $0.topCandidates(1).first?.string ?? "" }
            .joined(separator: "\n")
        if observations.isEmpty {
            statusMessage = "未识别到文字"
        }
    }

    private func copyAll() {
        UIPasteboard.general.string = recognizedText
        flashToast("已复制全部文字")
    }

    private func startTranslation(_ mode: TranslationMode) {
        translationMode = mode
        let isChinese = recognizedText.range(of: "\\p{Han}", options: .regularExpression) != nil
        let source = Locale.Language(identifier: isChinese ? "zh-Hans" : "en")
        let target = Locale.Language(identifier: isChinese ? "en" : "zh-Hans")
        beginTranslation(source: source, target: target)
    }

    private func beginTranslation(source: Locale.Language, target: Locale.Language) {
        #if canImport(Translation)
        Task {
            do {
                let status = try await LanguageAvailability().status(from: source, to: target)
                switch status {
                case .installed, .supported:
                    configuration = TranslationSession.Configuration(source: source, target: target)
                case .unsupported:
                    statusMessage = "当前系统不支持该语言的翻译"
                @unknown default:
                    statusMessage = "当前系统不支持该语言的翻译"
                }
            } catch {
                statusMessage = "当前系统不支持该语言的翻译"
            }
        }
        #else
        statusMessage = "当前系统不支持该语言的翻译"
        #endif
    }

    #if canImport(Translation)
    private func performTranslation(session: TranslationSession) async {
        do {
            switch translationMode {
            case .text:
                let response = try await session.translate(recognizedText)
                translatedText = response.targetText
                statusMessage = nil
            case .fullImage:
                let blocks = observations.compactMap { $0.topCandidates(1).first?.string }
                var translated: [String] = []
                for block in blocks {
                    let response = try await session.translate(block)
                    translated.append(response.targetText)
                }
                if let rendered = ImageTranslator.render(original: image, observations: observations, translations: translated) {
                    translatedImage = rendered
                    showTranslatedImage = true
                } else {
                    statusMessage = "生成翻译图片失败"
                }
            case .none:
                break
            }
        } catch {
            statusMessage = "翻译失败"
        }
    }
    #endif

    private func flashToast(_ text: String) {
        toastText = text
        withAnimation(.easeIn(duration: 0.15)) { showToast = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.15)) { showToast = false }
        }
    }
}

/// Runs a single on-device text recognition pass with Vision.
enum OCRRecognizer {
    static func recognize(_ image: UIImage) -> [VNRecognizedTextObservation] {
        guard let cgImage = image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            return (request.results ?? []).filter { !($0.topCandidates(1).first?.string ?? "").isEmpty }
        } catch {
            return []
        }
    }
}

/// Renders the original image with each recognized block overlaid by its
/// translation (Vision normalized rects are bottom-left origin; UIKit is
/// top-left, so the rect is flipped here).
enum ImageTranslator {
    static func render(original: UIImage, observations: [VNRecognizedTextObservation],
                       translations: [String]) -> UIImage? {
        let size = original.size
        guard size.width > 0, size.height > 0, !observations.isEmpty else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = original.scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            original.draw(in: CGRect(origin: .zero, size: size))
            for (index, observation) in observations.enumerated() {
                guard index < translations.count else { continue }
                let text = translations[index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let rect = convertVisionRect(observation.boundingBox, imageSize: size)
                guard rect.width > 1, rect.height > 1 else { continue }
                drawBlock(text: text, in: rect, original: original, context: context)
            }
        }
    }

    private static func convertVisionRect(_ normalized: CGRect, imageSize: CGSize) -> CGRect {
        let x = normalized.minX * imageSize.width
        let y = (1 - normalized.maxY) * imageSize.height
        return CGRect(x: x, y: y, width: normalized.width * imageSize.width,
                      height: normalized.height * imageSize.height)
    }

    private static func drawBlock(text: String, in rect: CGRect, original: UIImage,
                                  context: UIGraphicsImageRendererContext) {
        let backgroundRect = rect.insetBy(dx: -3, dy: -2)
        let sample = averageColor(of: original, in: backgroundRect)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        _ = sample.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        let darkText = luminance > 0.6

        let fillColor = darkText ? UIColor.white.withAlphaComponent(0.82) : UIColor.black.withAlphaComponent(0.62)
        fillColor.setFill()
        UIBezierPath(roundedRect: backgroundRect, cornerRadius: 5).fill()

        let textColor = darkText ? UIColor.black : UIColor.white
        let font = fittedFont(for: text, in: rect)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let textRect = CGRect(x: backgroundRect.midX - textSize.width / 2,
                              y: backgroundRect.midY - textSize.height / 2,
                              width: textSize.width, height: textSize.height)
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private static func fittedFont(for text: String, in rect: CGRect) -> UIFont {
        let maxWidth = rect.width + 10
        let maxHeight = rect.height + 8
        var size: CGFloat = min(220, max(8, rect.height * 0.5))
        while size > 8 {
            let font = UIFont.systemFont(ofSize: size, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let measured = (text as NSString).boundingRect(
                with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes, context: nil).size
            if measured.height <= maxHeight { return font }
            size -= 1
        }
        return UIFont.systemFont(ofSize: 8, weight: .medium)
    }

    private static func averageColor(of image: UIImage, in rect: CGRect) -> UIColor {
        guard let cgImage = image.cgImage else { return .white }
        let scale = image.scale
        var cropRect = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                              width: rect.width * scale, height: rect.height * scale).integral
        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        cropRect = cropRect.intersection(bounds)
        guard cropRect.width >= 1, cropRect.height >= 1,
              let cropped = cgImage.cropping(to: cropRect) else { return .white }
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return .white }
        return UIColor(red: CGFloat(data[0]) / 255, green: CGFloat(data[1]) / 255,
                       blue: CGFloat(data[2]) / 255, alpha: 1)
    }
}

/// Full-screen viewer for the translated image with save-to-album and share.
struct TranslatedImageViewer: View {
    let image: UIImage

    @Environment(\.dismiss) private var dismiss
    @State private var showToast = false
    @State private var toastText = ""
    @State private var shareItem: ShareItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZoomableImageView(image: image, onDismiss: { dismiss() }).ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            Text("翻译图片").font(.headline).foregroundStyle(.white.opacity(0.92)).padding(20)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 14) {
                Button { Task { await save() } } label: {
                    roundIcon("square.and.arrow.down")
                }
                .accessibilityLabel("保存到相册")
                Button { share() } label: {
                    roundIcon("square.and.arrow.up")
                }
                .accessibilityLabel("分享")
            }
            .padding(20)
        }
        .overlay { if showToast { toastView } }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        .statusBarHidden()
    }

    private func roundIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 22, weight: .medium))
            .frame(width: 52, height: 52)
            .background(Color.white.opacity(0.15), in: Circle())
            .foregroundStyle(.white)
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

    private func save() async {
        guard let data = image.jpegData(compressionQuality: 0.95) else {
            flashToast("保存失败")
            return
        }
        do {
            try await PhotoSaver.save(data, mediaType: "image/jpeg", name: "翻译图片.jpg")
            flashToast("已保存到相册")
        } catch {
            flashToast("保存失败")
        }
    }

    private func share() {
        guard let data = image.jpegData(compressionQuality: 0.95) else { return }
        if let url = AttachmentSupport.writeTemporaryFile(data, name: "翻译图片.jpg") {
            shareItem = ShareItem(url: url)
        }
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
