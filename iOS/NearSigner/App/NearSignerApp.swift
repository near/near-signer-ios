import NearSignerCore
import SwiftUI
import UIKit

/// Third-party keyboards can see what is typed (with Full Access, even send it away). Recovery
/// phrases are typed here, so only the system keyboard is allowed.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier) -> Bool {
        extensionPointIdentifier != .keyboard
    }
}

@main
struct NearSignerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}

struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var overlay = OverlayWindow()
    @State private var earlierDeferred = false
    @State private var strictUpgradeDeferred = false

    var body: some View {
        Group {
            if !model.isLoaded {
                // Until the phone is unlocked the wallet list cannot be read.
                PrivacyShield()
            } else if model.hasKey {
                // Hidden, not removed, while locked: the app comes back where it was. The lock
                // screen itself is in the overlay window, above any open sheet.
                MainTabView(model: model)
                    .opacity(model.isLocked ? 0 : 1)
                    .accessibilityHidden(model.isLocked)
            } else {
                OnboardingView(model: model)
            }
        }
        // Fallback for the moment before the overlay window exists.
        .overlay {
            if scenePhase != .active && (model.showsPrivacyShield || model.isLocked) {
                PrivacyShield()
            }
        }
        // Approvals, errors and the privacy shield are shown by the overlay window, above any sheet.
        .alert("Wallets from an earlier installation", isPresented: Binding(
            get: { !model.earlierWallets.isEmpty && !earlierDeferred && !model.isLocked },
            set: { if !$0 { earlierDeferred = true } }
        )) {
            // A cancelled Face ID / passcode prompt brings the choice back.
            Button("Restore") { Task { if await !model.restoreEarlierWallets() { earlierDeferred = false } } }
            Button("Delete keys", role: .destructive) { Task { if await !model.deleteEarlierWallets() { earlierDeferred = false } } }
            Button("Decide later", role: .cancel) {}
        } message: {
            Text("NEAR Signer found \(model.earlierWallets.count) wallet key(s) left on this iPhone by an earlier installation. Restore them, or delete them for good?")
        }
        // Strict Face ID from an earlier version: the app enforces it until the keys are updated.
        .alert("Update Strict Face ID", isPresented: Binding(
            get: { model.strictUpgradePending && model.hasKey && !strictUpgradeDeferred && !model.isLocked
                && (model.earlierWallets.isEmpty || earlierDeferred)
            },
            set: { if !$0 { strictUpgradeDeferred = true } }
        )) {
            Button("Continue") { Task { await model.setStrictBiometrics(true) } }
            Button("Later", role: .cancel) {}
        } message: {
            Text("Strict Face ID is now enforced by the Secure Enclave itself. Confirm with Face ID to update your wallets' keys. Until then, NEAR Signer keeps accepting only Face ID.")
        }
        .onAppear {
            model.loadIfPossible()
            overlay.install(model: model)
            model.appearance.apply()
        }
        .onChange(of: model.needsOverlay, initial: true) { _, visible in
            overlay.setVisible(visible)
        }
        .onChange(of: model.appearance) { _, appearance in
            overlay.apply(appearance)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.setSceneActive(phase == .active)
            // Transports stop in the background ("lockdown"), but not while merely inactive:
            // the Face ID prompt makes the app inactive in the middle of a signature.
            switch phase {
            case .active:
                model.appearance.apply()
                model.setActive(true)
            case .background:
                model.setActive(false)
            default:
                break
            }
        }
    }
}

struct MainTabView: View {
    let model: AppModel

    var body: some View {
        TabView {
            HomeView(model: model)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            HistoryView(model: model)
                .tabItem { Label("History", systemImage: "clock") }
            SettingsView(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

struct PrivacyShield: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            // Same mark and title as the lock screen, so switching between them doesn't jump.
            VStack(spacing: 16) {
                AppMark(size: 88)
                Text("NEAR Signer").font(.title.bold())
            }
        }
    }
}
