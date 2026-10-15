import Foundation
import XCTest
@testable import NearSignerCore

/// Presenter that answers automatically and remembers what it was shown.
final class ScriptedPresenter: ApprovalPresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Bool]
    private(set) var shown: [ApprovalRequest] = []

    init(answers: [Bool]) { self.answers = answers }

    func requestApproval(_ request: ApprovalRequest) async -> Bool {
        lock.withLock {
            shown.append(request)
            return answers.isEmpty ? false : answers.removeFirst()
        }
    }

    var shownCount: Int { lock.withLock { shown.count } }
}

final class ProtocolTests: XCTestCase {
    private func makeSession(answers: [Bool], history: HistoryStore = HistoryStore(fileURL: nil))
        throws -> (NearAppSession, ScriptedPresenter, HistoryStore) {
        let presenter = ScriptedPresenter(answers: answers)
        let vault = InMemoryKeyVault(material: try KeyMaterial.fromMnemonic(Fixtures.phrase))
        let service = SignerService(vault: vault, presenter: presenter, history: history)
        return (NearAppSession(service: service, transport: "test"), presenter, history)
    }

    private func exchange(_ session: NearAppSession, _ commands: [APDUCommand]) async -> Data {
        var last = Data()
        for (index, command) in commands.enumerated() {
            last = await session.handle(command.serialized)
            if index < commands.count - 1 { XCTAssertEqual(last, StatusWord.ok.bytes, "intermediate chunk") }
        }
        return last
    }

    func testSignsTransactionWithNearLedgerRsAndNearConnectChunking() async throws {
        let fixture = try XCTUnwrap(Fixtures.transactions.first { $0.name == "functionCall" })
        let payload = Data(base64Encoded: fixture.borsh)!
        let hash = SigningDigest.transaction(payload)
        let key = try KeyMaterial.fromMnemonic(Fixtures.phrase).privateKey(for: .ledgerDefault)
        // near-ledger-rs uses 250-byte chunks; the near-connect Ledger executor uses 123.
        for chunkSize in [250, 123, 7] {
            let (session, presenter, history) = try makeSession(answers: [true])
            let commands = NearAPDU.signCommands(ins: NearAPDU.insSignTransaction, path: .ledgerDefault,
                                                 payload: payload, chunkSize: chunkSize)
            let response = await exchange(session, commands)
            XCTAssertEqual(response.suffix(2), StatusWord.ok.bytes)
            let signature = response.dropLast(2)
            XCTAssertEqual(signature.count, 64)
            XCTAssertTrue(key.publicKey.isValidSignature(signature, for: hash))
            XCTAssertEqual(presenter.shownCount, 1)
            XCTAssertEqual(presenter.shown.first?.display.title, "Send usdc.testnet tokens to bob.testnet")
            XCTAssertEqual(presenter.shown.first?.needsUnlock, true)

            let records = await history.all()
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records[0].outcome, .approved)
            XCTAssertEqual(records[0].hash, fixture.hash)
            XCTAssertEqual(records[0].signature, Signature.ed25519(Data(signature)).description)
            XCTAssertEqual(records[0].signerId, "alice.testnet")
            XCTAssertEqual(records[0].network, "testnet")
            XCTAssertEqual(records[0].payload, payload)
            XCTAssertNotNil(PreparedRequest(record: records[0]))
        }
    }

    func testUserRejectionIsRecorded() async throws {
        let fixture = Fixtures.transactions[0]
        let (session, _, history) = try makeSession(answers: [false])
        let response = await exchange(session, NearAPDU.signCommands(
            ins: NearAPDU.insSignTransaction, path: .ledgerDefault, payload: Data(base64Encoded: fixture.borsh)!))
        XCTAssertEqual(response, StatusWord.userRejected.bytes)
        let records = await history.all()
        XCTAssertEqual(records.map(\.outcome), [.rejected])
        XCTAssertNil(records[0].signature)
    }

    func testUndecodablePayloadIsRefusedWithoutPrompt() async throws {
        let (session, presenter, history) = try makeSession(answers: [true])
        let response = await exchange(session, NearAPDU.signCommands(
            ins: NearAPDU.insSignTransaction, path: .ledgerDefault, payload: Data([1, 2, 3, 4, 5])))
        XCTAssertEqual(response, StatusWord.parseFailed.bytes)
        XCTAssertEqual(presenter.shownCount, 0)
        let records = await history.all()
        XCTAssertEqual(records.map(\.outcome), [.failed])
    }

    func testPublicKeyMismatchIsRefused() async throws {
        // The fixture transactions name the m/44'/397'/0'/0'/1' key; ask to sign with another path.
        let fixture = Fixtures.transactions[0]
        let otherPath = BIP32Path(hardened: [44, 397, 0, 0, 2])
        let (session, presenter, history) = try makeSession(answers: [true])
        let response = await exchange(session, NearAPDU.signCommands(
            ins: NearAPDU.insSignTransaction, path: otherPath, payload: Data(base64Encoded: fixture.borsh)!))
        XCTAssertEqual(response, StatusWord.publicKeyMismatch.bytes)
        XCTAssertEqual(presenter.shownCount, 1, "uncached key: mismatch is detected after unlocking")
        // The failure is remembered, so the second attempt is refused before prompting.
        let again = await exchange(session, NearAPDU.signCommands(
            ins: NearAPDU.insSignTransaction, path: otherPath, payload: Data(base64Encoded: fixture.borsh)!))
        XCTAssertEqual(again, StatusWord.publicKeyMismatch.bytes)
        XCTAssertEqual(presenter.shownCount, 1)
        let outcomes = await history.all().map(\.outcome)
        XCTAssertEqual(outcomes, [.failed, .failed])
    }

    func testNep413AndNep366Instructions() async throws {
        let key = try KeyMaterial.fromMnemonic(Fixtures.phrase).privateKey(for: .ledgerDefault)
        let (session, presenter, history) = try makeSession(answers: [true, true])

        let message = Data(base64Encoded: Fixtures.nep413Payload)!
        let messageResponse = await exchange(session, NearAPDU.signCommands(
            ins: NearAPDU.insSignNep413, path: .ledgerDefault, payload: message))
        XCTAssertEqual(messageResponse.suffix(2), StatusWord.ok.bytes)
        XCTAssertTrue(key.publicKey.isValidSignature(messageResponse.dropLast(2), for: SigningDigest.nep413(message)))

        let delegate = Data(Data(base64Encoded: Fixtures.delegatePrefixedBorsh)!.dropFirst(4))
        let delegateResponse = await exchange(session, NearAPDU.signCommands(
            ins: NearAPDU.insSignNep366, path: .ledgerDefault, payload: delegate))
        XCTAssertEqual(delegateResponse.suffix(2), StatusWord.ok.bytes)
        XCTAssertTrue(key.publicKey.isValidSignature(delegateResponse.dropLast(2), for: SigningDigest.delegateAction(delegate)))

        XCTAssertEqual(presenter.shown.map(\.kind), [.message, .delegateAction])
        let kinds = await history.all().map(\.kind)
        XCTAssertEqual(kinds, [.delegateAction, .message])
    }

    func testPublicKeyAndDashboardCommands() async throws {
        let (session, presenter, _) = try makeSession(answers: [true, true, true])

        let appName = await session.handle(APDUCommand(cla: 0xB0, ins: 0x01, p1: 0, p2: 0).serialized)
        XCTAssertEqual(appName.suffix(2), StatusWord.ok.bytes)
        XCTAssertEqual(appName[1], 4)
        XCTAssertEqual(String(data: appName[2..<6], encoding: .ascii), "NEAR")

        let open = await session.handle(APDUCommand(cla: 0xE0, ins: 0xD8, p1: 0, p2: 0, data: Data("NEAR".utf8)).serialized)
        XCTAssertEqual(open, StatusWord.ok.bytes)

        let version = await session.handle(NearAPDU.getVersion().serialized)
        XCTAssertEqual(version, Data([2, 4, 3]) + StatusWord.ok.bytes)

        // Silent request for an unknown path still needs approval (it unlocks the seed).
        let first = await session.handle(NearAPDU.getPublicKey(path: .ledgerDefault, display: false).serialized)
        XCTAssertEqual(first.suffix(2), StatusWord.ok.bytes)
        XCTAssertEqual(PublicKey.ed25519(first.dropLast(2)).description, Fixtures.ledgerPublicKey)
        XCTAssertEqual(presenter.shownCount, 1)
        // With automatic sharing off, a known path asks again, silent or not.
        let second = await session.handle(NearAPDU.getPublicKey(path: .ledgerDefault, display: false).serialized)
        XCTAssertEqual(second, first)
        XCTAssertEqual(presenter.shownCount, 2)
        // Only the first one unlocks the key; the approval screen shows Face ID for that one only.
        XCTAssertEqual(presenter.shown.map(\.needsUnlock), [true, false])
        let third = await session.handle(NearAPDU.getPublicKey(path: .ledgerDefault, display: true).serialized)
        XCTAssertEqual(third, first)
        XCTAssertEqual(presenter.shownCount, 3)
    }

    func testAutoShareKnownPublicKeys() async throws {
        let history = HistoryStore(fileURL: nil)
        let presenter = ScriptedPresenter(answers: [true, false])
        let vault = InMemoryKeyVault(material: try KeyMaterial.fromMnemonic(Fixtures.phrase))
        let service = SignerService(vault: vault, presenter: presenter, history: history)
        await service.setAutoShareKnownPublicKeys(true)
        let session = NearAppSession(service: service, transport: "test")
        // First export of a path still asks.
        let first = await session.handle(NearAPDU.getPublicKey(path: .ledgerDefault, display: true).serialized)
        XCTAssertEqual(first.suffix(2), StatusWord.ok.bytes)
        // Known path with the display flag (what near-cli-rs sends before every signature), or
        // without it: no prompt.
        let second = await session.handle(NearAPDU.getPublicKey(path: .ledgerDefault, display: true).serialized)
        XCTAssertEqual(second, first)
        let silent = await session.handle(NearAPDU.getPublicKey(path: .ledgerDefault, display: false).serialized)
        XCTAssertEqual(silent, first)
        XCTAssertEqual(presenter.shownCount, 1)
        // A new path asks again, and a rejection is recorded.
        let other = await session.handle(NearAPDU.getPublicKey(path: BIP32Path(hardened: [44, 397, 0, 0, 7]), display: true).serialized)
        XCTAssertEqual(other, StatusWord.userRejected.bytes)
        let outcomes = await history.all().map(\.outcome)
        XCTAssertEqual(outcomes, [.rejected, .approved])
    }

    /// "Quit app" shows the dashboard, so hosts that wait for it stop repeating the command.
    func testQuitAppShowsTheDashboard() async throws {
        let (session, _, _) = try makeSession(answers: [])
        func appName() async -> String? {
            let response = await session.handle(APDUCommand(cla: 0xB0, ins: 0x01, p1: 0, p2: 0).serialized)
            guard response.suffix(2) == StatusWord.ok.bytes, response.count > 2 else { return nil }
            return String(data: response.dropFirst(2).prefix(Int(response[1])), encoding: .ascii)
        }
        let quit = APDUCommand(cla: 0xB0, ins: 0xA7, p1: 0, p2: 0).serialized
        let firmware = APDUCommand(cla: 0xE0, ins: 0x01, p1: 0, p2: 0).serialized

        // Inside NEAR, firmware details are refused as by the NEAR Ledger app.
        let inApp = await session.handle(firmware)
        XCTAssertEqual(inApp, StatusWord.claNotSupported.bytes)

        // Ledger Live's device manager: quit until the dashboard shows, then ask for firmware
        // details. The error ends it, and NEAR is open again.
        var name = await appName()
        XCTAssertEqual(name, "NEAR")
        var answer = await session.handle(quit)
        XCTAssertEqual(answer, StatusWord.ok.bytes)
        name = await appName()
        XCTAssertEqual(name, "BOLOS")
        answer = await session.handle(firmware)
        XCTAssertEqual(answer, StatusWord.functionNotSupported.bytes)
        name = await appName()
        XCTAssertEqual(name, "NEAR")

        // near-connect and near-ledger-rs open NEAR from the dashboard.
        _ = await session.handle(quit)
        answer = await session.handle(APDUCommand(cla: 0xE0, ins: 0xD8, p1: 0, p2: 0, data: Data("NEAR".utf8)).serialized)
        XCTAssertEqual(answer, StatusWord.ok.bytes)
        name = await appName()
        XCTAssertEqual(name, "NEAR")

        // A NEAR command works on the dashboard too, and opens NEAR.
        _ = await session.handle(quit)
        let version = await session.handle(NearAPDU.getVersion().serialized)
        XCTAssertEqual(version, Data([2, 4, 3]) + StatusWord.ok.bytes)
        name = await appName()
        XCTAssertEqual(name, "NEAR")
    }

    func testErrorsForBadCommands() async throws {
        let (session, _, _) = try makeSession(answers: [])
        let unknownIns = await session.handle(APDUCommand(cla: 0x80, ins: 0x55, p1: 0, p2: 0).serialized)
        XCTAssertEqual(unknownIns, StatusWord.insNotSupported.bytes)
        let unknownCla = await session.handle(APDUCommand(cla: 0x12, ins: 0x01, p1: 0, p2: 0).serialized)
        XCTAssertEqual(unknownCla, StatusWord.claNotSupported.bytes)
        let shortPath = await session.handle(APDUCommand(cla: 0x80, ins: 0x04, p1: 1, p2: 0x57, data: Data([0x80, 0, 0, 44])).serialized)
        XCTAssertEqual(shortPath, StatusWord.badPath.bytes)
        let unhardened = await session.handle(NearAPDU.getPublicKey(path: BIP32Path(components: [44, 397, 0, 0, 1]), display: false).serialized)
        XCTAssertEqual(unhardened, StatusWord.badPath.bytes)
        let badP1 = await session.handle(APDUCommand(cla: 0x80, ins: 0x02, p1: 0x42, p2: 0x57, data: Data([1])).serialized)
        XCTAssertEqual(badP1, StatusWord.wrongP1P2.bytes)
        let truncated = await session.handle(Data([0x80, 0x02, 0x80, 0x57, 10, 1, 2]))
        XCTAssertEqual(truncated, StatusWord.wrongLength.bytes)
    }

    /// A garbled APDU drops a half-received request, so the host's retry starts clean.
    func testGarbledAPDUDropsPartialRequest() async throws {
        let (session, presenter, _) = try makeSession(answers: [true])
        let payload = try XCTUnwrap(Data(base64Encoded: Fixtures.transactions[0].borsh))
        let commands = NearAPDU.signCommands(ins: NearAPDU.insSignTransaction, path: .ledgerDefault,
                                             payload: payload, chunkSize: 16)
        let first = await session.handle(commands[0].serialized)
        XCTAssertEqual(first, StatusWord.ok.bytes)
        let garbled = await session.handle(Data([0x80, 0x02, 0x00, 0x57, 10, 1, 2]))
        XCTAssertEqual(garbled, StatusWord.wrongLength.bytes)

        let response = await exchange(session, commands)
        XCTAssertEqual(response.suffix(2), StatusWord.ok.bytes)
        XCTAssertEqual(presenter.shownCount, 1)
    }

    func testNoKeyReportsLocked() async throws {
        let service = SignerService(vault: InMemoryKeyVault(material: nil), presenter: ScriptedPresenter(answers: [true]),
                                    history: HistoryStore(fileURL: nil))
        let session = NearAppSession(service: service, transport: "test")
        let response = await session.handle(NearAPDU.getPublicKey(path: .ledgerDefault, display: false).serialized)
        XCTAssertEqual(response, StatusWord.locked.bytes)
    }

    // MARK: Framing

    func testBLEFramingRoundTrip() throws {
        for packetSize in [20, 23, 156, 255] {
            for length in [0, 1, 14, 15, 16, 200, 1000] {
                let message = Data((0..<length).map { UInt8($0 % 251) })
                let frames = BLEFraming.frames(for: message, packetSize: packetSize)
                XCTAssertTrue(frames.allSatisfy { $0.count <= packetSize })
                var assembler = BLEFrameAssembler()
                var result: Data?
                for (index, frame) in frames.enumerated() {
                    let event = try assembler.receive(frame)
                    if index == frames.count - 1 {
                        guard case let .apdu(apdu) = event else { return XCTFail("no apdu at end") }
                        result = apdu
                    } else {
                        XCTAssertEqual(event, BLEFrameAssembler.Event.none)
                    }
                }
                XCTAssertEqual(result, message, "packet \(packetSize) length \(length)")
            }
        }
    }

    func testBLEFramingMatchesLedgerLayout() throws {
        let frames = BLEFraming.frames(for: Data([0xAA, 0xBB, 0xCC]), packetSize: 20)
        XCTAssertEqual(frames, [Data([0x05, 0, 0, 0, 3, 0xAA, 0xBB, 0xCC])])
        let long = BLEFraming.frames(for: Data(repeating: 1, count: 20), packetSize: 20)
        XCTAssertEqual(long.map { Array($0.prefix(3)) }, [[5, 0, 0], [5, 0, 1]])
        XCTAssertEqual(long[0].count, 20)
        XCTAssertEqual(long[1].count, 3 + 5)
        XCTAssertEqual(BLEFraming.mtuResponse(packetSize: 156), Data([8, 0, 0, 0, 0, 156]))
        var assembler = BLEFrameAssembler()
        XCTAssertEqual(try assembler.receive(Data([8, 0, 0, 0, 0])), .mtuRequest)
        XCTAssertThrowsError(try assembler.receive(Data([0x05, 0, 2, 1])))
        var fresh = BLEFrameAssembler()
        XCTAssertThrowsError(try fresh.receive(Data([0x07, 0, 0])))
        // A new sequence 0 restarts reassembly after a lost packet.
        _ = try assembler.receive(Data([0x05, 0, 0, 0, 10, 1, 2]))
        XCTAssertEqual(try assembler.receive(Data([0x05, 0, 0, 0, 1, 9])), .apdu(Data([9])))
    }

    func testTCPFraming() throws {
        var decoder = TCPFrameDecoder()
        let a = TCPFrameDecoder.encodeRequest(Data([1, 2, 3]))
        let b = TCPFrameDecoder.encodeRequest(Data([4]))
        let stream = a + b
        decoder.append(stream.prefix(2))
        XCTAssertNil(try decoder.nextMessage())
        decoder.append(stream.dropFirst(2))
        XCTAssertEqual(try decoder.nextMessage(), Data([1, 2, 3]))
        XCTAssertEqual(try decoder.nextMessage(), Data([4]))
        XCTAssertNil(try decoder.nextMessage())
        XCTAssertEqual(TCPFrameDecoder.encodeResponse(Data([7, 0x90, 0])), Data([0, 0, 0, 1, 7, 0x90, 0]))
        var hostile = TCPFrameDecoder()
        hostile.append(Data([0x7F, 0, 0, 0]))
        XCTAssertThrowsError(try hostile.nextMessage())
    }

    func testMismatchOnNewPathDoesNotShareItsKey() async throws {
        // The fixture is signed by Account 1's key; the host asks to sign it with Account 2.
        let vault = InMemoryKeyVault(material: try KeyMaterial.fromMnemonic(Fixtures.phrase))
        let presenter = ScriptedPresenter(answers: [true])
        let service = SignerService(vault: vault, presenter: presenter, history: HistoryStore(fileURL: nil))
        let fixture = try XCTUnwrap(Fixtures.transactions.first { $0.name == "transfer" })
        let accountTwo = BIP32Path(hardened: [44, 397, 0, 0, 2])

        let result = await service.sign(kind: .transaction, path: accountTwo,
                                        payload: Data(base64Encoded: fixture.borsh)!, transport: "test")
        XCTAssertEqual(result, .failure(.publicKeyMismatch))
        let cached = await vault.cachedPublicKey(for: accountTwo)
        XCTAssertNil(cached, "a later silent public key request must still ask")
    }

    func testCancelledAuthenticationIsARejection() async throws {
        /// Vault whose Face ID prompt the user dismisses.
        final class CancellingVault: KeyVault, @unchecked Sendable {
            let inner = InMemoryKeyVault(material: try! KeyMaterial.fromMnemonic(Fixtures.phrase))
            var hasKey: Bool { true }
            func cachedPublicKey(for path: BIP32Path) async -> Data? { await inner.cachedPublicKey(for: path) }
            func derivePublicKey(for path: BIP32Path, reason: String) async throws -> Data {
                throw KeyError.authenticationCancelled
            }
            func sign(digest: Data, path: BIP32Path, expectedPublicKey: Data?, reason: String) async throws -> SignResult {
                throw KeyError.authenticationCancelled
            }
        }
        let presenter = ScriptedPresenter(answers: [true, true])
        let history = HistoryStore(fileURL: nil)
        let service = SignerService(vault: CancellingVault(), presenter: presenter, history: history)
        let fixture = try XCTUnwrap(Fixtures.transactions.first { $0.name == "transfer" })

        let signed = await service.sign(kind: .transaction, path: .ledgerDefault,
                                        payload: Data(base64Encoded: fixture.borsh)!, transport: "test")
        XCTAssertEqual(signed, .failure(.userRejected))
        XCTAssertEqual(presenter.shown.first?.signerId, "alice.testnet")
        let exported = await service.publicKey(path: .ledgerDefault, display: true, transport: "test")
        XCTAssertEqual(exported, .failure(.userRejected))

        let records = await history.all()
        XCTAssertEqual(records.map(\.outcome), [.rejected, .rejected])
        XCTAssertEqual(records.map(\.symbol), [.publicKey, .send])
        XCTAssertEqual(records.last?.failureReason, "authentication was cancelled")
    }

    // MARK: History

    func testHistoryPersistsAcrossLaunches() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("near-signer-tests-\(UUID().uuidString)")
            .appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = HistoryStore(fileURL: url, maxRecords: 3)
        for index in 0..<5 {
            try await store.append(HistoryRecord(kind: .transaction, outcome: .approved, transport: "test",
                                                 path: "m/0'", title: "tx \(index)", payload: Data([UInt8(index)])))
        }
        let reloaded = HistoryStore(fileURL: url)
        let titles = await reloaded.all().map(\.title)
        XCTAssertEqual(titles, ["tx 4", "tx 3", "tx 2"])
        let all = await reloaded.all()
        let first = try XCTUnwrap(all.first)
        try await reloaded.delete(id: first.id)
        let afterDelete = await HistoryStore(fileURL: url).all().count
        XCTAssertEqual(afterDelete, 2)
        try await reloaded.clear()
        let afterClear = await HistoryStore(fileURL: url).all()
        XCTAssertTrue(afterClear.isEmpty)
    }
}
