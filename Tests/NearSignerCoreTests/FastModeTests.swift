import Foundation
import XCTest
@testable import NearSignerCore

final class FastModeTests: XCTestCase {
    private let material = try! KeyMaterial.fromMnemonic(Fixtures.phrase)

    func testExtendedAPDUEncoding() throws {
        let small = APDUCommand(cla: 0x80, ins: 0x02, p1: 0, p2: 0x57, data: Data(repeating: 1, count: 255))
        XCTAssertEqual(small.serialized.count, 5 + 255)
        XCTAssertEqual(APDUCommand(small.serialized), small)

        let big = APDUCommand(cla: 0x80, ins: 0x02, p1: 0x80, p2: 0x57, data: Data(repeating: 2, count: 32 * 1024))
        let bytes = big.serialized
        XCTAssertEqual(Array(bytes.prefix(7)), [0x80, 0x02, 0x80, 0x57, 0x00, 0x80, 0x00])
        XCTAssertEqual(APDUCommand(bytes), big)

        // A short APDU with Lc = 0 stays short; a wrong extended length is rejected.
        XCTAssertEqual(APDUCommand(Data([0x80, 0x06, 0, 0, 0]))?.data, Data())
        XCTAssertNil(APDUCommand(Data([0x80, 0x02, 0, 0, 0, 0x01, 0x00, 1, 2])))
    }

    func testCapabilities() async throws {
        let session = NearAppSession(service: SignerService(vault: InMemoryKeyVault(material: material),
                                                            presenter: ScriptedPresenter(answers: []),
                                                            history: HistoryStore(fileURL: nil)),
                                     transport: "test")
        let response = await session.handle(NearAPDU.getCapabilities().serialized)
        XCTAssertEqual(response.suffix(2), StatusWord.ok.bytes)
        let capabilities = try XCTUnwrap(SignerCapabilities(response: response.dropLast(2)))
        XCTAssertEqual(capabilities, .current)
        XCTAssertTrue(capabilities.supportsExtendedAPDU)
        XCTAssertLessThanOrEqual(capabilities.maxChunk, NearAPDU.maxExtendedChunk)
        XCTAssertNil(SignerCapabilities(response: Data([0x90, 0x00])))
    }

    /// A 200 KB deployment in 32 KiB chunks, over the emulated BLE link: few round trips, same signature.
    func testFastSigningOverBLE() async throws {
        var code = Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])
        code.append(Data((0..<200_000).map { UInt8($0 & 0xFF) }))
        let key = try material.privateKey(for: .ledgerDefault)
        let payload = Transaction(signerId: "alice.near", publicKey: .ed25519(key.publicKey.rawRepresentation), nonce: 1,
                                  receiverId: "alice.near", blockHash: Data(repeating: 3, count: 32),
                                  actions: [.deployContract(code: code)]).borsh
        let service = SignerService(vault: InMemoryKeyVault(material: material), presenter: ScriptedPresenter(answers: [true]),
                                    history: HistoryStore(fileURL: nil))
        let link = BLELink(session: NearAppSession(service: service, transport: "test"), packetSize: 244)
        let commands = NearAPDU.signCommands(ins: NearAPDU.insSignTransaction, path: .ledgerDefault, payload: payload,
                                             chunkSize: SignerCapabilities.current.maxChunk)
        XCTAssertEqual(commands.count, Int((Double(payload.count + 20) / 32768).rounded(.up)))
        var response = Data()
        for command in commands {
            var assembler = BLEFrameAssembler()
            for packet in BLEFraming.frames(for: command.serialized, packetSize: 244) {
                for notification in await link.receive(packet) {
                    if case let .apdu(data) = try assembler.receive(notification) { response = data }
                }
            }
        }
        XCTAssertEqual(response.suffix(2), StatusWord.ok.bytes)
        XCTAssertTrue(key.publicKey.isValidSignature(response.dropLast(2), for: SigningDigest.transaction(payload)))
    }
}
