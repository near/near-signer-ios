import Foundation
import XCTest
@testable import NearSignerCore

final class WalletTests: XCTestCase {
    private let first = try! KeyMaterial.fromMnemonic(Fixtures.phrase)
    private let second = try! KeyMaterial.fromMnemonic(
        BIP39.mnemonic(fromEntropy: Data(repeating: 7, count: 32)).joined(separator: " "))
    private let imported = try! KeyMaterial.fromNearSecretKey(Fixtures.cliSecretKey)

    private func key(_ material: KeyMaterial, _ path: BIP32Path = .ledgerDefault) throws -> Data {
        try material.privateKey(for: path).publicKey.rawRepresentation
    }

    private func wallet(_ material: KeyMaterial, name: String = "") throws -> Wallet {
        var wallet = Wallet(name: name, kind: material.derivesFromPath ? .recoveryPhrase : .privateKey)
        try wallet.book.add(path: .ledgerDefault, publicKey: try key(material))
        return wallet
    }

    func testAddingNamingActivatingAndRemoving() throws {
        var list = WalletList()
        XCTAssertNil(list.activeWallet)
        let a = try wallet(first)
        try list.add(a)
        let b = try wallet(second)
        try list.add(b, activate: false)
        let c = try wallet(imported, name: "  Old CLI key  ")
        try list.add(c, activate: false)

        XCTAssertEqual(list.wallets.map(\.name), ["Wallet 1", "Wallet 2", "Old CLI key"])
        XCTAssertEqual(list.nextDefaultName(for: .privateKey), "Imported key 2")
        XCTAssertEqual(list.activeWallet?.id, a.id)

        list.activate(id: b.id)
        XCTAssertEqual(list.activeWallet?.id, b.id)
        try list.rename(id: b.id, to: "Savings")
        XCTAssertThrowsError(try list.rename(id: b.id, to: " "))

        // The same secret cannot be added twice, whatever the name.
        XCTAssertThrowsError(try list.add(try wallet(second, name: "Again"))) { error in
            XCTAssertEqual(error as? WalletError, .duplicate(existing: "Savings"))
        }

        list.remove(id: b.id)
        XCTAssertEqual(list.activeWallet?.id, a.id, "removing the active wallet activates another")
        list.removeAll()
        XCTAssertTrue(list.isEmpty)
    }

    func testRequestsRouteToTheWalletThatOwnsTheKey() throws {
        var list = WalletList()
        let a = try wallet(first)
        let b = try wallet(second)
        let c = try wallet(imported)
        try list.add(a)
        try list.add(b, activate: false)
        try list.add(c, activate: false)

        // Public key requests and messages (no key named) go to the active wallet.
        XCTAssertEqual(list.walletForRequest(path: .ledgerDefault, expectedPublicKey: nil)?.id, a.id)
        // A transaction signed by wallet B's Account 1 goes to B, even while A is active.
        XCTAssertEqual(list.walletForRequest(path: .ledgerDefault, expectedPublicKey: try key(second))?.id, b.id)
        // An imported key answers every path.
        let otherPath = AccountBook.standardPath(index: 5)
        XCTAssertEqual(list.walletForRequest(path: otherPath, expectedPublicKey: try key(imported))?.id, c.id)
        // A key nobody knows falls back to the active wallet, where the vault reports the mismatch.
        XCTAssertEqual(list.walletForRequest(path: .ledgerDefault, expectedPublicKey: Data(count: 32))?.id, a.id)
        XCTAssertEqual(list.walletForRequest(path: .ledgerDefault, expectedPublicKey: Data())?.id, a.id)

        let owner = try XCTUnwrap(list.owner(ofPublicKey: PublicKey.ed25519(try key(second)).description))
        XCTAssertEqual(owner.wallet.id, b.id)
        XCTAssertEqual(owner.account.name, "Account 1")
    }

    func testRememberingAndEditingAccounts() throws {
        var list = WalletList()
        let a = try wallet(first)
        let c = try wallet(imported)
        try list.add(a)
        try list.add(c, activate: false)

        let third = AccountBook.standardPath(index: 3)
        list.rememberAccount(walletID: a.id, path: third, publicKey: try key(first, third))
        list.rememberAccount(walletID: a.id, path: third, publicKey: try key(first, third))
        XCTAssertEqual(list.wallet(id: a.id)?.accounts.map(\.name), ["Account 1", "Account 3"])
        // An imported key stays a single account.
        list.rememberAccount(walletID: c.id, path: third, publicKey: try key(imported))
        XCTAssertEqual(list.wallet(id: c.id)?.accounts.count, 1)
        XCTAssertFalse(try XCTUnwrap(list.wallet(id: c.id)).canAddAccounts)

        let accountThree = try XCTUnwrap(list.wallet(id: a.id)?.book.account(for: third))
        try list.renameAccount(id: accountThree.id, to: "Trading")
        XCTAssertEqual(list.account(id: accountThree.id)?.account.name, "Trading")
        list.removeAccount(id: accountThree.id)
        XCTAssertEqual(list.wallet(id: a.id)?.accounts.count, 1)
        let last = try XCTUnwrap(list.wallet(id: a.id)?.accounts.first)
        list.removeAccount(id: last.id)
        XCTAssertEqual(list.wallet(id: a.id)?.accounts.count, 1, "a wallet keeps at least one account")
    }

    func testPersistence() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("near-signer-wallets-\(UUID().uuidString)").appendingPathComponent("wallets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var list = WalletList()
        try list.add(try wallet(first))
        try list.add(try wallet(imported), activate: true)
        try list.save(to: url)
        // Dates are stored with whole seconds, so compare everything else.
        guard case let .loaded(loaded) = WalletList.load(from: url) else { return XCTFail("expected a list") }
        XCTAssertEqual(loaded.wallets.map(\.id), list.wallets.map(\.id))
        XCTAssertEqual(loaded.wallets.map(\.name), list.wallets.map(\.name))
        XCTAssertEqual(loaded.wallets.map(\.kind), list.wallets.map(\.kind))
        XCTAssertEqual(loaded.wallets.flatMap(\.accounts).map(\.publicKey), list.wallets.flatMap(\.accounts).map(\.publicKey))
        XCTAssertEqual(loaded.activeWalletID, list.activeWalletID)
        // A damaged file is reported as such, never as "no wallets".
        try Data("{".utf8).write(to: url)
        guard case .unreadable = WalletList.load(from: url) else { return XCTFail("expected unreadable") }
        try FileManager.default.removeItem(at: url)
        guard case .missing = WalletList.load(from: url) else { return XCTFail("expected missing") }
    }

    func testAccountNames() throws {
        XCTAssertTrue(NearFormat.isValidAccountId("alice.near"))
        XCTAssertTrue(NearFormat.isValidAccountId("a-b_c.sub.testnet"))
        XCTAssertTrue(NearFormat.isValidAccountId(String(repeating: "f", count: 64)))
        for bad in ["a", "Alice.near", "alice..near", ".alice", "alice.", "al ice", "alice-.near", String(repeating: "a", count: 65)] {
            XCTAssertFalse(NearFormat.isValidAccountId(bad), bad)
        }
        XCTAssertFalse(NearFormat.isNamedAccount(String(repeating: "f", count: 64)))
        XCTAssertTrue(NearFormat.isNamedAccount("alice.near"))

        var list = WalletList()
        let a = try wallet(first)
        try list.add(a)
        let account = try XCTUnwrap(list.wallet(id: a.id)?.accounts.first)
        XCTAssertEqual(account.address, account.implicitAccountId)

        try list.setAccountId(accountID: account.id, to: "  Alice.Near ")
        XCTAssertEqual(list.account(id: account.id)?.account.accountId, "alice.near")
        XCTAssertEqual(list.account(id: account.id)?.account.address, "alice.near")
        XCTAssertThrowsError(try list.setAccountId(accountID: account.id, to: "not valid!"))
        try list.setAccountId(accountID: account.id, to: "")
        XCTAssertNil(list.account(id: account.id)?.account.accountId)
    }

    func testAccountNameSuggestionsComeFromApprovedRequests() throws {
        var list = WalletList()
        let a = try wallet(first)
        try list.add(a)
        let third = AccountBook.standardPath(index: 3)
        list.rememberAccount(walletID: a.id, path: third, publicKey: try key(first, third))
        let accountOne = try XCTUnwrap(list.wallet(id: a.id)?.book.account(for: .ledgerDefault))
        let accountThree = try XCTUnwrap(list.wallet(id: a.id)?.book.account(for: third))

        func record(_ tx: Transaction, outcome: HistoryRecord.Outcome = .approved) throws -> HistoryRecord {
            let prepared = try PreparedRequest(kind: .transaction, payload: tx.borsh)
            return prepared.historyRecord(outcome: outcome, transport: "test", path: .ledgerDefault, payload: tx.borsh,
                                          publicKey: try key(first), signature: nil, failureReason: nil)
        }
        func tx(signer: String, receiver: String, _ actions: [Action]) throws -> Transaction {
            Transaction(signerId: signer, publicKey: .ed25519(try key(first)), nonce: 1, receiverId: receiver,
                        blockHash: Data(repeating: 1, count: 32), actions: actions)
        }
        let addThree = Action.addKey(publicKey: .ed25519(try key(first, third)), accessKey: AccessKey(nonce: 0, permission: .fullAccess))
        let registrarArgs = #"{"new_account_id":"newbie.near","new_public_key":"\#(PublicKey.ed25519(try key(first, third)))"}"#
        let history = [
            // Rejected requests teach nothing.
            try record(try tx(signer: "mallory.near", receiver: "bob.near", [.transfer(deposit: U128(1))]), outcome: .rejected),
            try record(try tx(signer: "alice.near", receiver: "bob.near", [.transfer(deposit: U128(1))])),
            // A subaccount of the signer created with Account 3's key.
            try record(try tx(signer: "alice.near", receiver: "sub.alice.near", [.createAccount, addThree])),
            // CreateAccount on a non-subaccount cannot succeed on chain: ignored.
            try record(try tx(signer: "alice.near", receiver: "elsewhere.near", [.createAccount, addThree])),
            // The registrar creates top-level accounts.
            try record(try tx(signer: "alice.near", receiver: "near", [
                .functionCall(FunctionCallAction(methodName: "create_account", args: Data(registrarArgs.utf8), gas: 1, deposit: U128(1))),
            ])),
            // Any other contract proves nothing.
            try record(try tx(signer: "alice.near", receiver: "evil.near", [
                .functionCall(FunctionCallAction(methodName: "create_account",
                                                 args: Data(registrarArgs.replacingOccurrences(of: "newbie", with: "attacker").utf8),
                                                 gas: 1, deposit: U128(1))),
            ])),
        ]
        XCTAssertEqual(accountOne.suggestedAccountIds(in: history), ["alice.near"])
        XCTAssertEqual(accountThree.suggestedAccountIds(in: history), ["sub.alice.near", "newbie.near"])

        // Nothing is set until the user confirms; a confirmed name is no longer suggested.
        XCTAssertNil(list.account(id: accountOne.id)?.account.accountId)
        try list.setAccountId(accountID: accountOne.id, to: "alice.near")
        let confirmed = try XCTUnwrap(list.account(id: accountOne.id)?.account)
        XCTAssertEqual(confirmed.suggestedAccountIds(in: history), [])
    }
}
