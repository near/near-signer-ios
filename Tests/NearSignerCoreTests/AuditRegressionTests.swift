import Foundation
import XCTest
@testable import NearSignerCore

/// Each test replays an attack found in the security audit.
final class AuditRegressionTests: XCTestCase {
    private let usdc = "17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1"
    private let material = try! KeyMaterial.fromMnemonic(Fixtures.phrase)
    private var key: Data { try! material.privateKey(for: .ledgerDefault).publicKey.rawRepresentation }

    private func call(_ method: String, _ args: String, deposit: U128 = U128(1)) -> Action {
        .functionCall(FunctionCallAction(methodName: method, args: Data(args.utf8), gas: 30_000_000_000_000, deposit: deposit))
    }

    private func display(receiver: String, _ actions: [Action], signer: String = "alice.near") throws -> RequestDisplay {
        let tx = Transaction(signerId: signer, publicKey: .ed25519(key), nonce: 1, receiverId: receiver,
                             blockHash: Data(repeating: 1, count: 32), actions: actions)
        return try PreparedRequest(kind: .transaction, payload: tx.borsh).display
    }

    private func intents(_ message: String) throws -> RequestDisplay {
        let payload = NEP413Payload(message: message, nonce: Data(repeating: 2, count: 32), recipient: "intents.near", callbackUrl: nil)
        return try PreparedRequest(kind: .nep413, payload: payload.borsh).display
    }

    // MARK: Amounts (critical)

    /// "+1000000000" is a valid u128 for the contract (Rust's parser accepts "+"): it must show.
    func testPlusPrefixedIntentsAmountsAreShown() throws {
        let display = try intents("""
            {"signer_id":"alice.near","deadline":"2026-10-12T15:00:00Z","intents":[{"intent":"transfer","receiver_id":"attacker.near",
             "tokens":{"nep141:wrap.near":"1","nep141:usdt.tether-token.near":"+1000000000"}}]}
            """)
        XCTAssertEqual(display.title, "Send 2 tokens to attacker.near")
        XCTAssertTrue(display.primarySections.flatMap(\.fields).contains { $0.value == "1\u{202F}000 USDt" })
    }

    /// Anything else that doesn't parse (here "1e9") shows the raw message, never a partial summary.
    func testUnparsableIntentsAmountsFallBackToRaw() throws {
        let display = try intents("""
            {"signer_id":"alice.near","deadline":"2026-10-12T15:00:00Z","intents":[{"intent":"transfer","receiver_id":"attacker.near",
             "tokens":{"nep141:wrap.near":"1","nep141:usdt.tether-token.near":"1e9"}}]}
            """)
        XCTAssertNil(display.highlight)
        XCTAssertEqual(display.title, "Sign message for intents.near")
        XCTAssertTrue(display.text.contains("1e9"), "the raw message is shown in full")

        let withdraw = try intents("""
            {"signer_id":"alice.near","deadline":"x","intents":[{"intent":"ft_withdraw","token":"\(usdc)","receiver_id":"bob.near","amount":"lots"}]}
            """)
        XCTAssertNil(withdraw.highlight)
    }

    func testDAOAmountsFailClosed() throws {
        let args = Data(#"{"receiver_id":"x.near","amount":"1"}"#.utf8).base64EncodedString()
        let plus = try display(receiver: "dao.sputnik-dao.near", [call("act_proposal", """
            {"id":1,"action":"VoteApprove","proposal":{"FunctionCall":{"receiver_id":"attacker.near","actions":[
              {"method_name":"ping","args":"\(args)","deposit":"+1000000000000000000000000000","gas":"1"}]}}}
            """, deposit: .zero)])
        XCTAssertTrue(plus.text.contains("1000 NEAR"), "a + prefixed deposit is the real amount")

        let garbage = try display(receiver: "dao.sputnik-dao.near", [call("act_proposal", """
            {"id":1,"action":"VoteApprove","proposal":{"FunctionCall":{"receiver_id":"attacker.near","actions":[
              {"method_name":"ping","args":"\(args)","deposit":"0x10","gas":"1"}]}}}
            """, deposit: .zero)])
        XCTAssertFalse(garbage.primarySections.contains { $0.title.contains("Call 1 of 1") }, "no summary built on a guess")
        XCTAssertTrue(garbage.warnings.contains { $0.contains("could not read every value") })
        XCTAssertTrue(garbage.text.contains("0x10"), "the raw value is shown")
    }

    // MARK: Attached NEAR (high)

    func testAttachedNearIsAlwaysVisible() throws {
        let storage = try display(receiver: "unknown-token.near", [
            call("storage_deposit", #"{"account_id":"attacker.near"}"#, deposit: U128(decimal: "500000000000000000000000000")!),
            call("ft_transfer", #"{"receiver_id":"bob.near","amount":"1"}"#),
        ])
        XCTAssertTrue(storage.warnings.contains { $0.contains("storage deposit of 500 NEAR is unusually large") })
        XCTAssertTrue(storage.primarySections[0].fields.contains { $0.label == "Total attached NEAR" && $0.value.hasPrefix("500") })

        let bond = try display(receiver: "evil.sputnik-dao.near", [call("add_proposal", #"{"proposal":{"description":"","kind":"Vote"}}"#,
                                                                        deposit: U128(decimal: "1000000000000000000000000000")!)])
        XCTAssertTrue(bond.warnings.contains { $0.contains("proposal bond is 1000 NEAR") })
        guard case let .dao(action) = try XCTUnwrap(bond.highlight) else { return XCTFail("expected a DAO card") }
        XCTAssertEqual(action.bond, "1000 NEAR")
    }

    func testVotingOnTextIsFlagged() throws {
        let vote = try display(receiver: "dao.sputnik-dao.near", [call("act_proposal", #"{"id":3,"action":"VoteApprove","proposal":"Vote"}"#, deposit: .zero)])
        // The card marks the description as the website's; the field label says so too.
        XCTAssertTrue(vote.primarySections[0].fields.contains { $0.label == "Described by the website as" })
        guard case let .dao(action) = try XCTUnwrap(vote.highlight), case let .vote(_, _, summary) = action.kind else {
            return XCTFail("expected a vote card")
        }
        XCTAssertEqual(summary, "Poll (no action is executed)")
    }

    // MARK: Unknown fields, duplicates, invisible characters

    func testUnknownIntentFieldsAreShownAndDisableTheCard() throws {
        let display = try intents("""
            {"signer_id":"alice.near","deadline":"x","intents":[{"intent":"ft_withdraw","token":"usdt.tether-token.near",
             "receiver_id":"bob.near","amount":"1000000","storage_deposit":"900000000000000000000000000","surprise":1}]}
            """)
        XCTAssertTrue(display.warnings.contains { $0.contains("storage deposit of 900 NEAR") })
        XCTAssertTrue(display.warnings.contains { $0.contains("ft_withdraw.surprise") })
        XCTAssertNil(display.highlight)
    }

    func testDuplicateKeysDisableTheSummary() throws {
        XCTAssertTrue(JSONInspector.hasDuplicateKeys(Data(#"{"a":1,"b":{"c":1,"c":2}}"#.utf8)))
        XCTAssertTrue(JSONInspector.hasDuplicateKeys(Data(#"{"amount":"1","amount":"9"}"#.utf8)))
        XCTAssertFalse(JSONInspector.hasDuplicateKeys(Data(#"{"a":[{"a":1},{"a":2}],"b":"\"a\""}"#.utf8)))
        let duplicate = try display(receiver: usdc, [call("ft_transfer", #"{"receiver_id":"bob.near","amount":"1","amount":"9000000000"}"#)])
        XCTAssertNil(duplicate.highlight)
        XCTAssertTrue(duplicate.warnings.contains { $0.contains("repeat a key") })
    }

    func testInvisibleCharactersAreEscaped() throws {
        let display = try display(receiver: "game.near", [call("claim\nReward: 0 NEAR\u{202E}", "{}", deposit: .zero)])
        XCTAssertFalse(display.title.contains("\n"))
        XCTAssertFalse(display.title.contains("\u{202E}"))
        XCTAssertTrue(display.title.contains("\\u{A}") && display.title.contains("\\u{202E}"))
        XCTAssertEqual(NearFormat.visible("a\nb", allowNewlines: true), "a\nb")
        XCTAssertEqual(NearFormat.visible("zero\u{200B}width"), "zero\\u{200B}width")
    }

    /// Final audit, display: nothing a host controls hides what matters.
    func testFinalAuditDisplayFixes() throws {
        // "nep141:" names no contract, and must not read as native NEAR (an imt: token can use it).
        XCTAssertFalse(TokenAmount(raw: U128(5), tokenId: "imt:evil.near:nep141:").isKnown)
        XCTAssertFalse(TokenAmount(raw: U128(5), tokenId: "nep141:").isKnown)
        XCTAssertTrue(TokenAmount(raw: U128(5), tokenId: "").isKnown, "a bare empty id is native NEAR")

        // A tall stack of combining marks is escaped beyond the third.
        let stacked = "rent" + String(repeating: "\u{0301}", count: 10)
        XCTAssertEqual(NearFormat.visible(stacked), "rent\u{0301}\u{0301}\u{0301}" + String(repeating: "\\u{301}", count: 7))
        XCTAssertEqual(NearFormat.visible("Việt"), "Việt")

        // A withdrawal from NEAR Intents with a msg warns, and its card shows the message.
        let withdrawArgs = #"{"token":"usdt.tether-token.near","receiver_id":"bridge.near","amount":"1000000","msg":"to:attacker"}"#
        let withdraw = try display(receiver: "intents.near", [call("ft_withdraw", withdrawArgs)])
        XCTAssertTrue(withdraw.warnings.contains { $0.contains("acts on the message shown") })
        guard case let .tokenMove(move)? = withdraw.highlight else { return XCTFail("expected a card") }
        XCTAssertEqual(move.message, "to:attacker")

        // A DAO bounty says how many times it pays.
        let bounty = try display(receiver: "dao.sputnik-dao.near", [call("add_proposal", """
            {"proposal":{"description":"x","kind":{"AddBounty":{"bounty":{"description":"d","token":"",\
            "amount":"1000000000000000000000000","times":1000,"max_deadline":"604800000000000"}}}}}
            """, deposit: U128(decimal: "100000000000000000000000")!)])
        XCTAssertTrue(bounty.warnings.contains { $0.contains("can be paid 1000 times") })
        XCTAssertEqual(NearFormat.duration(nanoseconds: 604_800_000_000_000), "7 days")
        XCTAssertEqual(NearFormat.duration(nanoseconds: 90_061_000_000_000), "1 day 1 hour 1 minute 1 second")
    }

    /// Ids may break anywhere when they wrap, so iOS never adds a hyphen they don't have.
    func testIdsWrapWithoutHyphens() {
        let zwsp = "\u{200B}"
        func plain(_ text: String) -> String { text.replacingOccurrences(of: zwsp, with: "") }
        let warning = "imt:51e8f94d:nep141:eth-0xa0b8.omft.near is not in NEAR Signer's token list. Check bob.near."
        let wrapped = NearFormat.wrappingIDs(warning)
        XCTAssertEqual(plain(wrapped), warning, "nothing visible changes")
        XCTAssertTrue(wrapped.hasPrefix("i\(zwsp)m\(zwsp)t\(zwsp):"))
        // Ordinary words stay whole; punctuation after an id stays attached to it.
        XCTAssertTrue(wrapped.contains(" is not in NEAR Signer's token list. Check "))
        XCTAssertTrue(wrapped.hasSuffix("b\(zwsp)o\(zwsp)b\(zwsp).\(zwsp)n\(zwsp)e\(zwsp)a\(zwsp)r."))
        // Implicit ids, shortened ids and keys break anywhere; amounts and dates without letters don't change.
        let implicit = String(repeating: "ab", count: 32)
        XCTAssertEqual(NearFormat.wrappingIDs(implicit).count, 127)
        XCTAssertEqual(NearFormat.wrappingIDs("Send 1 234.5 USDC to 5bb0a9…8123ca"),
                       "Send 1 234.5 USDC to 5\(zwsp)b\(zwsp)b\(zwsp)0\(zwsp)a\(zwsp)9\(zwsp)…\(zwsp)8\(zwsp)1\(zwsp)2\(zwsp)3\(zwsp)c\(zwsp)a")
        XCTAssertEqual(NearFormat.wrappingIDs("(alice)"), "(alice)")
        XCTAssertEqual(NearFormat.wrappingIDs(""), "")
    }

    func testLongArgumentsNameEveryField() throws {
        let memo = String(repeating: "x", count: 20_000)
        let display = try display(receiver: "app.near", [call("act", #"{"memo":"\#(memo)","receiver_id":"attacker.near"}"#, deposit: .zero)])
        XCTAssertTrue(display.warnings.contains { $0.contains("Top-level fields: memo, receiver_id") })
    }

    // MARK: Decoding

    func testByteOrderMarkAndNonCanonicalPayloadsAreRefused() throws {
        var writer = BorshWriter()
        writer.writeString("alice.near")
        let tx = Transaction(signerId: "alice.near", publicKey: .ed25519(key), nonce: 1, receiverId: "bob.near",
                             blockHash: Data(repeating: 1, count: 32), actions: [.transfer(deposit: U128(1))])
        var payload = tx.borsh
        // Prefix the receiver with a UTF-8 byte-order mark (and fix its length).
        let receiver = Data("bob.near".utf8)
        let range = try XCTUnwrap(payload.range(of: Data([UInt8(receiver.count), 0, 0, 0]) + receiver))
        payload.replaceSubrange(range, with: Data([UInt8(receiver.count + 3), 0, 0, 0, 0xEF, 0xBB, 0xBF]) + receiver)
        XCTAssertThrowsError(try PreparedRequest(kind: .transaction, payload: payload))
    }

    func testTooManyActionsAreRefused() throws {
        let tx = Transaction(signerId: "alice.near", publicKey: .ed25519(key), nonce: 1, receiverId: "a.alice.near",
                             blockHash: Data(repeating: 1, count: 32), actions: Array(repeating: .createAccount, count: 101))
        XCTAssertThrowsError(try PreparedRequest(kind: .transaction, payload: tx.borsh)) { error in
            XCTAssertEqual(error as? BorshError, .tooManyElements(count: 101, limit: 100))
        }
        let ok = Transaction(signerId: "alice.near", publicKey: .ed25519(key), nonce: 1, receiverId: "a.alice.near",
                             blockHash: Data(repeating: 1, count: 32), actions: Array(repeating: .createAccount, count: 100))
        XCTAssertNoThrow(try PreparedRequest(kind: .transaction, payload: ok.borsh))
    }

    func testOtherCoinTypesAreRefused() async throws {
        let service = SignerService(vault: InMemoryKeyVault(material: material), presenter: ScriptedPresenter(answers: [true]),
                                    history: HistoryStore(fileURL: nil))
        let session = NearAppSession(service: service, transport: "test")
        let sui = BIP32Path(hardened: [44, 784, 0, 0, 0])
        let response = await session.handle(NearAPDU.getPublicKey(path: sui, display: false).serialized)
        XCTAssertEqual(response, StatusWord.badPath.bytes)
        XCTAssertFalse(AccountBook.isValidAccountPath(sui))
        XCTAssertNil(PublicKey(string: "ed25519:" + String(repeating: "1", count: 60_000)))
    }

    // MARK: History

    func testRefusedRequestsDoNotFillTheHistory() async throws {
        let history = HistoryStore(fileURL: nil, maxRecords: 5)
        let service = SignerService(vault: InMemoryKeyVault(material: material), presenter: ScriptedPresenter(answers: [true]),
                                    history: history)
        let fixture = Data(base64Encoded: Fixtures.transactions[0].borsh)!
        _ = await service.sign(kind: .transaction, path: .ledgerDefault, payload: fixture, transport: "test")
        for _ in 0..<10 {
            _ = await service.sign(kind: .transaction, path: .ledgerDefault, payload: Data(repeating: 0xFF, count: 100_000), transport: "test")
        }
        let records = await history.all()
        XCTAssertEqual(records.count, 5)
        XCTAssertTrue(records.contains { $0.outcome == .approved }, "refusals never push out an approved request")
        let refused = try XCTUnwrap(records.first)
        XCTAssertTrue(refused.payload.isEmpty)
        XCTAssertEqual(refused.payloadSize, 100_000)
    }

    func testPayloadBudget() async throws {
        let history = HistoryStore(fileURL: nil, maxPayloadBytes: 250)
        for index in 0..<4 {
            try await history.append(HistoryRecord(kind: .transaction, outcome: .approved, transport: "t", path: "",
                                                   title: "\(index)", payload: Data(repeating: 1, count: 100)))
        }
        let sizes = await history.all().map(\.payload.count)
        XCTAssertEqual(sizes, [100, 100, 0, 0])
        let kept = await history.all().map(\.payloadSize)
        XCTAssertEqual(kept, [100, 100, 100, 100])
    }

    // MARK: Transport

    /// A lost BLE packet gets one immediate error reply; the rest of that message is ignored and
    /// the next message works.
    func testLostPacketFailsFast() async throws {
        let service = SignerService(vault: InMemoryKeyVault(material: material), presenter: ScriptedPresenter(answers: [true]),
                                    history: HistoryStore(fileURL: nil))
        let link = BLELink(session: NearAppSession(service: service, transport: "test"), packetSize: 64)
        let tx = Data(base64Encoded: Fixtures.transactions[0].borsh)!
        let command = NearAPDU.signCommands(ins: NearAPDU.insSignTransaction, path: .ledgerDefault, payload: tx, chunkSize: 4096)[0]
        let packets = BLEFraming.frames(for: command.serialized, packetSize: 64)
        XCTAssertGreaterThanOrEqual(packets.count, 3)
        var replies: [Data] = []
        for (index, packet) in packets.enumerated() where index != 1 {   // packet 1 is lost
            replies += await link.receive(packet)
        }
        XCTAssertEqual(replies.count, 1)
        var assembler = BLEFrameAssembler()
        guard case let .apdu(answer) = try assembler.receive(replies[0]) else { return XCTFail("expected a reply") }
        XCTAssertEqual(answer, StatusWord.invalidData.bytes)

        // A retry from the start succeeds.
        var response = Data()
        for packet in packets {
            for notification in await link.receive(packet) {
                if case let .apdu(data) = try assembler.receive(notification) { response = data }
            }
        }
        XCTAssertEqual(response.suffix(2), StatusWord.ok.bytes)
    }

    // MARK: Wallets

    func testDuplicateWalletDetectedAfterHidingAccountOne() throws {
        var list = WalletList()
        var wallet = Wallet(kind: .recoveryPhrase)
        try wallet.book.add(path: .ledgerDefault, publicKey: key)
        try list.add(wallet)
        let walletID = try XCTUnwrap(list.wallets.first?.id)
        let second = AccountBook.standardPath(index: 2)
        list.rememberAccount(walletID: walletID, path: second, publicKey: try material.privateKey(for: second).publicKey.rawRepresentation)
        let accountOne = try XCTUnwrap(list.wallet(id: walletID)?.book.account(for: .ledgerDefault))
        list.removeAccount(id: accountOne.id)
        var again = Wallet(kind: .recoveryPhrase)
        try again.book.add(path: .ledgerDefault, publicKey: key)
        XCTAssertThrowsError(try list.add(again))
    }

    func testKnownMismatchesCanBeCleared() async throws {
        let service = SignerService(vault: InMemoryKeyVault(material: material), presenter: ScriptedPresenter(answers: [true, true]),
                                    history: HistoryStore(fileURL: nil))
        let fixture = Data(base64Encoded: Fixtures.transactions[0].borsh)!
        let other = AccountBook.standardPath(index: 2)
        _ = await service.sign(kind: .transaction, path: other, payload: fixture, transport: "test")
        await service.clearKnownMismatches()
        // After clearing, the request reaches the user again (and fails the key check again).
        let result = await service.sign(kind: .transaction, path: other, payload: fixture, transport: "test")
        XCTAssertEqual(result, .failure(.publicKeyMismatch))
    }

    // MARK: Re-review

    /// A recognized summary keeps the generic warnings (here: arguments too long to show whole,
    /// and a meta-transaction whose network can't be told).
    func testRecognizedSummariesKeepGenericWarnings() throws {
        let memo = String(repeating: "m", count: 20_000)
        let long = try display(receiver: "usdt.tether-token.near",
                               [call("ft_transfer", #"{"receiver_id":"bob.near","amount":"1","memo":"\#(memo)"}"#)])
        XCTAssertNotNil(long.highlight)
        XCTAssertTrue(long.warnings.contains { $0.contains("only the start is shown") })
        XCTAssertFalse(long.warnings.contains { $0.hasPrefix("Attaches ") }, "the card shows the attached NEAR itself")

        let delegate = DelegateAction(senderId: "alice.tg", receiverId: "token.sweat",
                                      actions: [call("ft_transfer", #"{"receiver_id":"bob.tg","amount":"1"}"#)],
                                      nonce: 1, maxBlockHeight: 100, publicKey: .ed25519(key))
        let meta = try PreparedRequest(kind: .nep366, payload: delegate.borsh).display
        XCTAssertNotNil(meta.highlight)
        XCTAssertTrue(meta.warnings.contains { $0.contains("network can't be told") })
    }

    /// Nested JSON is held to the same rules as the arguments: a repeated key or a value too long
    /// to show whole means no summary.
    func testNestedJSONFallsBack() throws {
        let duplicate = try display(receiver: "usdt.tether-token.near", [call("ft_transfer_call", """
            {"receiver_id":"pool.near","amount":"1","msg":"{\\"to\\":\\"bob.near\\",\\"to\\":\\"attacker.near\\"}"}
            """)])
        XCTAssertNil(duplicate.highlight)
        let long = String(repeating: "x", count: 20_000)
        let truncated = try display(receiver: "usdt.tether-token.near",
                                    [call("ft_transfer_call", #"{"receiver_id":"pool.near","amount":"1","msg":"\#(long)"}"#)])
        XCTAssertNil(truncated.highlight)
        let plain = try display(receiver: "usdt.tether-token.near",
                                [call("ft_transfer_call", #"{"receiver_id":"pool.near","amount":"1","msg":"say \"hi"}"#)])
        XCTAssertNotNil(plain.highlight, "text that isn't JSON has no keys to repeat")

        let args = Data(#"{"receiver_id":"bob.near","receiver_id":"attacker.near","amount":"1"}"#.utf8).base64EncodedString()
        let dao = try display(receiver: "dao.sputnik-dao.near", [call("add_proposal", """
            {"proposal":{"description":"pay","kind":{"FunctionCall":{"receiver_id":"usdt.tether-token.near","actions":[
              {"method_name":"ft_transfer","args":"\(args)","deposit":"1","gas":"1"}]}}}}
            """, deposit: U128(decimal: "100000000000000000000000")!)])
        XCTAssertTrue(dao.warnings.contains { $0.contains("could not read every value") })
        XCTAssertFalse(dao.text.contains("Token transfer"))
    }

    func testStorageDepositNamesTheAccount() throws {
        let registered = try display(receiver: "usdt.tether-token.near", [
            call("storage_deposit", #"{"account_id":"carol.near","registration_only":true}"#, deposit: U128(decimal: "1250000000000000000000")!),
            call("ft_transfer", #"{"receiver_id":"bob.near","amount":"1"}"#),
        ])
        XCTAssertTrue(registered.primarySections[0].fields.contains { $0.label == "Storage deposit" && $0.value.contains("registers carol.near") })
        let unreadable = try display(receiver: "usdt.tether-token.near", [
            call("storage_deposit", #"{"account_id":"carol.near","account_id":"bob.near"}"#),
            call("ft_transfer", #"{"receiver_id":"bob.near","amount":"1"}"#),
        ])
        XCTAssertNil(unreadable.highlight)
    }

    func testIntentsKeyCallNeedsAKey() throws {
        let shown = try display(receiver: "intents.near", [call("add_public_key", #"{"key":"ed25519:abc"}"#)])
        XCTAssertNil(shown.highlight)
        XCTAssertFalse(shown.title.contains("Add a key to your"))
    }

    func testMoreInvisibleCharactersAreEscaped() {
        for scalar in ["\u{3164}", "\u{115F}", "\u{FE0F}", "\u{2800}", "\u{00A0}", "\u{2007}", "\u{3000}", "\u{E0041}"] {
            XCTAssertTrue(NearFormat.visible("a\(scalar)b").contains("\\u{"), "\(scalar.unicodeScalars.first!.value)")
        }
        XCTAssertEqual(NearFormat.visible("1\u{202F}000 USDt"), "1\u{202F}000 USDt")
        let delegate = DelegateAction(senderId: "alice\u{3164}.near", receiverId: "bob.near", actions: [.transfer(deposit: U128(1))],
                                      nonce: 1, maxBlockHeight: 100, publicKey: .ed25519(key))
        let prepared = try? PreparedRequest(kind: .nep366, payload: delegate.borsh)
        let record = prepared?.historyRecord(outcome: .rejected, transport: "t", path: .ledgerDefault, payload: Data(),
                                             publicKey: nil, signature: nil, failureReason: nil)
        XCTAssertEqual(record?.signerId, "alice\\u{3164}.near")
    }

    /// Any framing error drops the rest of that message quietly: one error reply, not one per packet.
    func testFramingErrorsDiscardTheMessage() throws {
        var assembler = BLEFrameAssembler()
        XCTAssertEqual(try assembler.receive(Data([0x05, 0, 0, 0, 10, 1, 2])), .none)
        XCTAssertThrowsError(try assembler.receive(Data([0x07, 0, 1, 3])))
        XCTAssertEqual(try assembler.receive(Data([0x05, 0, 1, 3, 4, 5])), .none)
        XCTAssertThrowsError(try assembler.receive(Data([0x05, 0, 0, 0])), "short first packet")
        XCTAssertEqual(try assembler.receive(Data([0x05, 0, 1, 3])), .none)
        XCTAssertEqual(try assembler.receive(Data([0x05, 0, 0, 0, 2, 9, 9])), .apdu(Data([9, 9])))
    }

    /// A message that loses its first packet while an earlier one is still being dropped gets its
    /// own error reply, instead of none (the host would wait minutes).
    func testLostFirstPacketAfterAnErrorIsAnswered() throws {
        var assembler = BLEFrameAssembler()
        XCTAssertEqual(try assembler.receive(Data([0x05, 0, 0, 0, 10, 1, 2])), .none)
        XCTAssertThrowsError(try assembler.receive(Data([0x05, 0, 2, 3])), "packet 1 lost")
        XCTAssertEqual(try assembler.receive(Data([0x05, 0, 3, 4])), .none, "rest of the message dropped quietly")
        XCTAssertEqual(try assembler.receive(Data([0x09])), .none, "no second reply for more garbage")
        // The next message's packet 0 is lost: its packet 1 is reported once.
        XCTAssertThrowsError(try assembler.receive(Data([0x05, 0, 1, 7])))
        XCTAssertEqual(try assembler.receive(Data([0x05, 0, 2, 8])), .none)
        XCTAssertEqual(try assembler.receive(Data([0x05, 0, 0, 0, 1, 9])), .apdu(Data([9])))
    }

    /// A host that opens the transport again (MTU probe) starts clean: chunks an earlier upload left
    /// behind are not glued onto its request.
    func testProbeDropsAHalfSentUpload() async throws {
        let service = SignerService(vault: InMemoryKeyVault(material: material), presenter: ScriptedPresenter(answers: [true]),
                                    history: HistoryStore(fileURL: nil))
        let link = BLELink(session: NearAppSession(service: service, transport: "test"), packetSize: 64)
        var assembler = BLEFrameAssembler()
        func exchange(_ command: APDUCommand) async throws -> Data {
            var reply = Data()
            for packet in BLEFraming.frames(for: command.serialized, packetSize: 64) {
                for notification in await link.receive(packet) {
                    if case let .apdu(data) = try assembler.receive(notification) { reply = data }
                }
            }
            return reply
        }
        let tx = try XCTUnwrap(Data(base64Encoded: Fixtures.transactions[0].borsh))
        let commands = NearAPDU.signCommands(ins: NearAPDU.insSignTransaction, path: .ledgerDefault, payload: tx, chunkSize: 64)
        let first = try await exchange(commands[0])
        XCTAssertEqual(first, StatusWord.ok.bytes)
        _ = await link.receive(Data([BLEFraming.mtuTag, 0, 0, 0, 0]))
        var response = Data()
        for command in commands { response = try await exchange(command) }
        XCTAssertEqual(response.suffix(2), StatusWord.ok.bytes)
    }

    /// Refused requests lose their bytes before approved ones do.
    func testPayloadBudgetDropsRefusedBytesFirst() async throws {
        let history = HistoryStore(fileURL: nil, maxPayloadBytes: 250)
        try await history.append(HistoryRecord(kind: .transaction, outcome: .approved, transport: "t", path: "",
                                               title: "approved", payload: Data(repeating: 1, count: 100)))
        for index in 0..<3 {
            try await history.append(HistoryRecord(kind: .transaction, outcome: .rejected, transport: "t", path: "",
                                                   title: "\(index)", payload: Data(repeating: 1, count: 100)))
        }
        let sizes = await history.all().map(\.payload.count)
        XCTAssertEqual(sizes, [100, 0, 0, 100])
    }

    /// Automatic refusals are written in batches; `flush` writes them at once.
    func testDeferredHistoryWrites() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let history = HistoryStore(fileURL: url)
        try await history.append(HistoryRecord(kind: .transaction, outcome: .failed, transport: "t", path: "", title: "auto"),
                                 deferWrite: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try await history.flush()
        XCTAssertEqual(HistoryStore(fileURL: url).fileURL, url)
        let reread = await HistoryStore(fileURL: url).all()
        XCTAssertEqual(reread.map(\.title), ["auto"])
    }

    /// Signing results show the vault's message, not an enum case name such as `biometryChanged`.
    func testFailuresAreReadable() {
        struct Locked: UserFacingError { var userMessage: String { "Remove the wallet and restore it." } }
        enum Plain: Error { case broken }
        XCTAssertEqual(SignerService.readable(Locked()), "Remove the wallet and restore it.")
        XCTAssertEqual(SignerService.readable(Plain.broken), "broken")
    }

    // MARK: Camera transfer

    /// A hostile screen declares 65 535 one-byte fragments and holds up codes that mix tens of
    /// thousands of them. Choosing their fragments costs a dictionary and a set that size on the
    /// main actor at every camera read, and keeping them would cost gigabytes: frames that mix
    /// more than 1024 fragments are skipped before their fragments are chosen.
    func testFramesMixingThousandsOfFragmentsAreSkipped() throws {
        let count = OpticalFrame.maxFragmentCount
        let sender = try OpticalSender(message: Data(repeating: 0x5A, count: count), sessionId: 77, fragmentSize: 1)
        let receiver = OpticalReceiver()
        let wide = (UInt32(count)..<UInt32(2 * count))
            .filter { Fountain.degree(sessionId: 77, sequence: $0, fragmentCount: count) > OpticalReceiver.maxMixedDegree }
            .prefix(20)
        XCTAssertEqual(wide.count, 20)
        for sequence in wide.prefix(3) {
            XCTAssertEqual(Fountain.indexes(sessionId: 77, sequence: sequence, fragmentCount: count).count,
                           Fountain.degree(sessionId: 77, sequence: sequence, fragmentCount: count))
        }
        let texts = wide.map { sender.frame($0).text }
        let started = Date()
        for _ in 0..<50 {
            for text in texts { XCTAssertEqual(receiver.receive(text), .duplicate) }
        }
        XCTAssertEqual(receiver.heldIndexes, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "1000 reads of wide codes")
        let narrow = try XCTUnwrap((UInt32(count)..<UInt32(2 * count)).first {
            Fountain.degree(sessionId: 77, sequence: $0, fragmentCount: count) == 3
        })
        _ = receiver.receive(sender.frame(narrow).text)
        XCTAssertEqual(receiver.heldIndexes, 3, "a frame of a few fragments is kept")
    }

    /// Frames of up to 1024 fragments are kept while they fit: at most 16 unknown indexes per
    /// fragment in all, the oldest frames going first.
    func testMixedFramesHoldABoundedNumberOfIndexes() throws {
        let count = 4096
        let budget = OpticalReceiver.heldIndexesPerFragment * count
        let sender = try OpticalSender(message: Data(repeating: 0x5A, count: count), sessionId: 78, fragmentSize: 1)
        let receiver = OpticalReceiver()
        var fed = 0
        // Odd blocks of K frames are the mixed ones; nothing is known, so nothing peels.
        for block in stride(from: 1, to: 40, by: 2) where fed <= budget {
            for sequence in UInt32(block * count)..<UInt32((block + 1) * count) {
                let degree = Fountain.degree(sessionId: 78, sequence: sequence, fragmentCount: count)
                guard (100...OpticalReceiver.maxMixedDegree).contains(degree) else { continue }
                _ = receiver.receive(sender.frame(sequence).text)
                fed += degree
                XCTAssertLessThanOrEqual(receiver.heldIndexes, budget)
            }
        }
        XCTAssertGreaterThan(fed, budget, "frames mixing more than the budget were shown")
        XCTAssertGreaterThan(receiver.heldIndexes, budget - OpticalReceiver.maxMixedDegree, "kept while they fit")
    }

    func testSecretBytes() {
        let a = SecretBytes(Data([1, 2, 3]))
        XCTAssertEqual(a, SecretBytes([1, 2, 3] as [UInt8]))
        XCTAssertNotEqual(a, SecretBytes(Data([1, 2, 4])))
        XCTAssertEqual(a.data, Data([1, 2, 3]))
        XCTAssertEqual(SecretBytes(Data()).count, 0)
    }
}
