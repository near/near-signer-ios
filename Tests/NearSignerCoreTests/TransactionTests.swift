import Foundation
import XCTest
@testable import NearSignerCore

final class TransactionTests: XCTestCase {
    private func ledgerKey() throws -> Curve25519.Signing.PrivateKey {
        try KeyMaterial.fromMnemonic(Fixtures.phrase).privateKey(for: .ledgerDefault)
    }

    func testDecodesEveryNearApiJsFixture() throws {
        let key = try ledgerKey()
        for fixture in Fixtures.transactions {
            let bytes = try XCTUnwrap(Data(base64Encoded: fixture.borsh), fixture.name)
            let tx = try Transaction.decode(bytes)
            XCTAssertEqual(tx.borsh, bytes, "re-encoding \(fixture.name)")
            XCTAssertEqual(tx.signerId, "alice.testnet")
            XCTAssertEqual(tx.publicKey.description, Fixtures.ledgerPublicKey)
            XCTAssertEqual(tx.nonce, .nonce(7))

            let hash = SigningDigest.transaction(bytes)
            XCTAssertEqual(Base58.encode(hash), fixture.hash, fixture.name)

            let signature = try key.signature(for: hash)
            XCTAssertTrue(key.publicKey.isValidSignature(signature, for: hash))
            let expected = try XCTUnwrap(Data(base64Encoded: fixture.signature))
            XCTAssertTrue(key.publicKey.isValidSignature(expected, for: hash))
            #if !canImport(CryptoKit)
            // BoringSSL signs deterministically (RFC 8032), like tweetnacl. CryptoKit randomizes.
            XCTAssertEqual(signature, expected, fixture.name)
            #endif
            XCTAssertEqual(Transaction.signedTransaction(unsignedBorsh: bytes, ed25519Signature: expected).base64EncodedString(),
                           fixture.signed, fixture.name)

            let display = RequestRenderer.render(transaction: tx, hash: hash)
            XCTAssertFalse(display.title.isEmpty)
            XCTAssertTrue(display.text.contains(fixture.hash))
        }
    }

    func testDecodedFieldsAndDisplay() throws {
        func load(_ name: String) throws -> (Transaction, RequestDisplay) {
            let fixture = try XCTUnwrap(Fixtures.transactions.first { $0.name == name })
            let bytes = Data(base64Encoded: fixture.borsh)!
            let tx = try Transaction.decode(bytes)
            return (tx, RequestRenderer.render(transaction: tx, hash: SigningDigest.transaction(bytes)))
        }

        let (transfer, transferDisplay) = try load("transfer")
        XCTAssertEqual(transfer.actions, [.transfer(deposit: U128(decimal: "1500000000000000000000000")!)])
        XCTAssertEqual(transferDisplay.title, "Send 1.5 NEAR to bob.testnet")
        XCTAssertTrue(transferDisplay.text.contains("Network (from account names): testnet"))

        let (call, callDisplay) = try load("functionCall")
        guard case let .functionCall(action) = call.actions[0] else { return XCTFail("expected function call") }
        XCTAssertEqual(action.methodName, "ft_transfer")
        XCTAssertEqual(action.gas, 30_000_000_000_000)
        XCTAssertEqual(action.deposit, U128(1))
        XCTAssertEqual(callDisplay.title, "Send usdc.testnet tokens to bob.testnet")
        XCTAssertTrue(callDisplay.text.contains("1000000 raw token units → bob.testnet"))
        XCTAssertTrue(callDisplay.text.contains("\"receiver_id\": \"bob.testnet\""))

        let (_, binaryDisplay) = try load("functionCallBinary")
        XCTAssertTrue(binaryDisplay.text.contains("base64: AQID/w=="))

        let (create, createDisplay) = try load("createAccount")
        XCTAssertEqual(create.actions.count, 3)
        XCTAssertEqual(createDisplay.title, "3 actions on sub.alice.testnet")
        XCTAssertTrue(createDisplay.warnings.contains { $0.contains("FULL ACCESS") })

        let (_, deleteDisplay) = try load("deleteAccount")
        XCTAssertTrue(deleteDisplay.warnings.contains { $0.contains("remaining balance goes to bob.testnet") })

        let (_, deleteKeyDisplay) = try load("deleteKey")
        XCTAssertTrue(deleteKeyDisplay.warnings.contains("Deletes the key that signs this transaction."))

        let (limited, limitedDisplay) = try load("addFunctionCallKey")
        guard case let .addKey(_, accessKey) = limited.actions[0],
              case let .functionCall(permission) = accessKey.permission else { return XCTFail("expected limited key") }
        XCTAssertEqual(permission.methodNames, ["a", "b"])
        XCTAssertEqual(permission.allowance, U128(decimal: "250000000000000000000000"))
        XCTAssertEqual(limitedDisplay.title, "Add limited key to alice.testnet")
        XCTAssertTrue(limitedDisplay.warnings.isEmpty)

        let (global, _) = try load("deployGlobalByAccount")
        guard case let .deployGlobalContract(_, mode) = global.actions[0] else { return XCTFail("expected global deploy") }
        XCTAssertEqual(mode, .accountId)

        let (use, _) = try load("useGlobalByHash")
        XCTAssertEqual(use.actions, [.useGlobalContract(.codeHash(Data(repeating: 7, count: 32)))])
    }

    func testDelegateActionMatchesNearApiJs() throws {
        let prefixed = try XCTUnwrap(Data(base64Encoded: Fixtures.delegatePrefixedBorsh))
        XCTAssertEqual(prefixed.prefix(4).hexString, "6e010040")
        let borsh = Data(prefixed.dropFirst(4))
        let action = try DelegateAction.decode(borsh)
        XCTAssertEqual(action.senderId, "alice.testnet")
        XCTAssertEqual(action.receiverId, "app.testnet")
        XCTAssertEqual(action.maxBlockHeight, 1000)
        XCTAssertEqual(action.nonce, 9)
        XCTAssertEqual(action.actions.count, 2)
        XCTAssertEqual(action.borsh, borsh)
        let digest = SigningDigest.delegateAction(borsh)
        XCTAssertEqual(Base58.encode(digest), Fixtures.delegateHash)
        let key = try ledgerKey()
        XCTAssertTrue(key.publicKey.isValidSignature(Data(base64Encoded: Fixtures.delegateSignature)!, for: digest))
        let display = RequestRenderer.render(delegateAction: action, digest: digest)
        XCTAssertTrue(display.title.hasPrefix("Meta-tx: 2 actions on app.testnet"))
    }

    func testRelayTransactionWithSignedDelegate() throws {
        let bytes = try XCTUnwrap(Data(base64Encoded: Fixtures.relayTransactionBorsh))
        let tx = try Transaction.decode(bytes)
        XCTAssertEqual(tx.borsh, bytes)
        guard case let .delegate(signed) = tx.actions.first else { return XCTFail("expected delegate") }
        XCTAssertEqual(signed.delegateAction.senderId, "alice.testnet")
        let display = RequestRenderer.render(transaction: tx, hash: SigningDigest.transaction(bytes))
        XCTAssertEqual(display.title, "Relay meta-tx from alice.testnet")
        XCTAssertTrue(display.text.contains("Inner action 2: Function call"))
    }

    func testNEP413MatchesReference() throws {
        let payloadBytes = try XCTUnwrap(Data(base64Encoded: Fixtures.nep413Payload))
        let payload = try NEP413Payload.decode(payloadBytes)
        XCTAssertEqual(payload.message, "Login to app")
        XCTAssertEqual(payload.recipient, "app.near")
        XCTAssertEqual(payload.nonce, Data(repeating: 1, count: 32))
        XCTAssertEqual(payload.callbackUrl, "https://app.near/cb")
        XCTAssertEqual(payload.borsh, payloadBytes)
        let digest = SigningDigest.nep413(payloadBytes)
        XCTAssertEqual(Base58.encode(digest), Fixtures.nep413Hash)
        XCTAssertTrue(try ledgerKey().publicKey.isValidSignature(Data(base64Encoded: Fixtures.nep413Signature)!, for: digest))
    }

    /// Actions that near-api-js cannot build yet, plus TransactionV1, built by hand from nearcore's layout.
    func testNewerActionsAndTransactionV1RoundTrip() throws {
        let key = PublicKey.ed25519(Data(repeating: 3, count: 32))
        let delegateV2 = SignedDelegateActionV2(
            delegateAction: DelegateActionV2(senderId: "a.near", receiverId: "b.near",
                                             actions: [.transfer(deposit: U128(9))],
                                             nonce: .gasKeyNonce(nonce: 5, index: 2), maxBlockHeight: 77,
                                             publicKey: key),
            signature: .ed25519(Data(repeating: 4, count: 64)))
        let actions: [Action] = [
            .deterministicStateInit(DeterministicStateInit(code: .accountId("global.near"),
                                                           data: [(key: Data([1]), value: Data([2, 3]))]),
                                    deposit: U128(10)),
            .transferToGasKey(publicKey: key, deposit: U128(11)),
            .withdrawFromGasKey(publicKey: key, amount: U128(12)),
            .delegateV2(delegateV2),
            .universalStateInit(rawStateInit: Data([0, 1, 2]), deposit: U128(13)),
            .addKey(publicKey: key, accessKey: AccessKey(nonce: 0, permission: .gasKeyFullAccess(GasKeyInfo(balance: U128(1), numNonces: 16)))),
            .addKey(publicKey: .secp256k1(Data(repeating: 5, count: 64)),
                    accessKey: AccessKey(nonce: 1, permission: .gasKeyFunctionCall(
                        GasKeyInfo(balance: U128(2), numNonces: 1024),
                        FunctionCallPermission(allowance: nil, receiverId: "c.near", methodNames: ["m"])))),
        ]
        let tx = Transaction(version: .v1(nonceMode: .strict), signerId: "alice.near", publicKey: key,
                             nonce: .gasKeyNonce(nonce: 100, index: 3), receiverId: "alice.near",
                             blockHash: Data(repeating: 9, count: 32), actions: actions)
        let bytes = tx.borsh
        XCTAssertEqual(bytes.first, 1)
        // Tag, then u32 length of "alice.near".
        XCTAssertEqual(Array(bytes.prefix(5)), [1, 10, 0, 0, 0])
        let decoded = try Transaction.decode(bytes)
        XCTAssertEqual(decoded, tx)
        XCTAssertEqual(decoded.borsh, bytes)
        let display = RequestRenderer.render(transaction: decoded, hash: SigningDigest.transaction(bytes))
        XCTAssertTrue(display.text.contains("TransactionV1, nonce mode strict"))
        XCTAssertTrue(display.warnings.contains { $0.contains("FULL ACCESS gas key") })
        XCTAssertTrue(display.text.contains("100 (gas key nonce index 3)"))
    }

    func testRejectsMalformedPayloads() throws {
        let fixture = Fixtures.transactions[0]
        let bytes = Data(base64Encoded: fixture.borsh)!
        XCTAssertThrowsError(try Transaction.decode(bytes + Data([0]))) {
            XCTAssertEqual($0 as? BorshError, .trailingBytes(1))
        }
        XCTAssertThrowsError(try Transaction.decode(bytes.dropLast()))
        var unknownAction = bytes
        // The single action's tag sits right after the u32 action count, 17 bytes before the end.
        unknownAction[unknownAction.count - 17] = 99
        XCTAssertThrowsError(try Transaction.decode(unknownAction)) {
            XCTAssertEqual($0 as? BorshError, .invalidEnumTag(type: "Action", tag: 99))
        }
        // A delegate action may not contain another delegate action.
        var nested = BorshWriter()
        nested.writeString("a"); nested.writeString("b"); nested.writeU32(1); nested.writeU8(8)
        XCTAssertThrowsError(try DelegateAction.decode(nested.data)) {
            XCTAssertEqual($0 as? BorshError, .invalidEnumTag(type: "NonDelegateAction", tag: 8))
        }
        // Hostile length prefix.
        var huge = BorshWriter()
        huge.writeU32(0xFFFF_FFFF)
        XCTAssertThrowsError(try Transaction.decode(huge.data))
    }
}
