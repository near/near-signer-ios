import Foundation

/// Emulates the NEAR Ledger app's APDU interface for one host connection.
/// Each transport connection owns one session; APDUs must be passed in order.
public actor NearAppSession {
    private let service: SignerService
    private let transport: String
    /// False makes the session answer the capability command like a Ledger (for host tests).
    private let offersFastMode: Bool

    private var pendingIns: UInt8?
    private var pendingData = Data()
    // Progress of the request being received.
    private var pendingID = UUID()
    private var pendingStart = Date()
    private var reportedBytes = 0

    /// Requests smaller than this arrive in a blink and get no progress display.
    static let progressThreshold = 8 * 1024
    static let progressStep = 4 * 1024

    public init(service: SignerService, transport: String, offersFastMode: Bool = true) {
        self.service = service
        self.transport = transport
        self.offersFastMode = offersFastMode
    }

    /// Handles one raw APDU and returns response data followed by the status word.
    public func handle(_ raw: Data) async -> Data {
        guard let command = APDUCommand(raw) else {
            // Like every other error, drops a half-received signing request.
            reset()
            return StatusWord.wrongLength.bytes
        }
        do {
            return try await dispatch(command) + StatusWord.ok.bytes
        } catch let status as StatusWord {
            return status.bytes
        } catch {
            return StatusWord.invalidData.bytes
        }
    }

    public func reset() {
        if reportedBytes > 0 {
            let service = self.service
            let id = pendingID
            Task { await service.endReceiving(id) }
        }
        clearPending()
    }

    private func clearPending() {
        pendingIns = nil
        pendingData = Data()
        reportedBytes = 0
    }

    private func dispatch(_ command: APDUCommand) async throws -> Data {
        switch (command.cla, command.ins) {
        case (NearAPDU.claDashboard, NearAPDU.insGetAppName):
            // BOLOS "get app and version": format, name, version, flags.
            let name = Data("NEAR".utf8)
            let version = Data(NearAPDU.reportedAppVersion.map(String.init).joined(separator: ".").utf8)
            return Data([1, UInt8(name.count)]) + name + Data([UInt8(version.count)]) + version + Data([1, 0])

        case (NearAPDU.claDashboard, NearAPDU.insQuitApp), (NearAPDU.claOpenApp, NearAPDU.insOpenApp):
            // The NEAR "app" is always open.
            reset()
            return Data()

        case (NearAPDU.cla, NearAPDU.insGetVersion):
            reset()
            return Data(NearAPDU.reportedAppVersion)

        case (NearAPDU.cla, NearAPDU.insGetCapabilities) where offersFastMode:
            reset()
            return SignerCapabilities.current.serialized

        case (NearAPDU.cla, NearAPDU.insGetPublicKey), (NearAPDU.cla, NearAPDU.insGetWalletId):
            reset()
            let path = try parsePath(command.data)
            let display = command.ins == NearAPDU.insGetWalletId || command.p1 == NearAPDU.p1GetPublicKeyDisplay
            switch await service.publicKey(path: path, display: display, transport: transport) {
            case let .success(key): return key
            case let .failure(status): throw status
            }

        case (NearAPDU.cla, NearAPDU.insSignTransaction),
             (NearAPDU.cla, NearAPDU.insSignNep413),
             (NearAPDU.cla, NearAPDU.insSignNep366):
            return try await handleSignChunk(command)

        case (NearAPDU.cla, _):
            reset()
            throw StatusWord.insNotSupported

        default:
            reset()
            throw StatusWord.claNotSupported
        }
    }

    private func handleSignChunk(_ command: APDUCommand) async throws -> Data {
        guard command.p1 == NearAPDU.p1More || command.p1 == NearAPDU.p1Last else {
            reset()
            throw StatusWord.wrongP1P2
        }
        if pendingIns != command.ins {
            // A different instruction starts a new request.
            reset()
            pendingIns = command.ins
            pendingID = UUID()
            pendingStart = Date()
        }
        pendingData.append(command.data)
        guard pendingData.count <= NearAPDU.maxPayload + NearAPDU.pathLength else {
            reset()
            throw StatusWord.invalidData
        }
        let kind: SignerService.SignKind
        switch command.ins {
        case NearAPDU.insSignNep413: kind = .nep413
        case NearAPDU.insSignNep366: kind = .nep366
        default: kind = .transaction
        }
        var progress = ReceiveProgress(
            id: pendingID, transport: transport, received: max(0, pendingData.count - NearAPDU.pathLength),
            expected: nil, startedAt: pendingStart)

        // The user cancelled from the progress screen: refusing this chunk stops the host.
        if reportedBytes > 0, await service.takeCancelledReceive(pendingID) {
            let id = pendingID
            clearPending()
            await service.endReceiving(id)
            await service.recordCancelledReceive(progress, kind: kind)
            throw StatusWord.userRejected
        }
        guard command.p1 == NearAPDU.p1Last else {
            if progress.received >= NearAppSession.progressThreshold,
               reportedBytes == 0 || progress.received - reportedBytes >= NearAppSession.progressStep {
                reportedBytes = progress.received
                // The total is in the first bytes; look at a bounded prefix only.
                if kind == .transaction {
                    progress.expected = TransactionSizeProbe.expectedSize(
                        ofPrefix: pendingData.dropFirst(NearAPDU.pathLength).prefix(TransactionSizeProbe.prefixLimit))
                }
                await service.reportReceiving(progress)
            }
            return Data()
        }

        let data = pendingData
        if reportedBytes > 0 { await service.endReceiving(pendingID) }
        reportedBytes = 0
        reset()
        guard data.count >= NearAPDU.pathLength else { throw StatusWord.wrongLength }
        let path = try parsePath(data.prefix(NearAPDU.pathLength))
        let payload = Data(data.dropFirst(NearAPDU.pathLength))
        switch await service.sign(kind: kind, path: path, payload: payload, transport: transport) {
        case let .success(signature): return signature
        case let .failure(status): throw status
        }
    }

    /// Exactly 5 hardened levels under `44'/397'` (NEAR's coin type), so a host cannot use this
    /// seed's keys for other chains.
    private func parsePath(_ data: Data) throws -> BIP32Path {
        guard data.count == NearAPDU.pathLength,
              let path = BIP32Path(serialized: data), AccountBook.isValidAccountPath(path) else {
            throw StatusWord.badPath
        }
        return path
    }
}
