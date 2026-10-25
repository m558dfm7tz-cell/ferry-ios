import SwiftUI
import UIKit
import UniformTypeIdentifiers
import AVFoundation

enum Capture {
    case photo(UIImage)
    case video(URL)
}

/// System camera capture (photo + video) via `UIImagePickerController`.
struct CameraPicker: UIViewControllerRepresentable {
    let mediaTypes: [String]
    let onPick: (Result<Capture, Error>) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = mediaTypes
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onPick(.success(.photo(image)))
            } else if let url = info[.mediaURL] as? URL {
                parent.onPick(.success(.video(url)))
            } else {
                parent.onPick(.failure(CameraError.unavailable))
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onPick(.failure(CameraError.cancelled))
            picker.dismiss(animated: true)
        }
    }

    enum CameraError: LocalizedError {
        case unavailable, cancelled
        var errorDescription: String? {
            switch self {
            case .unavailable: "无法读取拍摄结果。"
            case .cancelled: "已取消拍摄。"
            }
        }
    }
}

/// AVFoundation QR scanner for the address QR shown by the PC/web UI.
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onScan = { text in context.coordinator.found(text) }
        controller.onCancel = { context.coordinator.cancelled() }
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator {
        let parent: QRScannerView
        init(_ parent: QRScannerView) { self.parent = parent }
        func found(_ text: String) { parent.onScan(text) }
        func cancelled() { parent.onCancel() }
    }
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasHandled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview

        let cancel = UIButton(type: .system)
        cancel.setTitle("取消", for: .normal)
        cancel.setTitleColor(.white, for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        cancel.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        cancel.layer.cornerRadius = 8
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancel)
        NSLayoutConstraint.activate([
            cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            cancel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            cancel.widthAnchor.constraint(equalToConstant: 64),
            cancel.heightAnchor.constraint(equalToConstant: 36),
        ])

        let hint = UILabel()
        hint.text = "对准电脑上显示的二维码"
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 15)
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestAndStart()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    private func requestAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.startIfNeeded() } else { self?.onCancel?() }
                }
            }
        default:
            onCancel?()
        }
    }

    private func startIfNeeded() {
        guard !session.isRunning, session.inputs.isEmpty else { return }
        guard let device = AVCaptureDevice.default(for: .video) else { return }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
            }
            session.startRunning()
        } catch {
            onCancel?()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !hasHandled else { return }
        guard let code = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              code.type == .qr, let value = code.stringValue else { return }
        hasHandled = true
        session.stopRunning()
        onScan?(value)
    }

    @objc private func cancelTapped() {
        hasHandled = true
        session.stopRunning()
        onCancel?()
    }
}
