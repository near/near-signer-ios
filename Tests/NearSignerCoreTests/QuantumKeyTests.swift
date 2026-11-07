import Foundation
import XCTest
@testable import NearSignerCore

/// ML-DSA-65 keys: the quantum-safe tree of a recovery phrase (NEP-649, same paths as ed25519),
/// imported seeds (NEP-645 1.0.1), their accounts, both transports, and the camera transfer's long
/// answers.
final class QuantumKeyTests: XCTestCase {
    private let material = try! KeyMaterial.fromMnemonic(Fixtures.phrase)
    private let quantumPath = AccountBook.standardPath(index: 1, keyType: .mlDsa65)
    private let digest = Data(SHA256.hash(data: Data("hello".utf8)))
    /// The test phrase's quantum-safe account 1, the simulator's.
    private let quantumAccountId = "0u93dqa2195458tvcqrytek0769bzh748ky9ej02ctp52zm628c8wg"

    private func makeTransaction(publicKey: PublicKey) -> Transaction {
        Transaction(version: .v0, signerId: "alice.testnet", publicKey: publicKey, nonce: .nonce(7),
                    receiverId: "bob.testnet", blockHash: Data(repeating: 9, count: 32),
                    actions: [.transfer(deposit: U128(1_000_000_000_000_000_000))])
    }

    private func sha256(_ data: Data) -> String { Data(SHA256.hash(data: data)).hexString }

    /// NEP-649's test vectors: its two mnemonic vectors and the first SLIP-10-shaped one.
    func testNEP649Vectors() throws {
        let phrase = "orbit pill once attitude garbage prefer afford what banner weird path present dream tide unfold despair inject physical lens battle fancy finish fever toward"
        let nep = try KeyMaterial.fromMnemonic(phrase)
        guard case let .bip39Seed(seed) = nep else { return XCTFail("a phrase is a seed") }
        XCTAssertEqual(seed.data.hexString.prefix(32), "85d44f13ba9c837a8fe51474cd7b7ed6")

        let full = BIP32Path(hardened: [44, 397, 0, 0, 1], keyType: .mlDsa65)
        XCTAssertEqual(try SLIP10.derive(seed: seed.data, path: full).hexString,
                       "908dd1a9a4bf8147e0ca25e95ac532827347a5f70eb7f7a3fc802c31448d6917")
        let fullKey = try nep.publicKey(for: full)
        XCTAssertEqual(sha256(fullKey), "c7d61d1b999a9a2b61b15df195189c922f4fcc8cc0aabea962de604c712a64df")
        XCTAssertEqual(PublicKey.mlDsa65(fullKey).handle,
                       .mlDsa65Hash(Data(hexString: "962ab10ffcfb67574145293f771369c0ae33643cf74d2c7887dc58002c26bb17")!))

        let short = BIP32Path(hardened: [44, 397, 0], keyType: .mlDsa65)
        XCTAssertEqual(try SLIP10.derive(seed: seed.data, path: short).hexString,
                       "e82fe9d0fd2a6af0798736fc2ed44907faf66d4a7a543499e7f1c04f18a7d3c4")
        XCTAssertEqual(sha256(try nep.publicKey(for: short)),
                       "377c1d992fb7b6f7975f9d1ad81c41ea80c27587ea8714b51e62057923937391")

        let slip = BIP32Path(components: [0, 1, 2, 2, 1_000_000_000].map { $0 | BIP32Path.hardenedOffset }, keyType: .mlDsa65)
        XCTAssertEqual(try SLIP10.derive(seed: Data(hexString: "000102030405060708090a0b0c0d0e0f")!, path: slip).hexString,
                       "3a7a1bdc57af0ee8a92da8ec4d900ecfeb269c13073127f032794af13f86c038")

        // NEP-645 1.0.1's secret-key string example: the same seed as the short path's.
        let imported = try KeyMaterial.fromNearSecretKey("ml-dsa-65:GdMxikMuRimoKStcDp78N8GXVK54z2HxgNhwKP6F3nMR")
        XCTAssertEqual(imported, .mlDsa65(SecretBytes(Data(hexString: "e82fe9d0fd2a6af0798736fc2ed44907faf66d4a7a543499e7f1c04f18a7d3c4")!)))
        XCTAssertEqual(PublicKey.mlDsa65(try imported.publicKey(for: short)).handle.description,
                       "ml-dsa-65-hash:9vwLPu52AWDLcuTv6NJrTudA6yAfUYQjScU5123i2pkr")
    }

    func testQuantumSafeAccountsAreTheSamePathsInTheirOwnTree() throws {
        XCTAssertEqual(quantumPath.pathText, "m/44'/397'/0'/0'/1'", "NEP-649's default path, the Ledger default")
        XCTAssertEqual(quantumPath.description, "m/44'/397'/0'/0'/1' (ML-DSA-65)")
        XCTAssertEqual(BIP32Path(quantumPath.description), quantumPath, "the description parses back")
        XCTAssertEqual(BIP32Path("m/44'/397'/0'/0'/1'", keyType: .mlDsa65), quantumPath)
        XCTAssertNotEqual(quantumPath, .ledgerDefault, "same path, another tree")
        XCTAssertEqual(quantumPath.serialized, BIP32Path.ledgerDefault.serialized, "the wire path is the same")
        XCTAssertEqual(quantumPath.inTree(.ed25519), .ledgerDefault)
        XCTAssertEqual(AccountBook.standardIndex(of: quantumPath), 1)
        XCTAssertEqual(AccountBook.defaultName(for: quantumPath), "Quantum-safe account 1")
        XCTAssertEqual(AccountBook.defaultName(for: .ledgerDefault), "Account 1")
        XCTAssertTrue(AccountBook.isValidAccountPath(quantumPath))
        XCTAssertNil(material.singleKeyType)
        XCTAssertTrue(material.derivesFromPath)

        // Stored paths: an ed25519 path keeps its old form; the tree is written only when it is ML-DSA-65.
        let encoded = try JSONEncoder().encode(BIP32Path.ledgerDefault)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("keyType"))
        XCTAssertEqual(try JSONDecoder().decode(BIP32Path.self, from: try JSONEncoder().encode(quantumPath)), quantumPath)

        let publicKey = try material.publicKey(for: quantumPath)
        XCTAssertEqual(publicKey.count, KeyType.mlDsa65.publicKeyLength)
        XCTAssertEqual(try KeyMaterial.fromMnemonic(Fixtures.phrase).publicKey(for: quantumPath), publicKey, "deterministic")
        XCTAssertNotEqual(try material.publicKey(for: AccountBook.standardPath(index: 2, keyType: .mlDsa65)), publicKey)
        XCTAssertEqual(PublicKey.ed25519(try material.publicKey(for: .ledgerDefault)).description, Fixtures.ledgerPublicKey,
                       "the ed25519 tree is untouched")
        XCTAssertThrowsError(try material.privateKey(for: quantumPath), "no ed25519 key in the ML-DSA-65 tree")
        XCTAssertEqual(UniversalAccount.id(forKey: .mlDsa65(publicKey)), quantumAccountId)

        // The trees share the algorithm, not the master key.
        let seed = Data(repeating: 1, count: 64)
        XCTAssertNotEqual(try SLIP10.derive(seed: seed, path: quantumPath), try SLIP10.derive(seed: seed, path: .ledgerDefault))

        let result = try material.sign(digest, path: quantumPath)
        XCTAssertEqual(result.keyType, .mlDsa65)
        XCTAssertEqual(result.publicKey, publicKey)
        XCTAssertEqual(result.signature.count, KeyType.mlDsa65.signatureLength)
        XCTAssertTrue(try KeyMaterial.verifyMLDSA65(signature: result.signature, digest: digest, publicKey: publicKey))
        XCTAssertFalse(try KeyMaterial.verifyMLDSA65(signature: result.signature, digest: Data(repeating: 1, count: 32),
                                                     publicKey: publicKey))
        XCTAssertEqual(try material.sign(digest, path: .ledgerDefault).keyType, .ed25519)
    }

    func testImportedSeedIsASingleQuantumSafeKey() throws {
        let seed = Data((0..<32).map { UInt8($0 * 3) })
        let imported = try KeyMaterial.fromNearSecretKey("ml-dsa-65:" + Base58.encode(seed))
        XCTAssertEqual(imported, .mlDsa65(SecretBytes(seed)))
        XCTAssertFalse(imported.derivesFromPath)
        XCTAssertEqual(imported.singleKeyType, .mlDsa65)
        XCTAssertEqual(try imported.publicKey(for: quantumPath), try imported.publicKey(for: BIP32Path(hardened: [44, 397, 0, 0, 9], keyType: .mlDsa65)),
                       "one key for every path of its tree")
        XCTAssertEqual(try imported.publicKey(for: quantumPath).count, 1952)
        XCTAssertThrowsError(try imported.publicKey(for: .ledgerDefault)) { error in
            XCTAssertEqual(error as? KeyError, .wrongKeyType(has: .mlDsa65, asked: .ed25519))
        }

        let stored = imported.serialized
        XCTAssertEqual(stored.first, 3)
        XCTAssertEqual(stored.count, 33)
        XCTAssertEqual(try KeyMaterial(serialized: stored), imported)
        XCTAssertThrowsError(try KeyMaterial(serialized: Data([3]) + Data(repeating: 0, count: 31)))
        // NEP-645: the expanded form is told apart by its length and refused with its own reason.
        XCTAssertThrowsError(try KeyMaterial.fromNearSecretKey("ml-dsa-65:" + Base58.encode(Data(repeating: 1, count: 4032)))) { error in
            XCTAssertTrue("\(error)".contains("expanded"))
        }
        XCTAssertThrowsError(try KeyMaterial.fromNearSecretKey("ml-dsa-65:" + Base58.encode(Data(repeating: 1, count: 64))))
        XCTAssertThrowsError(try KeyMaterial.fromNearSecretKey("ml-dsa-65:not base58 0OIl"))
    }

    func testAccountsOfAQuantumSafeKey() throws {
        let publicKey = try material.publicKey(for: quantumPath)
        var book = AccountBook()
        try book.add(path: .ledgerDefault, publicKey: try material.publicKey(for: .ledgerDefault))
        let account = try book.add(path: quantumPath, publicKey: publicKey)
        XCTAssertEqual(account.keyType, .mlDsa65, "the type is the path's tree")
        XCTAssertEqual(account.name, "Quantum-safe account 1")
        XCTAssertEqual(account.index, 1)
        XCTAssertTrue(account.publicKeyString.hasPrefix("ml-dsa-65:"))
        XCTAssertEqual(account.implicitAccountId, quantumAccountId)
        XCTAssertTrue(UniversalAccount.isUniversalId(account.implicitAccountId))
        XCTAssertEqual(account.address, account.implicitAccountId)
        XCTAssertEqual(account.shortAddress.count, 13)
        XCTAssertTrue(account.isQuantumSafe)
        XCTAssertEqual(book.accounts.map(\.name), ["Account 1", "Quantum-safe account 1"], "both at the same path, ed25519 first")
        XCTAssertEqual(book.account(for: quantumPath)?.id, account.id)
        XCTAssertEqual(book.account(for: .ledgerDefault)?.keyType, .ed25519)
        XCTAssertThrowsError(try book.add(path: quantumPath, publicKey: publicKey), "one account per path and tree")
        XCTAssertEqual(book.nextStandardPath(keyType: .mlDsa65), AccountBook.standardPath(index: 2, keyType: .mlDsa65))
        XCTAssertEqual(book.nextStandardPath, AccountBook.standardPath(index: 2))

        // Stored and read back, tree included; older lists are ed25519, and the short-lived format
        // that kept the type next to the path reads into the path.
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(Account.self, from: try encoder.encode(account)), account)
        let legacy = Account(name: "Old", path: .ledgerDefault, publicKey: Data(repeating: 2, count: 32))
        var json = try JSONSerialization.jsonObject(with: try encoder.encode(legacy)) as! [String: Any]
        XCTAssertNil(json["keyType"])
        XCTAssertEqual(try decoder.decode(Account.self, from: try JSONSerialization.data(withJSONObject: json)).keyType, .ed25519)
        json["keyType"] = "mlDsa65"
        XCTAssertEqual(try decoder.decode(Account.self, from: try JSONSerialization.data(withJSONObject: json)).path, quantumPath)

        // Wallets: a phrase has both trees; a single key one.
        var phrase = Wallet(kind: .recoveryPhrase, book: book, phraseWords: 24)
        XCTAssertTrue(phrase.canHaveQuantumSafeAccounts)
        XCTAssertFalse(phrase.hasShortPhrase)
        XCTAssertTrue(Wallet(kind: .recoveryPhrase, phraseWords: 12).canHaveQuantumSafeAccounts, "NEP-649: any phrase")
        XCTAssertTrue(Wallet(kind: .recoveryPhrase, phraseWords: 12).hasShortPhrase)
        XCTAssertNil(phrase.singleKeyType)
        var list = WalletList()
        try list.add(phrase)
        XCTAssertEqual(list.walletForRequest(path: quantumPath, expectedPublicKey: publicKey)?.id, phrase.id)
        XCTAssertEqual(list.owner(ofPublicKey: account.publicKeyString)?.account.id, account.id)
        list.rememberAccount(walletID: phrase.id, path: AccountBook.standardPath(index: 2, keyType: .mlDsa65),
                             publicKey: Data(repeating: 4, count: 1952))
        phrase = try XCTUnwrap(list.activeWallet)
        XCTAssertEqual(phrase.accounts.count, 3)
        XCTAssertEqual(phrase.accounts.last?.keyType, .mlDsa65)

        // A Secure Enclave key or an imported key: one key, every path of its tree, none of the other.
        var enclave = Wallet(kind: .secureEnclave)
        try enclave.book.add(path: .ledgerDefault, publicKey: publicKey, keyType: .mlDsa65)
        XCTAssertEqual(enclave.account(for: BIP32Path(hardened: [44, 397, 0, 0, 7], keyType: .mlDsa65))?.publicKey, publicKey)
        XCTAssertNil(enclave.account(for: .ledgerDefault))
        XCTAssertEqual(enclave.singleKeyType, .mlDsa65)
        XCTAssertFalse(enclave.canAddAccounts)
        XCTAssertFalse(enclave.canHaveQuantumSafeAccounts)
        XCTAssertEqual(list.nextDefaultName(for: .secureEnclave), "Secure Enclave key 1")
    }

    func testSigningThroughTheServiceWithAQuantumSafeAccount() async throws {
        let publicKey = try material.publicKey(for: quantumPath)
        let presenter = ScriptedPresenter(answers: [true, true, true])
        let history = HistoryStore(fileURL: nil)
        let service = SignerService(vault: InMemoryKeyVault(material: material), presenter: presenter, history: history)

        let exported = try await service.publicKey(path: quantumPath, display: true, transport: "Camera").get()
        XCTAssertEqual(exported, publicKey)
        XCTAssertTrue(presenter.shown.first?.display.text.contains("Quantum-safe account 1") == true)

        let tx = makeTransaction(publicKey: .mlDsa65(publicKey))
        let payload = tx.borsh
        let signature = try await service.sign(kind: .transaction, path: quantumPath, payload: payload, transport: "Camera").get()
        XCTAssertEqual(signature.count, 3309)
        XCTAssertTrue(try KeyMaterial.verifyMLDSA65(signature: signature, digest: SigningDigest.transaction(payload), publicKey: publicKey))
        XCTAssertEqual(presenter.shown.last?.publicKey, publicKey)
        let records = await history.all()
        XCTAssertEqual(records.first?.outcome, .approved)
        XCTAssertEqual(records.first?.publicKey, PublicKey.mlDsa65(publicKey).description)
        XCTAssertEqual(records.first?.signature, Signature.mlDsa65(signature).description)

        // The same transaction in the ed25519 tree names a key that account doesn't have: once
        // that account's key is known, the request is refused without a prompt.
        _ = try await service.publicKey(path: .ledgerDefault, display: true, transport: "Camera").get()
        let refused = await service.sign(kind: .transaction, path: .ledgerDefault, payload: payload, transport: "Camera")
        guard case .failure(.publicKeyMismatch) = refused else { return XCTFail("\(refused)") }
        XCTAssertEqual(presenter.shownCount, 3, "refused without a prompt")
    }

    func testLedgerProtocolCarriesQuantumSafeKeys() async throws {
        let publicKey = try material.publicKey(for: quantumPath)
        let presenter = ScriptedPresenter(answers: [true, true, true])
        let history = HistoryStore(fileURL: nil)
        let service = SignerService(vault: InMemoryKeyVault(material: material), presenter: presenter, history: history)
        let session = NearAppSession(service: service, transport: "Bluetooth")

        let key = await session.handle(NearAPDU.getPublicKey(path: quantumPath, display: true).serialized)
        XCTAssertEqual(key.suffix(2), StatusWord.ok.bytes)
        XCTAssertEqual(key.dropLast(2), publicKey)
        let payload = makeTransaction(publicKey: .mlDsa65(publicKey)).borsh
        var last = Data()
        for command in NearAPDU.signCommands(ins: NearAPDU.insSignTransaction, path: quantumPath, payload: payload, chunkSize: 250) {
            last = await session.handle(command.serialized)
        }
        XCTAssertEqual(last.suffix(2), StatusWord.ok.bytes)
        XCTAssertEqual(last.count, 3309 + 2)
        XCTAssertTrue(try KeyMaterial.verifyMLDSA65(signature: last.dropLast(2), digest: SigningDigest.transaction(payload),
                                                    publicKey: publicKey))
        XCTAssertEqual(presenter.shownCount, 2)
        let records = await history.all()
        XCTAssertEqual(records.map(\.outcome), [.approved, .approved])
        XCTAssertEqual(records.first?.transport, "Bluetooth")

        // Over the radio, a 3311-byte response takes many notifications and arrives whole.
        let link = BLELink(session: NearAppSession(service: service, transport: "BLE"), packetSize: 156)
        var assembler = BLEFrameAssembler()
        var response: Data?
        for packet in BLEFraming.frames(for: NearAPDU.getPublicKey(path: quantumPath, display: false).serialized, packetSize: 156) {
            for notification in await link.receive(packet) {
                if case let .apdu(message) = try assembler.receive(notification) { response = message }
            }
        }
        XCTAssertEqual(response?.count, 1952 + 2)
        XCTAssertEqual(response?.dropLast(2), publicKey)
    }

    func testTheTreeTravelsAsAFlag() async throws {
        // Ledger APDUs: P1 bit 0x40 on get public key and every signing chunk; P2 untouched.
        XCTAssertEqual(NearAPDU.getPublicKey(path: quantumPath, display: true).p1, 0x40)
        XCTAssertEqual(NearAPDU.getPublicKey(path: quantumPath, display: false).p1, 0x41)
        XCTAssertEqual(NearAPDU.getPublicKey(path: .ledgerDefault, display: false).p1, 0x01)
        let chunks = NearAPDU.signCommands(ins: NearAPDU.insSignTransaction, path: quantumPath, payload: Data(repeating: 1, count: 400))
        XCTAssertEqual(chunks.map(\.p1), [0x40, 0xC0])
        XCTAssertEqual(Set(chunks.map(\.p2)), [NearAPDU.networkMainnet])

        // The camera transfer: instruction bit 0x40, next to 0x80 (compressed).
        let keyRequest = OpticalRequest(kind: .publicKey, path: quantumPath, payload: Data())
        XCTAssertEqual(keyRequest.message.first, 0x44)
        XCTAssertEqual(OpticalRequest(message: keyRequest.message), keyRequest)
        XCTAssertEqual(OpticalRequest(message: keyRequest.message)?.path.keyType, .mlDsa65)
        let tx = OpticalRequest(kind: .transaction, path: quantumPath, payload: Data([1, 2, 3]))
        XCTAssertEqual(tx.message(deflatedPayload: Data([0x63, 0x64, 0x62, 0x06, 0x00])).first, 0xC2)
        XCTAssertEqual(OpticalRequest(message: tx.message(deflatedPayload: Data([0x63, 0x64, 0x62, 0x06, 0x00])))?.path, quantumPath)
        XCTAssertEqual(OpticalRequest(kind: .publicKey, path: .ledgerDefault, payload: Data()).message.first, 0x04)

        // A single key answers its own tree only: the other one is B00B, without a prompt.
        let presenter = ScriptedPresenter(answers: [true, true])
        let history = HistoryStore(fileURL: nil)
        let classic = SignerService(vault: InMemoryKeyVault(material: try KeyMaterial.fromNearSecretKey(Fixtures.ledgerSecretKey)),
                                    presenter: presenter, history: history)
        let refused = await classic.publicKey(path: quantumPath, display: true, transport: "Bluetooth")
        guard case .failure(.badPath) = refused else { return XCTFail("\(refused)") }
        XCTAssertEqual(presenter.shownCount, 0)
        let session = NearAppSession(service: classic, transport: "Bluetooth")
        let answer = await session.handle(NearAPDU.getPublicKey(path: quantumPath, display: false).serialized)
        XCTAssertEqual(answer, StatusWord.badPath.bytes)
        let record = await history.all().first
        XCTAssertTrue(record?.failureReason?.contains("classic key only") == true)
        let classicKey = await session.handle(NearAPDU.getPublicKey(path: .ledgerDefault, display: false).serialized)
        XCTAssertEqual(classicKey.count, 32 + 2)
    }

    func testLongAnswersTravelAsFrames() throws {
        let short = OpticalResponse(sessionId: 5, status: .ok, result: Data(repeating: 1, count: 64))
        XCTAssertTrue(short.fitsOneCode)
        let key = OpticalResponse(sessionId: 5, status: .ok, result: Data(repeating: 1, count: 1952))
        XCTAssertFalse(key.fitsOneCode)
        let answer = OpticalResponse(sessionId: 0xA5A5_0001, status: .ok, result: Data((0..<3309).map { UInt8($0 % 251) }))
        XCTAssertFalse(answer.fitsOneCode)
        XCTAssertEqual(answer.text.count, 5312)
        XCTAssertEqual(OpticalResponse(text: answer.text), answer, "pasted, any length works")
        XCTAssertEqual(OpticalResponse(bytes: answer.bytes), answer)

        let sender = try answer.frames()
        XCTAssertEqual(sender.prefix, OpticalFrame.answerPrefix)
        XCTAssertEqual(sender.sessionId, 0xA5A5_0001)
        XCTAssertEqual(sender.fragmentCount, 6)
        let frame = sender.frame(0)
        XCTAssertTrue(frame.text.hasPrefix("NSR1:"))
        XCTAssertEqual(OpticalFrame(text: frame.text), frame)
        XCTAssertEqual(OpticalFrame(text: frame.text)?.prefix, OpticalFrame.answerPrefix)
        XCTAssertLessThanOrEqual(frame.text.count, 1000, "one answer code stays readable from a phone screen")

        // The computer collects every other frame; the phone's request receiver ignores them all.
        let computer = OpticalReceiver(prefix: OpticalFrame.answerPrefix)
        let phone = OpticalReceiver()
        var message: Data?
        for sequence in UInt32(0)..<200 where sequence % 2 == 1 {
            let text = sender.frame(sequence).text
            XCTAssertEqual(phone.receive(text), .notAFrame)
            if case let .complete(bytes) = computer.receive(text) {
                message = bytes
                break
            }
        }
        XCTAssertEqual(OpticalResponse(bytes: try XCTUnwrap(message)), answer)
        XCTAssertEqual(computer.sessionId, 0xA5A5_0001)

        // And the other way round: an answer receiver ignores request frames.
        let request = try OpticalSender(message: Data([4]) + BIP32Path.ledgerDefault.serialized, sessionId: 1, fragmentSize: 500)
        XCTAssertEqual(OpticalReceiver(prefix: OpticalFrame.answerPrefix).receive(request.frame(0).text), .notAFrame)
        XCTAssertEqual(OpticalFrame(text: request.frame(0).text)?.prefix, OpticalFrame.prefix)
    }
}
