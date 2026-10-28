import NearSignerCore
import SwiftUI
import UIKit

/// A request received through the camera (README "Camera transfer"): the computer shows it as a
/// loop of QR codes; the request then goes through the usual approval screen; the answer is one
/// QR code for the computer's camera, or to type there.
struct ScanView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        switch model.cameraTransfer {
        case .scanning, nil: return "Scan from computer"
        case .processing: return "Request received"
        case .response: return "Show to your computer"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.cameraTransfer {
                case let .scanning(progress):
                    ScanningView(scanner: model.cameraScanner, progress: progress, speed: model.cameraSpeed)
                case .processing:
                    ProcessingView()
                case let .response(response):
                    ResponseView(response: response) { model.cancelCameraTransfer() }
                case nil:
                    Color.clear
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                switch model.cameraTransfer {
                case .scanning:
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { model.cancelCameraTransfer() }
                    }
                case .response:
                    ToolbarItem(placement: .confirmationAction) {
                        CloseButton { model.cancelCameraTransfer() }
                    }
                default:
                    ToolbarItem(placement: .confirmationAction) { EmptyView() }
                }
            }
        }
        // While the signer has the request, its approval screen is the way to stop; closing this
        // sheet would lose the answer.
        .interactiveDismissDisabled(model.cameraTransfer == .processing)
        .onChange(of: model.cameraTransfer == nil) { _, closed in
            if closed { dismiss() }
        }
        .onDisappear {
            if model.cameraTransfer != .processing { model.cancelCameraTransfer() }
        }
    }
}

/// The camera, with the progress of the request arriving over it.
private struct ScanningView: View {
    let scanner: CameraScanner
    let progress: OpticalProgress?
    let speed: Double?

    private var cameraShown: Bool { scanner.permission == .authorized && scanner.failure == nil }

    var body: some View {
        ZStack {
            if cameraShown {
                CameraPreview(session: scanner.session)
                    .ignoresSafeArea()
            } else {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()
            }
            VStack {
                Spacer()
                status
                    .card()
                    .padding()
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch scanner.permission {
        case .denied:
            VStack(alignment: .leading, spacing: 10) {
                Label("Camera access is off", systemImage: "camera.fill")
                    .font(.headline)
                Text("NEAR Signer needs the camera to read the codes on your computer's screen. Allow it in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        case .undetermined:
            Label("Waiting for camera access…", systemImage: "camera.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .authorized:
            if let failure = scanner.failure {
                Label(failure, systemImage: "camera.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let progress {
                ProgressCard(progress: progress, speed: speed)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Point the camera at the codes on your computer's screen", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("The request appears here once every piece has been seen. It can start from any code.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ProgressCard: View {
    let progress: OpticalProgress
    let speed: Double?

    private var detail: String {
        var parts = [NearFormat.byteSize(progress.length)]
        if let speed, speed > 0 {
            parts.append("\(NearFormat.byteSize(Int(speed)))/s")
            let remaining = Double(progress.length) * Double(progress.total - progress.known) / Double(max(progress.total, 1)) / speed
            parts.append(remaining < 60 ? "about \(max(1, Int(remaining.rounded(.up)))) s left"
                : "about \(Int((remaining / 60).rounded(.up))) min left")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(progress.total == 1 ? "Receiving the request" : "\(progress.known) of \(progress.total) pieces")
                .font(.headline.monospacedDigit())
            ProgressView(value: Double(progress.known), total: Double(max(progress.total, 1)))
            Text(detail)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("Keep the codes in view until it's done.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// The request is with the signer: its approval screen is up (in the overlay window, above
/// this sheet), or the key is being unlocked.
private struct ProcessingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Request received")
                .font(.headline)
            Text("Review it on the screen that appears, then approve or reject it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

/// The answer: one QR code, and the same text in groups of five for typing.
private struct ResponseView: View {
    let response: OpticalResponse
    let done: () -> Void

    private var explanation: String? {
        switch response.status {
        case .ok: return nil
        case .parseFailed: return "The request couldn't be decoded, so nothing was signed."
        case .badPath: return "The computer asked for a key outside NEAR's derivation paths, so nothing was signed."
        case .publicKeyMismatch: return "The transaction names a key this phone doesn't have for that account, so nothing was signed."
        case .locked: return "The key couldn't be unlocked, so nothing was signed."
        default: return "Nothing was signed (\(response.status.description))."
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let explanation {
                    WarningCard(text: explanation + " This code tells your computer.")
                }
                QRCodeView(value: response.text)
                    .frame(maxWidth: 300)
                Text("Show this code to your computer's camera, or type it there.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                DataText(response.groupedText)
                    .font(.callout.monospaced())
                    .multilineTextAlignment(.center)
                    .valueMenu(response.text, title: "Answer")
                // For a phone that is online: Universal Clipboard pastes it on a Mac.
                CopyButton(value: response.text, label: "Copy code")
                    .secondaryActionStyle()
                    .controlSize(.small)
                if response.status == .ok {
                    Text(response.result.count == 32
                        ? "It carries your account's public key; the computer checks it."
                        : "It carries the signature; the computer checks it against your account's key before using it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .bottomActionBar {
            Button(action: done) {
                Text("Done").frame(maxWidth: .infinity)
            }
            .prominentActionStyle()
            .controlSize(.large)
            .padding()
        }
    }
}
