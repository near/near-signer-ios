import NearSignerCore
import SwiftUI
import UIKit

/// A window above the app for what must never end up behind a sheet, alert or share sheet:
/// approval requests, the lock screen, errors and the privacy shield. A modal presented from the app's own window
/// cannot appear while another one is open, so these live here instead. The window is hidden
/// whenever it has nothing to show, and touches then reach the app.
@MainActor
final class OverlayWindow {
    private var window: UIWindow?

    func install(model: AppModel) {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let host = UIHostingController(rootView: OverlayContent(model: model))
        host.view.backgroundColor = .clear
        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        window.backgroundColor = .clear
        window.rootViewController = host
        window.overrideUserInterfaceStyle = model.appearance.interfaceStyle
        window.isHidden = !model.needsOverlay
        self.window = window
    }

    func setVisible(_ visible: Bool) {
        guard let window, window.isHidden == visible else { return }
        window.isHidden = !visible
        if visible {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }

    func apply(_ appearance: AppAppearance) {
        window?.overrideUserInterfaceStyle = appearance.interfaceStyle
    }
}

private struct OverlayContent: View {
    let model: AppModel

    var body: some View {
        ZStack {
            if let request = model.pendingRequest {
                ApprovalView(model: model, request: request)
                    .id(request.id)
                    .transition(.move(edge: .bottom))
            } else if let progress = model.receiving {
                ReceivingCard(progress: progress, isCancelling: model.isCancellingReceive) {
                    model.cancelReceiving(progress.id)
                }
            }
            if model.isLocked {
                LockView(model: model)
            }
            if let message = model.errorMessage {
                ErrorCard(message: message) { model.errorMessage = nil }
            }
            // Hides everything from the app switcher snapshot and while Face ID is shown. The lock
            // screen hides everything already.
            if !model.isSceneActive && !model.isLocked {
                PrivacyShield()
            }
        }
        .animation(.default, value: model.pendingRequest?.id)
    }
}

/// Shown while a large request (a contract deployment) arrives over Bluetooth.
private struct ReceivingCard: View {
    let progress: ReceiveProgress
    let isCancelling: Bool
    let cancel: () -> Void

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var amountText: String {
        guard let expected = progress.expected, let fraction = progress.fraction else {
            return "\(ReceivingCard.size(progress.received)) received"
        }
        return "\(ReceivingCard.size(progress.received)) of \(ReceivingCard.size(expected)) · \(Int(fraction * 100))%"
    }

    private var speedText: String? {
        guard let rate = progress.bytesPerSecond() else { return nil }
        var text = "\(ReceivingCard.size(Int(rate)))/s"
        if let remaining = progress.secondsRemaining() {
            text += remaining < 60 ? " · about \(max(1, Int(remaining))) s left" : " · about \(Int((remaining / 60).rounded(.up))) min left"
        }
        return text
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.largeTitle)
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: !isCancelling)
                Text("Receiving a request")
                    .font(.headline)
                Text("Your computer is sending a large request, such as a contract deployment. Keep this app open. You'll review it when it has arrived.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
                VStack(spacing: 4) {
                    Text(amountText)
                        .font(.callout.monospacedDigit().weight(.medium))
                    if let speedText {
                        Text(speedText)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Button(role: .destructive) {
                    cancel()
                } label: {
                    Text(isCancelling ? "Cancelling…" : "Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isCancelling)
            }
            .padding(24)
            .frame(maxWidth: 360)
            .floatingPanel()
            .padding(24)
        }
    }
}

private struct ErrorCard: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Color.orange)
                Text("Something went wrong")
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    dismiss()
                } label: {
                    Text("OK").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(24)
            .frame(maxWidth: 340)
            .floatingPanel()
            .padding(32)
        }
    }
}
