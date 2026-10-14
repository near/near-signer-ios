import SwiftUI

/// The app lock screen. It is shown in the overlay window, above any sheet that was open when the
/// app went to the background, and asks for Face ID by itself when the app becomes active.
struct LockView: View {
    let model: AppModel
    private let hasBiometrics = SecureKeyVault.hasBiometrics

    private var usesPasscode: Bool { !hasBiometrics || model.unlocksWithPasscode }

    private var primaryTitle: String {
        usesPasscode ? "Unlock with Passcode" : "Unlock with \(SecureKeyVault.biometryName)"
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 16) {
                    AppMark(size: 88)
                    Text("NEAR Signer")
                        .font(.title.bold())
                    Label("Locked", systemImage: "lock.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(spacing: 12) {
                    if let error = model.unlockError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(Color.red)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        Task { await model.unlock() }
                    } label: {
                        Label(primaryTitle, systemImage: usesPasscode ? "circle.grid.3x3.fill" : SecureKeyVault.biometrySymbol)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .prominentActionStyle()
                    .controlSize(.large)
                    .disabled(model.isUnlocking)
                    // The other way in, remembered for next time.
                    if hasBiometrics {
                        Button(usesPasscode ? "Use \(SecureKeyVault.biometryName)" : "Use Passcode") {
                            Task { await model.unlock(withPasscode: !usesPasscode) }
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 4)
                        .disabled(model.isUnlocking)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: 420)
        }
        // Not tied to the view's lifetime: the Face ID sheet makes the app inactive, and a
        // cancelled task must not cut the prompt short.
        .onChange(of: model.isSceneActive, initial: true) { _, active in
            if active { Task { await model.unlockAutomatically() } }
        }
    }
}

/// The app icon as it appears on the Home Screen, in the light or dark version to match the
/// app's appearance. The image set holds the same artwork as the app icon
/// (scripts/gen-app-icon.py writes both).
struct AppMark: View {
    let size: CGFloat

    var body: some View {
        Image("AppMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            // The Home Screen's corner shape.
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}
