import Foundation
import XCTest
@testable import NearSignerCore

final class AccountTests: XCTestCase {
    private let material = try! KeyMaterial.fromMnemonic(Fixtures.phrase)

    private func publicKey(_ path: BIP32Path) throws -> Data {
        try material.privateKey(for: path).publicKey.rawRepresentation
    }

    func testStandardPathsAndNames() {
        XCTAssertEqual(AccountBook.standardPath(index: 1), .ledgerDefault)
        XCTAssertEqual(AccountBook.standardIndex(of: .ledgerDefault), 1)
        XCTAssertEqual(AccountBook.standardIndex(of: BIP32Path("m/44'/397'/0'/0'/7'")!), 7)
        XCTAssertNil(AccountBook.standardIndex(of: BIP32Path("m/44'/397'/1'/0'/7'")!))
        XCTAssertNil(AccountBook.standardIndex(of: BIP32Path("m/44'/397'/0'/0'/7")!))
        XCTAssertEqual(AccountBook.defaultName(for: BIP32Path("m/44'/397'/0'/0'/2'")!), "Account 2")
        XCTAssertEqual(AccountBook.defaultName(for: BIP32Path("m/44'/397'/5'/0'/0'")!), "Custom account")
        XCTAssertTrue(AccountBook.isValidAccountPath(.ledgerDefault))
        XCTAssertFalse(AccountBook.isValidAccountPath(.nearCliSeedPhraseDefault))
        XCTAssertFalse(AccountBook.isValidAccountPath(BIP32Path("m/44'/397'/0'/0'/1")!))
    }

    func testAddingNumberingAndOrdering() throws {
        var book = AccountBook()
        XCTAssertEqual(book.nextStandardPath, .ledgerDefault)

        let first = try book.add(path: book.nextStandardPath, publicKey: try publicKey(.ledgerDefault))
        XCTAssertEqual(first.name, "Account 1")
        XCTAssertEqual(first.publicKeyString, Fixtures.ledgerPublicKey)
        XCTAssertEqual(first.implicitAccountId, first.publicKey.hexString)
        XCTAssertEqual(first.shortAddress.count, 13)

        let third = AccountBook.standardPath(index: 3)
        try book.add(path: third, publicKey: try publicKey(third), name: "  Savings  ")
        XCTAssertEqual(book.nextStandardPath, AccountBook.standardPath(index: 2))

        let custom = BIP32Path("m/44'/397'/1'/0'/0'")!
        try book.add(path: custom, publicKey: try publicKey(custom), date: Date(timeIntervalSince1970: 0))
        let second = AccountBook.standardPath(index: 2)
        try book.add(path: second, publicKey: try publicKey(second))

        XCTAssertEqual(book.accounts.map(\.name), ["Account 1", "Account 2", "Savings", "Custom account"])
        XCTAssertEqual(book.nextStandardPath, AccountBook.standardPath(index: 4))
        XCTAssertEqual(book.account(for: third)?.name, "Savings")

        XCTAssertThrowsError(try book.add(path: third, publicKey: try publicKey(third))) { error in
            XCTAssertEqual(error as? AccountError, .duplicatePath(third.description))
        }
        XCTAssertThrowsError(try book.add(path: .nearCliSeedPhraseDefault, publicKey: Data(count: 32))) { error in
            XCTAssertEqual(error as? AccountError, .invalidPath(BIP32Path.nearCliSeedPhraseDefault.description))
        }

        try book.rename(id: first.id, to: "  Main  ")
        XCTAssertEqual(book.account(id: first.id)?.name, "Main")
        XCTAssertThrowsError(try book.rename(id: first.id, to: "   "))
        try book.rename(id: first.id, to: String(repeating: "x", count: 100))
        XCTAssertEqual(book.account(id: first.id)?.name.count, AccountBook.maxNameLength)

        book.remove(id: first.id)
        XCTAssertNil(book.account(for: .ledgerDefault))
        XCTAssertEqual(book.nextStandardPath, .ledgerDefault)
    }

    func testPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("near-signer-accounts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("accounts.json")
        XCTAssertEqual(AccountBook.load(from: url), AccountBook())

        var book = AccountBook()
        try book.add(path: .ledgerDefault, publicKey: try publicKey(.ledgerDefault))
        try book.add(path: AccountBook.standardPath(index: 2), publicKey: try publicKey(AccountBook.standardPath(index: 2)))
        try book.save(to: url)
        XCTAssertEqual(AccountBook.load(from: url).accounts.map(\.path), book.accounts.map(\.path))
        XCTAssertEqual(AccountBook.load(from: url).accounts.map(\.publicKey), book.accounts.map(\.publicKey))

        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(AccountBook.load(from: url).accounts.isEmpty)
    }

    func testLinkedAccountIdsComeFromApprovedHistory() throws {
        let account = Account(name: "Account 1", path: .ledgerDefault, publicKey: try publicKey(.ledgerDefault))
        func record(_ signer: String?, _ outcome: HistoryRecord.Outcome, key: String? = nil) -> HistoryRecord {
            HistoryRecord(kind: .transaction, outcome: outcome, transport: "test", path: account.path.description,
                          title: "tx", signerId: signer, publicKey: key ?? account.publicKeyString)
        }
        let history = [
            record("bob.near", .approved),
            record("mallory.near", .rejected),
            record(account.implicitAccountId, .approved),
            record("alice.near", .approved),
            record("bob.near", .approved),
            record("other.near", .approved, key: Fixtures.cliPublicKey),
            record(nil, .approved),
        ]
        XCTAssertEqual(account.linkedAccountIds(in: history), ["bob.near", "alice.near"])
    }

    func testDisplaySymbolsAndTechnicalSections() throws {
        func display(_ name: String) throws -> RequestDisplay {
            let fixture = try XCTUnwrap(Fixtures.transactions.first { $0.name == name })
            return try PreparedRequest(kind: .transaction, payload: Data(base64Encoded: fixture.borsh)!).display
        }
        let transfer = try display("transfer")
        XCTAssertEqual(transfer.symbol, .send)
        XCTAssertEqual(transfer.network, "testnet")
        XCTAssertEqual(transfer.primarySections.map(\.title), ["Transfer"])
        XCTAssertEqual(transfer.technicalSections.map(\.title), ["Account", "Details"], "the transfer is not listed twice")
        XCTAssertFalse(transfer.primarySections.contains { $0.isTechnical })
        XCTAssertTrue(transfer.text.contains("Transaction hash"), "the terminal rendering keeps every section")

        XCTAssertEqual(try display("functionCall").symbol, .send, "ft_transfer is recognized")
        XCTAssertEqual(try display("createAccount").symbol, .createAccount)
        XCTAssertEqual(try display("deleteAccount").symbol, .deleteAccount)
        XCTAssertEqual(try display("addFunctionCallKey").symbol, .addKey)
        XCTAssertEqual(try display("deployGlobalByHash").symbol, .deploy)

        let message = try PreparedRequest(kind: .nep413, payload: Data(base64Encoded: Fixtures.nep413Payload)!).display
        XCTAssertEqual(message.symbol, .message)
        XCTAssertEqual(message.primarySections.flatMap(\.fields).map(\.label), ["Recipient (app)", "Message", "Callback URL"])
        XCTAssertEqual(message.technicalSections.flatMap(\.fields).map(\.label), ["Nonce", "Signed digest"])

        let delegate = try PreparedRequest(kind: .nep366, payload: Data(base64Encoded: Fixtures.delegatePrefixedBorsh)!.dropFirst(4)).display
        XCTAssertEqual(delegate.technicalSections.count, 1)
    }

    func testHistoryRecordsFromOlderVersionsDecode() throws {
        let json = """
            [{"id":"6B3C2C55-3F6E-4B7E-9C55-1D2B3C4D5E6F","date":"2026-01-02T03:04:05Z","kind":"transaction",
              "outcome":"approved","transport":"USB / local TCP","path":"m/44'/397'/0'/0'/1'","title":"Send 1 NEAR to bob.near",
              "payload":""}]
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([HistoryRecord].self, from: Data(json.utf8))
        XCTAssertEqual(records.first?.title, "Send 1 NEAR to bob.near")
        XCTAssertNil(records.first?.symbol)
    }
}
