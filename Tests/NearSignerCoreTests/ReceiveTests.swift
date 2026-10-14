import Foundation
import XCTest
@testable import NearSignerCore

/// Collects signer events.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SignerEvent] = []
    func append(_ event: SignerEvent) { lock.withLock { events.append(event) } }
    var all: [SignerEvent] { lock.withLock { events } }
}

final class ReceiveTests: XCTestCase {
    private let material = try! KeyMaterial.fromMnemonic(Fixtures.phrase)

    private func deployTransaction(codeSize: Int, initCall: Bool = false) throws -> Data {
        var code = Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])
        code.append(Data(repeating: 0x42, count: codeSize))
        var actions: [Action] = [.deployContract(code: code)]
        if initCall {
            actions.append(.functionCall(FunctionCallAction(methodName: "new", args: Data("{}".utf8), gas: 1, deposit: .zero)))
        }
        return Transaction(signerId: "alice.near", publicKey: .ed25519(try material.privateKey(for: .ledgerDefault).publicKey.rawRepresentation),
                           nonce: 1, receiverId: "alice.near", blockHash: Data(repeating: 1, count: 32), actions: actions).borsh
    }

    func testSizeProbe() throws {
        let deploy = try deployTransaction(codeSize: 100_000)
        // The total is known as soon as the code length has arrived.
        XCTAssertNil(TransactionSizeProbe.expectedSize(ofPrefix: deploy.prefix(20)))
        XCTAssertEqual(TransactionSizeProbe.expectedSize(ofPrefix: deploy.prefix(250)), deploy.count)
        XCTAssertEqual(TransactionSizeProbe.expectedSize(ofPrefix: deploy.prefix(50_000)), deploy.count)
        XCTAssertEqual(TransactionSizeProbe.expectedSize(ofPrefix: deploy), deploy.count)

        // A call after the code: a lower bound until the call arrives, then exact.
        let withInit = try deployTransaction(codeSize: 100_000, initCall: true)
        let bound = try XCTUnwrap(TransactionSizeProbe.expectedSize(ofPrefix: withInit.prefix(250)))
        XCTAssertLessThan(bound, withInit.count)
        XCTAssertGreaterThan(bound, 100_000)
        XCTAssertEqual(TransactionSizeProbe.expectedSize(ofPrefix: withInit), withInit.count)

        // Every fixture transaction is measured exactly or not at all.
        for fixture in Fixtures.transactions {
            let bytes = Data(base64Encoded: fixture.borsh)!
            if let size = TransactionSizeProbe.expectedSize(ofPrefix: bytes) {
                XCTAssertEqual(size, bytes.count, fixture.name)
            }
        }
    }

    private func makeSession(answers: [Bool]) -> (NearAppSession, EventLog, HistoryStore) {
        let log = EventLog()
        let history = HistoryStore(fileURL: nil)
        let service = SignerService(vault: InMemoryKeyVault(material: material),
                                    presenter: ScriptedPresenter(answers: answers), history: history) { log.append($0) }
        return (NearAppSession(service: service, transport: "test"), log, history)
    }

    func testLargeRequestsReportProgressThenEnd() async throws {
        let payload = try deployTransaction(codeSize: 40_000)
        let (session, log, _) = makeSession(answers: [true])
        let commands = NearAPDU.signCommands(ins: NearAPDU.insSignTransaction, path: .ledgerDefault, payload: payload)
        var last = Data()
        for command in commands { last = await session.handle(command.serialized) }
        XCTAssertEqual(last.suffix(2), StatusWord.ok.bytes)

        let events = log.all
        let progress = events.compactMap { event -> ReceiveProgress? in
            if case let .receiving(progress) = event { return progress }
            return nil
        }
        XCTAssertGreaterThan(progress.count, 3)
        XCTAssertTrue(progress.allSatisfy { $0.expected == payload.count })
        XCTAssertEqual(progress.map(\.received), progress.map(\.received).sorted())
        XCTAssertGreaterThanOrEqual(progress[0].received, NearAppSession.progressThreshold)
        // The progress ends before the approval starts.
        let endIndex = try XCTUnwrap(events.firstIndex { if case .receiveEnded = $0 { return true } else { return false } })
        let startIndex = try XCTUnwrap(events.firstIndex { if case .requestStarted = $0 { return true } else { return false } })
        XCTAssertLessThan(endIndex, startIndex)
    }

    func testSmallRequestsReportNothing() async throws {
        let (session, log, _) = makeSession(answers: [true])
        let payload = Data(base64Encoded: Fixtures.transactions[0].borsh)!
        for command in NearAPDU.signCommands(ins: NearAPDU.insSignTransaction, path: .ledgerDefault, payload: payload) {
            _ = await session.handle(command.serialized)
        }
        XCTAssertFalse(log.all.contains { if case .receiving = $0 { return true } else { return false } })
    }

    func testCancellingStopsTheHost() async throws {
        let payload = try deployTransaction(codeSize: 60_000)
        let log = EventLog()
        let history = HistoryStore(fileURL: nil)
        let service = SignerService(vault: InMemoryKeyVault(material: material),
                                    presenter: ScriptedPresenter(answers: [true]), history: history) { log.append($0) }
        let session = NearAppSession(service: service, transport: "test")
        let commands = NearAPDU.signCommands(ins: NearAPDU.insSignTransaction, path: .ledgerDefault, payload: payload)
        var responses: [Data] = []
        for command in commands {
            let response = await session.handle(command.serialized)
            responses.append(response)
            if response != StatusWord.ok.bytes { break }
            // Cancel once progress is showing, as the app's Cancel button does.
            if let id = log.all.lazy.compactMap({ event -> UUID? in
                if case let .receiving(progress) = event { return progress.id }
                return nil
            }).first {
                await service.cancelReceiving(id)
            }
        }
        XCTAssertEqual(responses.last, StatusWord.userRejected.bytes)
        XCTAssertLessThan(responses.count, commands.count, "the host is stopped before the end")
        let records = await history.all()
        XCTAssertEqual(records.first?.title, "Request cancelled while receiving")
        XCTAssertEqual(records.first?.outcome, .rejected)
        XCTAssertTrue(log.all.contains { if case .receiveEnded = $0 { return true } else { return false } })
    }
}
