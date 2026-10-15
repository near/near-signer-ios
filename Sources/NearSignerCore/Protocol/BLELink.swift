import Foundation

/// Device side of the Ledger BLE protocol for one connected central: reassembles written
/// packets, answers MTU probes, runs APDUs through the session and frames the responses.
/// The iOS peripheral and the simulator's BLE-packet mode both use it.
public actor BLELink {
    private let session: NearAppSession
    private var assembler = BLEFrameAssembler()
    private var packetSize: Int

    /// - Parameter packetSize: largest notification payload, `CBCentral.maximumUpdateValueLength`
    ///   on iOS. Capped at 255 because the MTU answer carries it in one byte.
    public init(session: NearAppSession, packetSize: Int) {
        self.session = session
        self.packetSize = BLELink.clamp(packetSize)
    }

    public func updatePacketSize(_ size: Int) {
        packetSize = BLELink.clamp(size)
    }

    /// Handles one GATT write and returns the notifications to send, in order.
    public func receive(_ packet: Data) async -> [Data] {
        let event: BLEFrameAssembler.Event
        do {
            event = try assembler.receive(packet)
        } catch {
            // A lost or garbled packet: answer at once so the host fails fast (instead of waiting
            // minutes for a reply), and drop any half-received signing request.
            await session.reset()
            return BLEFraming.frames(for: StatusWord.invalidData.bytes, packetSize: packetSize)
        }
        switch event {
        case .none:
            return []
        case .mtuRequest:
            // Hosts probe when they open the transport: whatever an earlier one left half-sent on
            // this link must not be glued onto the next request.
            await session.reset()
            return [BLEFraming.mtuResponse(packetSize: packetSize)]
        case let .apdu(apdu):
            let response = await session.handle(apdu)
            return BLEFraming.frames(for: response, packetSize: packetSize)
        }
    }

    public func reset() async {
        assembler.reset()
        await session.reset()
    }

    private static func clamp(_ size: Int) -> Int { min(max(size, 20), 255) }
}
