import CoreBluetooth
import Foundation
import NearSignerCore

enum BLEStatus: Equatable {
    case off
    case starting
    case unauthorized
    case unsupported
    case poweredOff
    case advertising(connected: Int)
    case failed(String)
}

/// BLE GATT peripheral that looks like a Ledger Nano X running the NEAR app.
///
/// It exposes Ledger's Nano X service and characteristic UUIDs and speaks Ledger's BLE framing,
/// so unmodified hosts work: `near-cli-rs` built with the `ledger-ble` feature (near-ledger-rs
/// `TransportBle`) and the Ledger wallet of near-connect (Web Bluetooth in Chrome/Edge).
/// The service is the only primary service, because the near-connect executor picks the first one.
final class BLEPeripheral: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
    static let serviceUUID = CBUUID(string: "13D63400-2C97-0004-0000-4C6564676572")
    static let notifyUUID = CBUUID(string: "13D63400-2C97-0004-0001-4C6564676572")
    static let writeUUID = CBUUID(string: "13D63400-2C97-0004-0002-4C6564676572")
    static let writeCommandUUID = CBUUID(string: "13D63400-2C97-0004-0003-4C6564676572")
    static let localName = "NEAR Signer"
    /// Every host writes as soon as it has subscribed; see `answerLostProbe(of:)`.
    private static let lostProbeDelay: TimeInterval = 1

    private final class Connection {
        let central: CBCentral
        let link: BLELink
        let continuation: AsyncStream<Data>.Continuation
        let task: Task<Void, Never>
        /// Set once a packet arrives from the central (or the lost-probe answer goes out).
        var heardFrom = false

        init(central: CBCentral, link: BLELink, continuation: AsyncStream<Data>.Continuation, task: Task<Void, Never>) {
            self.central = central
            self.link = link
            self.continuation = continuation
            self.task = task
        }
    }

    private let queue = DispatchQueue(label: "near-signer.ble")
    private let makeSession: @Sendable (String) -> NearAppSession
    private let onStatus: @Sendable (BLEStatus) -> Void

    // Everything below is confined to `queue` (the CoreBluetooth delegate queue).
    private var manager: CBPeripheralManager?
    private var notifyCharacteristic: CBMutableCharacteristic?
    private var connections: [UUID: Connection] = [:]
    private var outbox: [(central: CBCentral, packet: Data)] = []
    private var requirePairing = true

    init(makeSession: @escaping @Sendable (String) -> NearAppSession,
         onStatus: @escaping @Sendable (BLEStatus) -> Void) {
        self.makeSession = makeSession
        self.onStatus = onStatus
        super.init()
    }

    /// Starts advertising. Creating the manager triggers the Bluetooth permission prompt.
    /// Calling it again with the same setting keeps existing connections.
    func start(requirePairing: Bool) {
        queue.async {
            let changed = self.requirePairing != requirePairing
            self.requirePairing = requirePairing
            if let manager = self.manager {
                if changed { self.configure(manager) }
            } else {
                self.onStatus(.starting)
                self.manager = CBPeripheralManager(
                    delegate: self, queue: self.queue,
                    options: [CBPeripheralManagerOptionShowPowerAlertKey: true])
            }
        }
    }

    func stop() {
        queue.async {
            self.dropAllConnections()
            if let manager = self.manager {
                manager.stopAdvertising()
                manager.removeAllServices()
                manager.delegate = nil
            }
            self.manager = nil
            self.notifyCharacteristic = nil
            self.onStatus(.off)
        }
    }

    // MARK: Setup

    private func configure(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }
        peripheral.stopAdvertising()
        peripheral.removeAllServices()
        dropAllConnections()

        // With pairing required, subscribing to notifications brings up the pairing dialog, as on
        // a Nano X, and every write needs the encrypted link. Ledger's mobile transports (Ledger
        // Live, Meteor) send their first packet as a write without response, which gets no error
        // to start pairing: it must not be the thing that is expected to start it.
        let writePermissions: CBAttributePermissions = requirePairing ? [.writeEncryptionRequired] : [.writeable]
        let notify = CBMutableCharacteristic(
            type: BLEPeripheral.notifyUUID,
            properties: requirePairing ? [.notify, .notifyEncryptionRequired] : [.notify], value: nil,
            permissions: requirePairing ? [.readEncryptionRequired] : [.readable])
        let write = CBMutableCharacteristic(
            type: BLEPeripheral.writeUUID, properties: [.write, .writeWithoutResponse], value: nil,
            permissions: writePermissions)
        let writeCommand = CBMutableCharacteristic(
            type: BLEPeripheral.writeCommandUUID, properties: [.writeWithoutResponse], value: nil,
            permissions: writePermissions)
        let service = CBMutableService(type: BLEPeripheral.serviceUUID, primary: true)
        service.characteristics = [notify, write, writeCommand]
        notifyCharacteristic = notify
        peripheral.add(service)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            configure(peripheral)
        case .poweredOff:
            dropAllConnections()
            onStatus(.poweredOff)
        case .unauthorized:
            onStatus(.unauthorized)
        case .unsupported:
            onStatus(.unsupported)
        case .resetting, .unknown:
            onStatus(.starting)
        @unknown default:
            onStatus(.starting)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            onStatus(.failed(error.localizedDescription))
            return
        }
        // iOS advertises only the local name and service UUIDs, and only while the app is in the
        // foreground, which is what this app wants anyway.
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: BLEPeripheral.localName,
            CBAdvertisementDataServiceUUIDsKey: [BLEPeripheral.serviceUUID],
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            onStatus(.failed(error.localizedDescription))
        } else {
            publishStatus()
        }
    }

    // MARK: Connections

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        let connection = connection(for: central)
        // Ask for the shortest connection interval: every APDU is a round trip, so the interval,
        // not the phone, sets the speed of large requests. The computer may still refuse.
        peripheral.setDesiredConnectionLatency(.low, for: central)
        let size = central.maximumUpdateValueLength
        Task { await connection.link.updatePacketSize(size) }
        if requirePairing { answerLostProbe(of: connection) }
        publishStatus()
    }

    /// Ledger's mobile transports (Ledger Live, Meteor) ask for notifications and send the MTU probe
    /// (a write without response) right away, without waiting for the subscription. On a first
    /// connection the probe can arrive while pairing is still going on: iOS then drops it without
    /// an error, and the host waits for the answer forever. A central that is still silent a moment
    /// after subscribing lost its probe, so it gets the answer anyway. The answer only carries the
    /// packet size; every later write still needs the encrypted link.
    private func answerLostProbe(of connection: Connection) {
        queue.asyncAfter(deadline: .now() + BLEPeripheral.lostProbeDelay) { [weak self] in
            guard let self, self.connections[connection.central.identifier] === connection,
                  !connection.heardFrom else { return }
            connection.heardFrom = true
            connection.continuation.yield(Data([BLEFraming.mtuTag, 0, 0, 0, 0]))
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        drop(central.identifier)
        publishStatus()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // Requests with a non-zero offset continue the previous one (long write); every
        // offset-0 request is a separate Ledger BLE packet. Only computers that subscribed to
        // notifications (every Ledger host does so first) get a connection; others are refused,
        // so they cannot hold memory or a pending prompt.
        var packet: (central: CBCentral, data: Data)?
        func deliver(_ pending: (central: CBCentral, data: Data)) {
            guard let connection = connections[pending.central.identifier] else { return }
            connection.heardFrom = true
            connection.continuation.yield(pending.data)
        }
        for request in requests {
            let uuid = request.characteristic.uuid
            guard uuid == BLEPeripheral.writeUUID || uuid == BLEPeripheral.writeCommandUUID,
                  let value = request.value else { continue }
            if request.offset == 0 {
                if let pending = packet { deliver(pending) }
                packet = (request.central, value)
            } else {
                packet?.data.append(value)
            }
        }
        if let pending = packet { deliver(pending) }
        if let first = requests.first {
            let subscribed = connections[first.central.identifier] != nil
            peripheral.respond(to: first, withResult: subscribed ? .success : .writeNotPermitted)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        flush()
    }

    private func connection(for central: CBCentral) -> Connection {
        if let existing = connections[central.identifier] { return existing }
        // A short per-computer label tells several connected computers apart on screen.
        let session = makeSession("Bluetooth · \(central.identifier.uuidString.prefix(4))")
        let link = BLELink(session: session, packetSize: central.maximumUpdateValueLength)
        // Bounded: a computer flooding packets loses its own (and gets a framing error), nothing more.
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingOldest(4096))
        // One consumer per central keeps packets and responses in order. Cancelling the task
        // (on disconnect) cancels a pending approval prompt.
        let task = Task { [weak self] in
            for await packet in stream {
                let notifications = await link.receive(packet)
                guard !Task.isCancelled, let self else { break }
                self.queue.async { self.send(notifications, to: central) }
            }
        }
        let connection = Connection(central: central, link: link, continuation: continuation, task: task)
        connections[central.identifier] = connection
        return connection
    }

    private func drop(_ identifier: UUID) {
        guard let connection = connections.removeValue(forKey: identifier) else { return }
        connection.continuation.finish()
        connection.task.cancel()
        outbox.removeAll { $0.central.identifier == identifier }
    }

    private func dropAllConnections() {
        for identifier in Array(connections.keys) { drop(identifier) }
        outbox.removeAll()
    }

    private func publishStatus() {
        guard manager?.isAdvertising == true || !connections.isEmpty else { return }
        onStatus(.advertising(connected: connections.count))
    }

    // MARK: Notifications

    private func send(_ packets: [Data], to central: CBCentral) {
        guard connections[central.identifier] != nil else { return }
        outbox.append(contentsOf: packets.map { (central: central, packet: $0) })
        flush()
    }

    /// Sends queued notifications until CoreBluetooth's transmit queue is full; the rest go out
    /// from `peripheralManagerIsReady(toUpdateSubscribers:)`.
    private func flush() {
        guard let manager, let characteristic = notifyCharacteristic else {
            outbox.removeAll()
            return
        }
        while let next = outbox.first {
            if manager.updateValue(next.packet, for: characteristic, onSubscribedCentrals: [next.central]) {
                outbox.removeFirst()
            } else {
                return
            }
        }
    }
}
