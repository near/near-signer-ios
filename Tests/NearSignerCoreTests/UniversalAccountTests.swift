import Foundation
import XCTest
@testable import NearSignerCore

/// SHA3-256, ML-DSA-65 key handles and universal accounts (NEP-655). The expected values come
/// from FIPS 202, nearcore's test vectors and Python's `hashlib.sha3_256`.
final class UniversalAccountTests: XCTestCase {
    /// A 1,952-byte key with a fixed pattern (byte i is i mod 251), so its handle and account id
    /// can be checked against other implementations.
    private let patternKey = PublicKey.mlDsa65(Data((0..<1952).map { UInt8($0 % 251) }))
    private let patternHandle = Data(hexString: "a578162387b89691bebd78ddc237074b2ebbd7b3f08467ea7c33ceaad5b7bcde")!
    private let patternAccountId = "0u5ywz5wh3sgdf205z3yw5x7fxb5bqessrs2d1431en7yz9w3r13g0"
    private let ed25519Key = PublicKey.ed25519(Data(repeating: 3, count: 32))

    private func display(signer: String, receiver: String, key: PublicKey, _ actions: [Action]) throws -> RequestDisplay {
        let tx = Transaction(signerId: signer, publicKey: key, nonce: 1, receiverId: receiver,
                             blockHash: Data(repeating: 1, count: 32), actions: actions)
        return try PreparedRequest(kind: .transaction, payload: tx.borsh).display
    }

    // MARK: SHA3-256

    func testSHA3Vectors() {
        func hash(_ data: Data) -> String { SHA3.hash256(data).hexString }
        // FIPS 202 examples.
        XCTAssertEqual(hash(Data()), "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a")
        XCTAssertEqual(hash(Data("abc".utf8)), "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532")
        XCTAssertEqual(hash(Data(repeating: 0xA3, count: 200)), "79f38adec5c20307a98ef76e8324afbfd46cfd81b22e3973c65fa1bd9de31787")
        // Around the 136-byte block boundary (the padding shares a byte with the message at 135),
        // and several blocks long; from Python's hashlib.
        XCTAssertEqual(hash(Data(repeating: UInt8(ascii: "a"), count: 135)), "8094bb53c44cfb1e67b7c30447f9a1c33696d2463ecc1d9c92538913392843c9")
        XCTAssertEqual(hash(Data(repeating: UInt8(ascii: "a"), count: 136)), "3fc5559f14db8e453a0a3091edbd2bc25e11528d81c66fa570a4efdcc2695ee1")
        XCTAssertEqual(hash(Data((0..<1000).map { UInt8($0 % 256) })), "14e5de35911194ddad95ac1572e2b6ce054ed2146cd0562280fcab04ccfecbd8")
        // Any DataProtocol, including a slice that doesn't start at zero.
        let padded = Data([9, 9]) + Data("abc".utf8) + Data([9])
        XCTAssertEqual(SHA3.hash256(padded[2..<5]).hexString, "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532")
    }

    // MARK: Key types

    func testKeyTypesAndRawKeys() throws {
        XCTAssertEqual(KeyType.allCases.map(\.publicKeyLength), [32, 64, 1952])
        XCTAssertEqual(KeyType.allCases.map(\.signatureLength), [64, 65, 3309])
        XCTAssertEqual(KeyType.allCases.map(\.nearName), ["ed25519", "secp256k1", "ml-dsa-65"])
        XCTAssertEqual(KeyType.mlDsa65.rawValue, "mlDsa65")

        XCTAssertEqual(PublicKey(raw: Data(repeating: 1, count: 32)), .ed25519(Data(repeating: 1, count: 32)))
        XCTAssertEqual(PublicKey(raw: patternKey.raw), patternKey)
        XCTAssertNil(PublicKey(raw: Data(repeating: 1, count: 64)), "hosts never answer with a secp256k1 key")
        XCTAssertNil(PublicKey(raw: Data(repeating: 1, count: 31)))
        XCTAssertNil(PublicKey(raw: Data()))
        XCTAssertEqual(patternKey.keyType, .mlDsa65)
        XCTAssertEqual(PublicKey.secp256k1(Data(repeating: 2, count: 64)).keyType, .secp256k1)

        XCTAssertEqual(Signature(raw: Data(repeating: 7, count: 64)), .ed25519(Data(repeating: 7, count: 64)))
        XCTAssertEqual(Signature(raw: Data(repeating: 7, count: 3309)), .mlDsa65(Data(repeating: 7, count: 3309)))
        XCTAssertNil(Signature(raw: Data(repeating: 7, count: 65)))
        XCTAssertNil(Signature(raw: Data(repeating: 7, count: 3308)))
        XCTAssertEqual(Signature(raw: Data(repeating: 7, count: 3309))?.raw.count, 3309)
        XCTAssertEqual(Signature(raw: Data(repeating: 7, count: 3309))?.keyType, .mlDsa65)
    }

    func testPublicKeyStringForms() throws {
        // The three prefixes round-trip, with surrounding whitespace forgiven.
        for key in [ed25519Key, PublicKey.secp256k1(Data(repeating: 5, count: 64)), patternKey] {
            XCTAssertEqual(PublicKey(string: key.description), key)
            XCTAssertEqual(PublicKey(string: " \(key.description) "), key)
            XCTAssertTrue(key.description.hasPrefix(key.keyType.nearName + ":"))
        }
        XCTAssertEqual(patternKey.description.count, "ml-dsa-65:".count + 2665)
        // The largest 1,952-byte value is the longest possible key text, and still parses.
        let largest = PublicKey.mlDsa65(Data(repeating: 0xFF, count: 1952))
        XCTAssertEqual(largest.description.count, "ml-dsa-65:".count + 2666)
        XCTAssertEqual(PublicKey(string: largest.description), largest)
        XCTAssertEqual(PublicKey(string: "ed25519:" + Base58.encode(Data(repeating: 1, count: 32))),
                       .ed25519(Data(repeating: 1, count: 32)))
        // Wrong length for the type, unknown or missing type, and text too long to be a key.
        XCTAssertNil(PublicKey(string: "ed25519:" + Base58.encode(Data(repeating: 1, count: 31))))
        XCTAssertNil(PublicKey(string: "ml-dsa-65:" + Base58.encode(Data(repeating: 1, count: 32))))
        XCTAssertNil(PublicKey(string: "secp256k1:" + Base58.encode(Data(repeating: 1, count: 32))))
        XCTAssertNil(PublicKey(string: "ml-dsa-65-hash:" + Base58.encode(patternHandle)), "a handle is not a key")
        XCTAssertNil(PublicKey(string: "rsa:" + Base58.encode(Data(repeating: 1, count: 32))))
        XCTAssertNil(PublicKey(string: Base58.encode(Data(repeating: 1, count: 32))))
        XCTAssertNil(PublicKey(string: "ed25519:" + String(repeating: "1", count: 45)))
        XCTAssertNil(PublicKey(string: "ml-dsa-65:" + String(repeating: "1", count: 2667)))
    }

    // MARK: Handles

    func testMlDsaHandleMatchesSHA3OfDomainAndKey() {
        XCTAssertEqual(patternKey.handle, .mlDsa65Hash(patternHandle))
        XCTAssertEqual(patternKey.handle.description, "ml-dsa-65-hash:" + Base58.encode(patternHandle))
        XCTAssertEqual(patternKey.handle.keyType, .mlDsa65)
        // The other types are their own handle.
        XCTAssertEqual(ed25519Key.handle, .ed25519(Data(repeating: 3, count: 32)))
        XCTAssertEqual(ed25519Key.handle.description, ed25519Key.description)
        let secp = PublicKey.secp256k1(Data(repeating: 5, count: 64))
        XCTAssertEqual(secp.handle, .secp256k1(Data(repeating: 5, count: 64)))
        XCTAssertEqual(secp.handle.description, secp.description)
    }

    func testPublicKeyHandleOrderAndBorsh() throws {
        let low = PublicKeyHandle.ed25519(Data(repeating: 0xFF, count: 32))
        let secp = PublicKeyHandle.secp256k1(Data(repeating: 0, count: 64))
        let hashA = PublicKeyHandle.mlDsa65Hash(Data([1] + [UInt8](repeating: 0xFF, count: 31)))
        let hashB = PublicKeyHandle.mlDsa65Hash(Data([2] + [UInt8](repeating: 0, count: 31)))
        // The tag decides first (ed25519 < secp256k1 < ML-DSA-65 hash), then the bytes.
        XCTAssertEqual([hashB, secp, hashA, low].sorted(), [low, secp, hashA, hashB])
        XCTAssertTrue(hashA < hashB)
        XCTAssertFalse(hashA < hashA)

        for (handle, tag) in [(low, UInt8(0)), (secp, 1), (hashA, 3)] {
            var writer = BorshWriter()
            handle.encode(&writer)
            XCTAssertEqual(writer.data.first, tag)
            XCTAssertEqual(writer.data.count, 1 + handle.bytes.count)
            var reader = BorshReader(writer.data)
            XCTAssertEqual(try PublicKeyHandle.decode(&reader), handle)
            XCTAssertTrue(reader.isAtEnd)
        }
        // Tag 2 is the full ML-DSA-65 key, which a handle never carries.
        var reader = BorshReader(Data([2]) + patternKey.raw)
        XCTAssertThrowsError(try PublicKeyHandle.decode(&reader)) {
            XCTAssertEqual($0 as? BorshError, .invalidEnumTag(type: "PublicKeyHandle", tag: 2))
        }
    }

    // MARK: State init and account ids

    func testKeyOnlyStateInitMatchesNearcore() throws {
        let handle = PublicKeyHandle.mlDsa65Hash(Data(repeating: 0x11, count: 32))
        let stateInit = UniversalStateInit(keyOnly: handle)
        let expected = Data([0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 3]) + Data(repeating: 0x11, count: 32)
        XCTAssertEqual(stateInit.borsh, expected)
        XCTAssertEqual(stateInit.borsh.count, 43)
        XCTAssertEqual(try UniversalStateInit.decode(expected), stateInit)
        XCTAssertEqual(UniversalAccount.id(stateInit: expected), "0ux8te7g99f9kqzdtp9h4qnwt9aczpgayymmtbdc50w199rcw3at1g")
        XCTAssertTrue(UniversalAccount.isUniversalId(UniversalAccount.id(stateInit: expected)))
    }

    func testStateInitWithCodeAndDataMatchesNearcore() throws {
        let stateInit = UniversalStateInit(
            code: .codeHash(Data(repeating: 0x22, count: 32)),
            data: [.init(key: Data("key".utf8), value: Data("value".utf8))],
            accessKeys: [])
        let expected = try XCTUnwrap(Data(hexString:
            "000100" + String(repeating: "22", count: 32) + "01000000" + "030000006b6579" + "0500000076616c7565" + "00000000"))
        XCTAssertEqual(stateInit.borsh, expected)
        XCTAssertEqual(try UniversalStateInit.decode(expected), stateInit)
        XCTAssertEqual(UniversalAccount.id(stateInit: expected), "0uzvdgbyea2rd8ywx0kw3cg4vc0ez1x5fc2gyks4fdz9ae0xxvzan0")
    }

    func testAccountIdOfAnMlDsaKey() {
        XCTAssertEqual(UniversalAccount.id(forKey: patternKey), patternAccountId)
        XCTAssertEqual(UniversalAccount.id(stateInit: UniversalStateInit(keyOnly: .mlDsa65Hash(patternHandle)).borsh), patternAccountId)
        // An ed25519 key has a universal id too (a key-only state init with the key itself).
        let edId = UniversalAccount.id(forKey: ed25519Key)
        XCTAssertTrue(UniversalAccount.isUniversalId(edId))
        XCTAssertNotEqual(edId, patternAccountId)
    }

    func testUniversalIdShape() {
        // The NEP-655 appendix example: only its shape is known.
        let appendix = "0u4bfkw2qvgfzbf7zzkxykcppqymn0p2hbayjee3ygzrbhmmtyejx0"
        XCTAssertEqual(appendix.count, 54)
        XCTAssertTrue(UniversalAccount.isUniversalId(appendix))
        XCTAssertTrue(UniversalAccount.isUniversalId(patternAccountId))
        let body = String(appendix.dropFirst(2).dropLast(2))
        let bad: [String] = [
            String(appendix.dropLast()),           // 53 characters
            appendix + "0",                        // 55 characters
            "0s" + body + "x0",                    // deterministic prefix
            "0U" + body + "x0",                    // uppercase
            "0u" + body + "x1",                    // padding bits set
            "0u" + body + "xz",
            "0u" + body + "i0",                    // not in the alphabet
            "0u" + body + "l0",
            "0u" + body + "o0",
            "0u" + body + "u0",
            "0u" + body + "é0",
            String(repeating: "0", count: 54),     // no "u"
        ]
        for id in bad {
            XCTAssertFalse(UniversalAccount.isUniversalId(id), id)
        }
        // The account-id rules accept them, and the display knows the kind.
        XCTAssertTrue(NearFormat.isValidAccountId(appendix))
        XCTAssertEqual(NearFormat.accountKind(appendix), "universal account")
        XCTAssertFalse(NearFormat.isNamedAccount(appendix))
        XCTAssertEqual(NearFormat.shortAccountId(appendix), "0u4bfk…tyejx0")
        XCTAssertNil(NearFormat.accountKind(String(appendix.dropLast())))
    }

    func testStateInitBorshIsCanonical() throws {
        let a = PublicKeyHandle.ed25519(Data(repeating: 1, count: 32))
        let b = PublicKeyHandle.mlDsa65Hash(Data(repeating: 2, count: 32))
        let unordered = UniversalStateInit(
            code: .accountId("global.near"),
            data: [.init(key: Data([2]), value: Data([20])), .init(key: Data([1]), value: Data([10])),
                   .init(key: Data([2]), value: Data([21]))],
            accessKeys: [b, a, b])
        let decoded = try UniversalStateInit.decode(unordered.borsh)
        XCTAssertEqual(decoded.data, [.init(key: Data([1]), value: Data([10])), .init(key: Data([2]), value: Data([21]))])
        XCTAssertEqual(decoded.accessKeys, [a, b])
        XCTAssertEqual(decoded.code, .accountId("global.near"))
        XCTAssertEqual(decoded.borsh, unordered.borsh)
        // Keys compare byte by byte, a shorter prefix first.
        let prefixes = UniversalStateInit(code: nil, data: [.init(key: Data([1, 0]), value: Data()), .init(key: Data([1]), value: Data())],
                                          accessKeys: [])
        XCTAssertEqual(try UniversalStateInit.decode(prefixes.borsh).data.map(\.key), [Data([1]), Data([1, 0])])
    }

    func testStateInitDecodingIsStrict() throws {
        func bytes(_ build: (inout BorshWriter) -> Void) -> Data {
            var writer = BorshWriter()
            build(&writer)
            return writer.data
        }
        func entry(_ writer: inout BorshWriter, _ key: [UInt8], _ value: [UInt8]) {
            writer.writeByteVector(Data(key))
            writer.writeByteVector(Data(value))
        }
        let keyOnly = UniversalStateInit(keyOnly: .mlDsa65Hash(Data(repeating: 0x11, count: 32))).borsh

        // Entries out of order, or repeated: nearcore's map would hold something else.
        let unsorted = bytes { w in
            w.writeU8(0); w.writeU8(0); w.writeU32(2); entry(&w, [2], [0]); entry(&w, [1], [0]); w.writeU32(0)
        }
        XCTAssertThrowsError(try UniversalStateInit.decode(unsorted)) { XCTAssertEqual($0 as? BorshError, .nonCanonical) }
        let duplicate = bytes { w in
            w.writeU8(0); w.writeU8(0); w.writeU32(2); entry(&w, [1], [0]); entry(&w, [1], [1]); w.writeU32(0)
        }
        XCTAssertThrowsError(try UniversalStateInit.decode(duplicate)) { XCTAssertEqual($0 as? BorshError, .nonCanonical) }
        // Keys out of order (an ML-DSA-65 hash sorts after an ed25519 key), or repeated.
        let unsortedKeys = bytes { w in
            w.writeU8(0); w.writeU8(0); w.writeU32(0); w.writeU32(2)
            w.writeU8(3); w.writeFixed(Data(repeating: 0, count: 32))
            w.writeU8(0); w.writeFixed(Data(repeating: 0xFF, count: 32))
        }
        XCTAssertThrowsError(try UniversalStateInit.decode(unsortedKeys)) { XCTAssertEqual($0 as? BorshError, .nonCanonical) }
        let duplicateKeys = bytes { w in
            w.writeU8(0); w.writeU8(0); w.writeU32(0); w.writeU32(2)
            w.writeU8(3); w.writeFixed(Data(repeating: 0, count: 32))
            w.writeU8(3); w.writeFixed(Data(repeating: 0, count: 32))
        }
        XCTAssertThrowsError(try UniversalStateInit.decode(duplicateKeys)) { XCTAssertEqual($0 as? BorshError, .nonCanonical) }
        // Trailing bytes, a version this signer doesn't know, truncation, a full key as a handle.
        XCTAssertThrowsError(try UniversalStateInit.decode(keyOnly + Data([0]))) { XCTAssertEqual($0 as? BorshError, .trailingBytes(1)) }
        XCTAssertThrowsError(try UniversalStateInit.decode(Data([1]) + keyOnly.dropFirst())) {
            XCTAssertEqual($0 as? BorshError, .invalidEnumTag(type: "UniversalStateInit", tag: 1))
        }
        XCTAssertThrowsError(try UniversalStateInit.decode(keyOnly.dropLast()))
        XCTAssertThrowsError(try UniversalStateInit.decode(Data()))
        var fullKey = keyOnly
        fullKey[10] = 2
        XCTAssertThrowsError(try UniversalStateInit.decode(fullKey)) {
            XCTAssertEqual($0 as? BorshError, .invalidEnumTag(type: "PublicKeyHandle", tag: 2))
        }
        // Hostile counts are bounded before anything is allocated.
        let huge = bytes { w in w.writeU8(0); w.writeU8(0); w.writeU32(0xFFFF_FFFF) }
        XCTAssertThrowsError(try UniversalStateInit.decode(huge))
    }

    // MARK: Display

    func testActivationOfAUniversalAccount() throws {
        let stateInit = UniversalStateInit(keyOnly: patternKey.handle).borsh
        let activate = Action.universalStateInit(rawStateInit: stateInit, deposit: .zero)
        let display = try self.display(signer: patternAccountId, receiver: patternAccountId, key: patternKey, [activate])
        XCTAssertEqual(display.title, "Activate account 0u5ywz…3r13g0")
        XCTAssertEqual(display.symbol, .createAccount)
        XCTAssertTrue(display.warnings.isEmpty, display.warnings.joined(separator: "\n"))
        XCTAssertEqual(display.primarySections.map(\.title), ["Activate account"])
        let card = display.primarySections[0].fields
        XCTAssertTrue(card.contains(DisplayField("Account", patternAccountId, style: .monospace)))
        XCTAssertTrue(card.contains(DisplayField("Account type", "universal account")))
        XCTAssertTrue(card.contains(DisplayField("Key", patternKey.handle.description, style: .monospace)))
        XCTAssertTrue(card.contains(DisplayField("Key type", "ML-DSA-65 (post-quantum)")))
        XCTAssertTrue(card.contains { $0.label == "What it does" && $0.value.contains("controlled by the key that signs this request") })
        XCTAssertFalse(card.contains { $0.label == "Deposit" }, "nothing attached, nothing to show")
        // The raw action and the signing key stay in the technical details.
        XCTAssertTrue(display.technicalSections.contains { $0.title == "Universal state init" })
        XCTAssertTrue(display.text.contains("Signer public key: " + patternKey.description))

        // Actions after the state init stay in plain sight, next to the card.
        let withTransfer = try self.display(signer: patternAccountId, receiver: patternAccountId, key: patternKey,
                                            [activate, .transfer(deposit: U128(decimal: "2000000000000000000000000")!)])
        XCTAssertEqual(withTransfer.title, "Activate account 0u5ywz…3r13g0")
        XCTAssertEqual(withTransfer.primarySections.map(\.title), ["Activate account", "Also, action 2 of 2: Transfer"])
        XCTAssertTrue(withTransfer.primarySections[0].fields.contains(DisplayField("Total attached NEAR", "2 NEAR", style: .amount)))
        XCTAssertTrue(withTransfer.primarySections[1].fields.contains(DisplayField("Amount", "2 NEAR", style: .amount)))

        // A deposit on the state init itself (storage) is on the card.
        let funded = try self.display(signer: patternAccountId, receiver: patternAccountId, key: patternKey,
                                      [.universalStateInit(rawStateInit: stateInit, deposit: U128(decimal: "100000000000000000000000")!)])
        XCTAssertTrue(funded.primarySections[0].fields.contains(DisplayField("Deposit", "0.1 NEAR", style: .amount)))

        // Signed with a key the state init doesn't commit: no quiet summary.
        let otherKey = try self.display(signer: patternAccountId, receiver: patternAccountId, key: ed25519Key, [activate])
        XCTAssertEqual(otherKey.title, "Activate account 0u5ywz…3r13g0")
        XCTAssertTrue(otherKey.primarySections[0].fields.contains(DisplayField("Signed with this key", "NO", style: .warning)))
        XCTAssertTrue(otherKey.warnings.contains { $0.contains("not the key the account is created with") })
    }

    func testUniversalStateInitRenderedActionByAction() throws {
        let stateInit = UniversalStateInit(keyOnly: patternKey.handle).borsh
        // Someone else funds and initializes the account (a relayer): the plain action view.
        let relayed = try display(signer: "relayer.near", receiver: patternAccountId, key: ed25519Key, [
            .transfer(deposit: U128(decimal: "1000000000000000000000000")!),
            .universalStateInit(rawStateInit: stateInit, deposit: .zero),
        ])
        XCTAssertEqual(relayed.title, "2 actions on \(patternAccountId)")
        XCTAssertTrue(relayed.warnings.isEmpty, relayed.warnings.joined(separator: "\n"))
        XCTAssertTrue(relayed.text.contains("Receiver type: universal account"))
        let section = try XCTUnwrap(relayed.primarySections.first { $0.title == "Action 2 of 2: Universal state init" })
        XCTAssertTrue(section.fields.contains(DisplayField("Derived from the state init", "yes, the id matches")))
        XCTAssertTrue(section.fields.contains(DisplayField("Contract", "none")))
        XCTAssertTrue(section.fields.contains(DisplayField("Key", patternKey.handle.description, style: .monospace)))
        XCTAssertTrue(section.fields.contains(DisplayField("Initial storage entries", "0")))
        XCTAssertFalse(section.fields.contains { $0.label == "Signed with a committed key" }, "another account may initialize it")

        // Alone, from the account itself but with a contract: the single-action title.
        let full = UniversalStateInit(
            code: .codeHash(Data(repeating: 0x22, count: 32)),
            data: [.init(key: Data("key".utf8), value: Data("value".utf8))],
            accessKeys: [ed25519Key.handle, patternKey.handle]).borsh
        let fullId = UniversalAccount.id(stateInit: full)
        let contract = try display(signer: fullId, receiver: fullId, key: patternKey,
                                   [.universalStateInit(rawStateInit: full, deposit: .zero)])
        XCTAssertEqual(contract.title, "Initialize \(NearFormat.shortAccountId(fullId))")
        XCTAssertEqual(contract.symbol, .initialize)
        XCTAssertTrue(contract.warnings.isEmpty, contract.warnings.joined(separator: "\n"))
        let fields = contract.primarySections[1].fields
        XCTAssertTrue(fields.contains(DisplayField("Contract", "code hash " + Base58.encode(Data(repeating: 0x22, count: 32)), style: .monospace)))
        XCTAssertTrue(fields.contains(DisplayField("Key 1 of 2", ed25519Key.description, style: .monospace)))
        XCTAssertTrue(fields.contains(DisplayField("Key 2 of 2", patternKey.handle.description, style: .monospace)))
        XCTAssertTrue(fields.contains(DisplayField("Initial storage entries", "1")))

        // Self-initialized with a key the state init doesn't commit: the network rejects it.
        let wrongKey = try display(signer: fullId, receiver: fullId, key: .ed25519(Data(repeating: 8, count: 32)),
                                   [.universalStateInit(rawStateInit: full, deposit: .zero)])
        XCTAssertTrue(wrongKey.primarySections[1].fields.contains(DisplayField("Signed with a committed key", "NO", style: .warning)))
        XCTAssertTrue(wrongKey.warnings.contains { $0.contains("not one of the keys the state init commits") })
    }

    func testUniversalStateInitMismatchAndUnreadableBytes() throws {
        let stateInit = UniversalStateInit(keyOnly: patternKey.handle).borsh
        let other = UniversalAccount.id(forKey: ed25519Key)
        // The receiver is another universal id: never shown as its activation.
        let mismatch = try display(signer: other, receiver: other, key: patternKey,
                                   [.universalStateInit(rawStateInit: stateInit, deposit: .zero)])
        XCTAssertEqual(mismatch.title, "State init doesn't match \(NearFormat.shortAccountId(other))")
        XCTAssertFalse(mismatch.text.contains("Activate"))
        XCTAssertTrue(mismatch.warnings.contains("The state init describes account \(patternAccountId), not \(other). The network rejects this transaction; it does not activate \(other)."))
        let fields = mismatch.primarySections[1].fields
        XCTAssertTrue(fields.contains(DisplayField("Account the state init describes", patternAccountId, style: .monospace)))
        XCTAssertTrue(fields.contains(DisplayField("Matches the receiver", "NO", style: .warning)))
        XCTAssertTrue(fields.contains(DisplayField("Key", patternKey.handle.description, style: .monospace)))

        // A named receiver can't be created this way either.
        let named = try display(signer: "alice.near", receiver: "alice.near", key: ed25519Key,
                                [.universalStateInit(rawStateInit: stateInit, deposit: .zero)])
        XCTAssertEqual(named.title, "State init doesn't match alice.near")
        XCTAssertTrue(named.warnings.contains { $0.hasSuffix("it does not activate alice.near.") })

        // Bytes that don't decode: said so, with their size; the id they hash to is still shown.
        let raw = Data([0, 1, 2])
        let rawId = UniversalAccount.id(stateInit: raw)
        let unreadable = try display(signer: rawId, receiver: rawId, key: patternKey,
                                     [.universalStateInit(rawStateInit: raw, deposit: U128(13))])
        XCTAssertEqual(unreadable.title, "Initialize \(NearFormat.shortAccountId(rawId))")
        XCTAssertTrue(unreadable.primarySections[1].fields.contains(
            DisplayField("State init", "3 bytes, not in a format NEAR Signer can read", style: .warning)))
        XCTAssertTrue(unreadable.primarySections[1].fields.contains(DisplayField("Deposit", "0.000000000000000000000013 NEAR", style: .amount)))
        XCTAssertTrue(unreadable.warnings.contains { $0.hasPrefix("The state init can't be decoded") })
        // Non-canonical bytes count as unreadable too: nearcore's map would hold something else.
        var duplicate = BorshWriter()
        duplicate.writeU8(0); duplicate.writeU8(0); duplicate.writeU32(2)
        for value: UInt8 in [0, 1] {
            duplicate.writeByteVector(Data([1])); duplicate.writeByteVector(Data([value]))
        }
        duplicate.writeU32(0)
        let dupId = UniversalAccount.id(stateInit: duplicate.data)
        let nonCanonical = try display(signer: dupId, receiver: dupId, key: patternKey,
                                       [.universalStateInit(rawStateInit: duplicate.data, deposit: .zero)])
        XCTAssertTrue(nonCanonical.warnings.contains { $0.hasPrefix("The state init can't be decoded") })
        XCTAssertFalse(nonCanonical.text.contains("Activate"))
    }
}
