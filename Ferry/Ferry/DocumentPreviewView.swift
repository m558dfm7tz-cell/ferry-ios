import SwiftUI
import QuickLook

/// PDF / Word / Excel / PowerPoint and other non-media files are previewed with
/// the system QuickLook controller (QLPreviewController). It is hosted inside
/// our own container so we can add a clearly visible 关闭 button and vertical
/// drag-down-to-dismiss (WeChat style); the QL nav bar "Done" also dismisses
/// via `previewControllerDidDismiss`.
struct DocumentPreviewView: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            QLPreviewContainer(url: url, onDismiss: { dismiss() })
                .ignoresSafeArea()
                .offset(y: dragOffset)
                .scaleEffect(scale)
                .opacity(opacity)
                .gesture(dismissDrag)
        }
        .overlay(alignment: .bottomTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 52, height: 52)
                    .background(Color.black.opacity(0.55), in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
            .padding(20)
        }
    }

    private var scale: CGFloat { 1 - min(1, abs(dragOffset) / 600) * 0.2 }
    private var opacity: Double { 1 - min(1, abs(dragOffset) / 400) * 0.6 }

    private var dismissDrag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let velocityY = value.predictedEndTranslation.height
                if abs(dragOffset) > 120 || abs(velocityY) > 900 {
                    dismiss()
                } else {
                    withAnimation(.spring()) { dragOffset = 0 }
                }
            }
    }
}

/// Hosts QLPreviewController inside a UINavigationController and forwards the
/// controller's own dismiss (nav-bar "Done") back to SwiftUI.
private struct QLPreviewContainer: UIViewControllerRepresentable {
    let url: URL
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.delegate = context.coordinator
        let nav = UINavigationController(rootViewController: preview)
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url, onDismiss: onDismiss) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let url: URL
        let onDismiss: () -> Void
        init(url: URL, onDismiss: @escaping () -> Void) {
            self.url = url
            self.onDismiss = onDismiss
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }

        func previewControllerDidDismiss(_ controller: QLPreviewController) {
            onDismiss()
        }
    }
}

/// Native SwiftUI viewer for plain-text files (.txt / .md / text/*). Rendered
/// as selectable text; also supports vertical drag-down-to-dismiss.
struct TextFileView: View {
    let text: String
    let name: String

    @Environment(\.dismiss) private var dismiss
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
            .offset(y: dragOffset)
            .scaleEffect(scale)
            .opacity(opacity)
            .gesture(dismissDrag)
        }
    }

    private var scale: CGFloat { 1 - min(1, abs(dragOffset) / 600) * 0.2 }
    private var opacity: Double { 1 - min(1, abs(dragOffset) / 400) * 0.6 }

    private var dismissDrag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let velocityY = value.predictedEndTranslation.height
                if abs(dragOffset) > 120 || abs(velocityY) > 900 {
                    dismiss()
                } else {
                    withAnimation(.spring()) { dragOffset = 0 }
                }
            }
    }
}
