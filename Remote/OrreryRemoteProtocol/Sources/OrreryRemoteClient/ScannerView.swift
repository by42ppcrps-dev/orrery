#if os(iOS)
import SwiftUI
import AVFoundation

/// A plain QR scanner on AVFoundation: works on every iPhone that can run the app and needs
/// only the camera permission. The first `orrery-remote:` code found is handed back.
struct ScannerView: UIViewControllerRepresentable {
    var found: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.found = found
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var found: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var done = false
    private var visible = false
    private let sessionQueue = DispatchQueue(label: "orrery.camera")
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        label.text = "Point the camera at the code on the Mac"
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
        ])
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.visible else { return }
                granted ? self.startScanning() : self.show("Camera access was not allowed. Close this screen and paste the code instead.")
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); visible = true }

    private func show(_ text: String) { label.text = text }

    private func startScanning() {
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else { show("No camera available. Paste the code instead."); return }
        let output = AVCaptureMetadataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { show("The camera could not be used."); return }
        session.addInput(input)
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        self.preview = preview
        sessionQueue.async { [session] in session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        sessionQueue.async { [session] in session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !done, let code = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first(where: { $0.hasPrefix("orrery-remote:") }) else { return }
        done = true
        sessionQueue.async { [session] in session.stopRunning() }
        found?(code)
    }
}

#endif
