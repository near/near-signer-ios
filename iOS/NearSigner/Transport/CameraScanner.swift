import AVFoundation
import Foundation
import Observation
import SwiftUI
import UIKit

/// Reads QR codes with the back camera and hands their text to the model, for requests that come
/// through the camera instead of Bluetooth (README "Camera transfer"). The camera only takes
/// pictures in: nothing on the phone can be reached through it. Like Bluetooth it runs only
/// while the app is in the foreground, and only while the scan screen is open.
@MainActor
@Observable
final class CameraScanner {
    enum Permission: Equatable {
        case undetermined
        case denied
        case authorized
    }

    private(set) var permission: Permission
    /// Why the camera couldn't start (no camera, as in the Simulator; a configuration error).
    private(set) var failure: String?
    private(set) var isRunning = false
    /// Every QR code the camera sees, as often as it sees it; the receiver drops repeats.
    var onCode: ((String) -> Void)?

    /// Shared with the preview layer. Configured here, started and stopped on `queue` (starting a
    /// session blocks); AVFoundation allows both.
    var session: AVCaptureSession { box.session }
    private let box = SessionBox()
    private let queue = DispatchQueue(label: "near-signer.camera")
    private var configured = false
    /// Set by `start`, cleared by `stop`: a stop during the permission prompt keeps the camera off.
    private var wanted = false
    @ObservationIgnored private lazy var delegate = Delegate { [weak self] codes in
        guard let self, self.isRunning else { return }
        for code in codes { self.onCode?(code) }
    }

    init() {
        permission = CameraScanner.currentPermission
    }

    private static var currentPermission: Permission {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .undetermined
        default: return .denied
        }
    }

    /// Asks for permission the first time, then starts the camera.
    func start() async {
        wanted = true
        permission = CameraScanner.currentPermission
        if permission == .undetermined {
            permission = await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
        }
        guard permission == .authorized, wanted else { return }
        if !configured {
            configured = true
            if let problem = configure() {
                failure = problem
                return
            }
        }
        guard failure == nil else { return }
        isRunning = true
        let box = self.box
        queue.async {
            if !box.session.isRunning { box.session.startRunning() }
        }
    }

    func stop() {
        wanted = false
        isRunning = false
        let box = self.box
        queue.async {
            if box.session.isRunning { box.session.stopRunning() }
        }
    }

    /// Back wide camera at 1080p (dense codes need the pixels), fast frames where the camera has
    /// them, QR codes only.
    private func configure() -> String? {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return "This device has no camera NEAR Signer can use."
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            return "The camera couldn't be opened."
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return "The camera can't read codes." }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(delegate, queue: queue)
        guard output.availableMetadataObjectTypes.contains(.qr) else { return "The camera can't read QR codes." }
        output.metadataObjectTypes = [.qr]
        CameraScanner.preferFastFrames(device, session: session)
        return nil
    }

    /// 1080p at 60 frames a second when the camera has such a format, and exposures of at most
    /// 1/120 s (auto exposure raises the sensitivity instead; a screen is bright). The codes change
    /// up to 20 times a second, and a frame exposed across a change reads nothing: more and shorter
    /// exposures lose fewer codes. Best effort; a camera without these keeps its defaults.
    private static func preferFastFrames(_ device: AVCaptureDevice, session: AVCaptureSession) {
        let fast = device.formats.first { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width == 1920 && size.height == 1080
                && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 60 }
        }
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if let fast {
            session.sessionPreset = .inputPriority
            device.activeFormat = fast
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
        }
        let shortest = CMTime(value: 1, timescale: 120)
        if device.activeFormat.minExposureDuration <= shortest, shortest <= device.activeFormat.maxExposureDuration {
            device.activeMaxExposureDuration = shortest
        }
    }

    /// The session crosses to `queue` to start and stop, which AVFoundation allows from any thread.
    private final class SessionBox: @unchecked Sendable {
        let session = AVCaptureSession()
    }

    /// AVFoundation calls back on `queue`; the texts are forwarded to the main actor.
    private final class Delegate: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onCodes: @MainActor ([String]) -> Void

        init(onCodes: @escaping @MainActor ([String]) -> Void) {
            self.onCodes = onCodes
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            let codes = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            guard !codes.isEmpty else { return }
            let onCodes = self.onCodes
            Task { @MainActor in onCodes(codes) }
        }
    }
}

/// The live camera image behind the scan screen.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        // The app is portrait only.
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    /// The preview layer is the view's own layer, so it always fills the view.
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
