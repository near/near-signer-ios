import Foundation
import NearSignerCore

/// Starts and stops the transports. Device builds use Bluetooth only. The iOS Simulator has no
/// Bluetooth, so Simulator builds add a loopback bridge for test hosts running on the Mac.
final class Transports: @unchecked Sendable {
    private let ble: BLEPeripheral
    #if targetEnvironment(simulator)
    private let bridge: SimulatorBridge
    #endif

    init(makeSession: @escaping @Sendable (String) -> NearAppSession,
         onBLEStatus: @escaping @Sendable (BLEStatus) -> Void,
         onBridgeStatus: @escaping @Sendable (BridgeStatus) -> Void) {
        ble = BLEPeripheral(makeSession: makeSession, onStatus: onBLEStatus)
        #if targetEnvironment(simulator)
        bridge = SimulatorBridge(makeSession: makeSession, onStatus: onBridgeStatus)
        #endif
    }

    func start(bluetooth: Bool, requirePairing: Bool) {
        if bluetooth {
            ble.start(requirePairing: requirePairing)
        } else {
            ble.stop()
        }
        #if targetEnvironment(simulator)
        bridge.start()
        #endif
    }

    func stop() {
        ble.stop()
        #if targetEnvironment(simulator)
        bridge.stop()
        #endif
    }
}
