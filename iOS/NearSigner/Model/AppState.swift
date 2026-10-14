import UIKit

/// Light, dark, or follow the system (the default).
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Sets the style on every window, so sheets and full-screen covers follow it too.
    @MainActor
    func apply() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = interfaceStyle
            }
        }
    }
}

/// The link to computers, as the home screen presents it.
enum ConnectionState: Equatable {
    case starting
    /// Turned off in the app's settings.
    case disabled
    case needsPermission
    /// Turned off in iOS.
    case bluetoothOff
    case unsupported
    case waiting
    case connected(Int)
    /// iOS Simulator: no Bluetooth, hosts on the Mac connect over the loopback bridge.
    case simulator(connected: Int)
    case failed(String)

    var isWaiting: Bool {
        switch self {
        case .waiting, .simulator(connected: 0): return true
        default: return false
        }
    }
}

/// One line of the security checklist.
struct SecurityItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let done: Bool
}
