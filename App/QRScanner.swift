import AVFoundation
import SwiftUI
import UIKit

/// A live camera view that reports the first QR code it sees.
///
/// Deliberately thin: it finds a code and hands the string up. Every decision about what
/// that string MEANS lives in `Pairing.parse` and `PairingCoordinator`, in HerdrKit, where
/// it is covered by tests. This file cannot be tested on the machine it was written on, so
/// it is kept small enough to read in one sitting.
struct QRScannerView: UIViewControllerRepresentable {
    /// Called on the main actor with the decoded string, at most once per scanning session.
    var onFound: (String) -> Void
    /// Called when the camera cannot run at all (denied, restricted, or no device).
    var onUnavailable: (QRScannerUnavailable) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.onFound = onFound
        controller.onUnavailable = onUnavailable
        return controller
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {
        // The closures capture SwiftUI state that is re-created on every body evaluation;
        // without refreshing them the controller keeps calling into a stale generation and
        // the sheet appears to ignore a successful scan.
        controller.onFound = onFound
        controller.onUnavailable = onUnavailable
    }
}

/// Why the camera could not be used. Separated from a generic error so the UI can offer
/// the right next step — Settings for a denial, manual entry for anything else.
enum QRScannerUnavailable: Equatable {
    /// The person said no, or can say yes in Settings.
    case permissionDenied
    /// Parental controls / MDM: asking again will not help.
    case restricted
    /// No usable camera (a Mac without one, or the simulator).
    case noCamera
    /// The capture graph would not start.
    case cameraFailed(String)

    var message: String {
        switch self {
        case .permissionDenied:
            return "herdrup needs camera access to scan the pairing code. Turn it on in "
                + "Settings, or add the machine manually."
        case .restricted:
            return "Camera access is restricted on this device. Add the machine manually."
        case .noCamera:
            return "This device has no camera to scan with. Add the machine manually."
        case .cameraFailed(let why):
            return "The camera couldn't start (\(why)). Add the machine manually."
        }
    }

    /// Only a denial is fixable in Settings; offering that button for the others sends
    /// someone to a screen with nothing on it to change.
    var offersSettings: Bool { self == .permissionDenied }
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onFound: ((String) -> Void)?
    var onUnavailable: ((QRScannerUnavailable) -> Void)?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    /// A camera delivers the same code many times a second. Without this the coordinator
    /// would be driven repeatedly — pairing twice, with the second attempt failing on a
    /// spent token and overwriting the success the user just saw.
    private var hasReported = false
    /// `startRunning` blocks; doing it on the main thread stalls the sheet's presentation
    /// animation, which reads as the app freezing at the moment of opening the scanner.
    private let sessionQueue = DispatchQueue(label: "herdrup.qrscanner.session")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestAccessThenConfigure()
    }

    private func requestAccessThenConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    granted ? self.configure() : self.onUnavailable?(.permissionDenied)
                }
            }
        case .denied:
            onUnavailable?(.permissionDenied)
        case .restricted:
            onUnavailable?(.restricted)
        @unknown default:
            onUnavailable?(.permissionDenied)
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            onUnavailable?(.noCamera)
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onUnavailable?(.cameraFailed("no metadata output"))
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        // Set AFTER adding the output: available types are empty until then, so setting
        // it earlier silently yields a session that detects nothing.
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            onUnavailable?(.cameraFailed("QR codes not supported here"))
            return
        }
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.layer.bounds
        view.layer.addSublayer(preview)
        self.preview = preview

        sessionQueue.async { [session] in session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.layer.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Leaving the camera running holds the hardware and the privacy indicator stays
        // lit after the sheet is gone.
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput objects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasReported,
              let object = objects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue
        else { return }
        hasReported = true
        // Stop first: a scan that opens a confirmation should not keep reading frames
        // behind it.
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onFound?(value)
    }

    /// Allow another scan after a failure, without rebuilding the capture graph.
    func resumeScanning() {
        hasReported = false
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }
}
