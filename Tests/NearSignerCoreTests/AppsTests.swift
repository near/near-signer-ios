import Foundation
import XCTest
@testable import NearSignerCore

final class AppsTests: XCTestCase {
    private let usdc = "17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1"
    private let key = PublicKey.ed25519(Data(repeating: 9, count: 32))

    private func call(_ method: String, _ args: String, deposit: U128 = U128(1)) -> Action {
        .functionCall(FunctionCallAction(methodName: method, args: Data(args.utf8), gas: 30_000_000_000_000, deposit: deposit))
    }

    private func display(signer: String = "alice.near", receiver: String, _ actions: [Action]) throws -> RequestDisplay {
        let tx = Transaction(signerId: signer, publicKey: key, nonce: 1, receiverId: receiver,
                             blockHash: Data(repeating: 1, count: 32), actions: actions)
        return try PreparedRequest(kind: .transaction, payload: tx.borsh).display
    }

    private func move(_ display: RequestDisplay) throws -> TokenMove {
        guard case let .tokenMove(move) = try XCTUnwrap(display.highlight) else {
            XCTFail("expected a token move")
            throw XCTSkip()
        }
        return move
    }

    func testTokenAmountFormatting() {
        XCTAssertEqual(NearFormat.tokenAmount(U128(1_234_567_890), decimals: 6), "1\u{202F}234.56789")
        XCTAssertEqual(NearFormat.tokenAmount(U128(1_000_000_000), decimals: 6), "1\u{202F}000")
        XCTAssertEqual(NearFormat.tokenAmount(.zero, decimals: 6), "0")
        XCTAssertEqual(NearFormat.tokenAmount(U128(1), decimals: 24), "0.000000000000000000000001")
        XCTAssertEqual(NearFormat.tokenAmount(U128(decimal: "123456789000000000000000000000")!, decimals: 24), "123\u{202F}456.789")
        XCTAssertEqual(TokenAmount(raw: "2980000", tokenId: "nep141:\(usdc)")?.text, "2.98 USDC")
        XCTAssertEqual(TokenAmount(raw: "5", tokenId: "foo.near")?.text, "5 units of foo.near")
        XCTAssertNil(TokenAmount(raw: "-5", tokenId: "foo.near"))
    }

    func testFungibleTokenTransfers() throws {
        let send = try display(receiver: usdc, [call("ft_transfer", #"{"receiver_id":"bob.near","amount":"1000000000","memo":"rent"}"#)])
        XCTAssertEqual(send.title, "Send 1\u{202F}000 USDC to bob.near")
        XCTAssertEqual(send.symbol, .send)
        XCTAssertTrue(send.warnings.isEmpty, "the 1 yoctoNEAR security deposit is not worth a warning")
        let sendMove = try move(send)
        XCTAssertEqual(sendMove.kind, .send)
        XCTAssertEqual(sendMove.amount.text, "1\u{202F}000 USDC")
        XCTAssertEqual(sendMove.counterparty, "bob.near")
        XCTAssertEqual(sendMove.memo, "rent")
        XCTAssertEqual(send.primarySections.map(\.title), ["Token transfer"])
        XCTAssertTrue(send.technicalSections.contains { $0.title == "Function call" }, "raw call stays visible")

        // Wallets register the recipient first; the storage deposit is listed.
        let withStorage = try display(receiver: "usdt.tether-token.near", [
            call("storage_deposit", #"{"account_id":"bob.near","registration_only":true}"#, deposit: U128(decimal: "1250000000000000000000")!),
            call("ft_transfer", #"{"receiver_id":"bob.near","amount":"5000000"}"#),
        ])
        XCTAssertEqual(withStorage.title, "Send 5 USDt to bob.near")
        XCTAssertTrue(withStorage.primarySections[0].fields.contains { $0.label == "Storage deposit" })

        let unknown = try display(receiver: "foo.near", [call("ft_transfer", #"{"receiver_id":"bob.near","amount":"77"}"#)])
        XCTAssertEqual(unknown.title, "Send foo.near tokens to bob.near")
        XCTAssertTrue(unknown.warnings.contains { $0.contains("not in NEAR Signer's token list") })

        let transferCall = try display(receiver: usdc, [call("ft_transfer_call", #"{"receiver_id":"v2.ref-finance.near","amount":"1000000","msg":"{\"actions\":[]}"}"#)])
        XCTAssertEqual(transferCall.title, "Send 1 USDC to v2.ref-finance.near")
        XCTAssertTrue(transferCall.warnings.contains { $0.contains("runs its own code") })

        // Something else on a token contract is not dressed up.
        let other = try display(receiver: usdc, [call("ft_balance_of", #"{"account_id":"bob.near"}"#)])
        XCTAssertEqual(other.title, "Call ft_balance_of on \(usdc)")
        XCTAssertNil(other.highlight)
    }

    func testNearTransfers() throws {
        let send = try display(receiver: "bob.near", [.transfer(deposit: U128(decimal: "1234500000000000000000000000")!)])
        XCTAssertEqual(send.title, "Send 1\u{202F}234.5 NEAR to bob.near")
        XCTAssertEqual(send.symbol, .send)
        XCTAssertTrue(send.warnings.isEmpty)
        let sendMove = try move(send)
        XCTAssertEqual(sendMove.kind, .send)
        XCTAssertEqual(sendMove.amount.token, TokenRegistry.near)
        XCTAssertEqual(sendMove.amount.text, "1\u{202F}234.5 NEAR")
        XCTAssertEqual(sendMove.counterparty, "bob.near")
        XCTAssertEqual(send.primarySections.map(\.title), ["Transfer"])
        XCTAssertEqual(send.primarySections[0].fields.filter { $0.label.contains("NEAR") || $0.label == "Amount" }.count, 1,
                       "the amount is not repeated as an attached total")
        XCTAssertTrue(send.technicalSections.contains { $0.fields.contains { $0.label == "From" && $0.value == "alice.near" } })

        let implicit = String(repeating: "ab", count: 32)
        let toImplicit = try display(receiver: implicit, [.transfer(deposit: U128(1))])
        XCTAssertEqual(toImplicit.title, "Send 0.000000000000000000000001 NEAR to ababab…ababab", "titles shorten implicit ids")
        guard case let .tokenMove(implicitMove) = try XCTUnwrap(toImplicit.highlight) else { return XCTFail("expected a token move") }
        XCTAssertEqual(implicitMove.counterparty, implicit, "the card shows the full id")
        XCTAssertTrue(toImplicit.primarySections[0].fields.contains { $0.label == "Recipient type" && $0.value == "implicit account" })

        // Meta-transactions get the same card.
        let delegate = DelegateAction(senderId: "alice.near", receiverId: "bob.near", actions: [.transfer(deposit: U128(decimal: "2000000000000000000000000")!)],
                                      nonce: 1, maxBlockHeight: 100, publicKey: key)
        let meta = try PreparedRequest(kind: .nep366, payload: delegate.borsh).display
        XCTAssertEqual(meta.title, "Meta-tx: Send 2 NEAR to bob.near")
        XCTAssertEqual(try move(meta).amount.text, "2 NEAR")

        // A transfer plus anything else is shown action by action.
        let batch = try display(receiver: "bob.near", [.transfer(deposit: U128(1)), .transfer(deposit: U128(2))])
        XCTAssertNil(batch.highlight)
    }

    func testTransferRecipientWarnings() throws {
        let oneNear = U128(decimal: "1000000000000000000000000")!
        let toWrap = try display(receiver: "wrap.near", [.transfer(deposit: oneNear)])
        XCTAssertTrue(toWrap.warnings.contains { $0.contains("doesn't wrap it") })
        let toIntents = try display(receiver: "intents.near", [.transfer(deposit: oneNear)])
        XCTAssertTrue(toIntents.warnings.contains { $0.contains("doesn't deposit into NEAR Intents") })
        let toToken = try display(receiver: usdc, [.transfer(deposit: oneNear)])
        XCTAssertTrue(toToken.warnings.contains { $0.contains("is the USDC token contract") })
        let toSelf = try display(receiver: "alice.near", [.transfer(deposit: oneNear)])
        XCTAssertTrue(toSelf.warnings.contains { $0.contains("to itself") })
        let crossNetwork = try display(receiver: "bob.testnet", [.transfer(deposit: oneNear)])
        XCTAssertTrue(crossNetwork.warnings.contains { $0.contains("bob.testnet is a testnet name, but alice.near is a mainnet account") })
        let invalid = try display(receiver: "Bob.near", [.transfer(deposit: oneNear)])
        XCTAssertTrue(invalid.warnings.contains { $0.contains("not a valid NEAR account name") })
        for fine in ["bob.near", "0x" + String(repeating: "a", count: 40), String(repeating: "0", count: 64), "dev.sputnik-dao.near"] {
            XCTAssertTrue(try display(receiver: fine, [.transfer(deposit: oneNear)]).warnings.isEmpty, fine)
        }

        // Tokens sent with ft_transfer get the same checks; ft_transfer_call is meant for contracts.
        let tokensToContract = try display(receiver: usdc, [call("ft_transfer", #"{"receiver_id":"\#(usdc)","amount":"5"}"#)])
        XCTAssertTrue(tokensToContract.warnings.contains { $0.contains("is the USDC token contract") && $0.contains("the tokens") })
        let tokensToIntents = try display(receiver: usdc, [call("ft_transfer", #"{"receiver_id":"intents.near","amount":"5"}"#)])
        XCTAssertTrue(tokensToIntents.warnings.contains { $0.contains("doesn't deposit into NEAR Intents") })
        let deposit = try display(receiver: usdc, [call("ft_transfer_call", #"{"receiver_id":"intents.near","amount":"5","msg":""}"#)])
        XCTAssertFalse(deposit.warnings.contains { $0.contains("most likely be lost") })
    }

    func testWrappedNearAndIntentsDeposits() throws {
        let wrap = try display(receiver: "wrap.near", [call("near_deposit", "{}", deposit: U128(decimal: "2000000000000000000000000")!)])
        XCTAssertEqual(wrap.title, "Wrap 2 NEAR into wNEAR")
        let unwrap = try display(receiver: "wrap.near", [call("near_withdraw", #"{"amount":"500000000000000000000000"}"#)])
        XCTAssertEqual(unwrap.title, "Unwrap 0.5 wNEAR into NEAR")

        let deposit = try display(receiver: usdc, [call("ft_transfer_call", #"{"receiver_id":"intents.near","amount":"5000000","msg":""}"#)])
        XCTAssertEqual(deposit.title, "Deposit 5 USDC to NEAR Intents")
        XCTAssertEqual(deposit.symbol, .deposit)
        XCTAssertEqual(try move(deposit).counterparty, "alice.near", "an empty msg credits the sender")

        let forFriend = try display(receiver: usdc, [call("ft_transfer_call", #"{"receiver_id":"intents.near","amount":"5000000","msg":"carol.near"}"#)])
        XCTAssertEqual(try move(forFriend).counterparty, "carol.near")

        // NEAR deposits wrap first, then deposit wNEAR.
        let nearDeposit = try display(receiver: "wrap.near", [
            call("near_deposit", "{}", deposit: U128(decimal: "1000000000000000000000000")!),
            call("ft_transfer_call", #"{"receiver_id":"intents.near","amount":"1000000000000000000000000","msg":""}"#),
        ])
        XCTAssertEqual(nearDeposit.title, "Deposit 1 wNEAR to NEAR Intents")
        XCTAssertTrue(nearDeposit.primarySections[0].fields.contains { $0.label == "Wraps first" })

        let withdraw = try display(receiver: "intents.near", [call("ft_withdraw", #"{"token":"usdt.tether-token.near","receiver_id":"alice.near","amount":"2500000"}"#)])
        XCTAssertEqual(withdraw.title, "Withdraw 2.5 USDt from NEAR Intents to alice.near")
        let addKey = try display(receiver: "intents.near", [call("add_public_key", #"{"public_key":"ed25519:3t4F"}"#)])
        XCTAssertEqual(addKey.title, "Add a key to your NEAR Intents account")
        XCTAssertFalse(addKey.warnings.isEmpty)
    }

    func testDAOProposalsAndVotes() throws {
        let transfer = try display(receiver: "dev.sputnik-dao.near", [call("add_proposal", """
            {"proposal":{"description":"Pay the designer","kind":{"Transfer":{"token_id":"\(usdc)","receiver_id":"bob.near","amount":"100000000"}}}}
            """, deposit: U128(decimal: "100000000000000000000000")!)])
        XCTAssertEqual(transfer.title, "DAO proposal: Transfer 100 USDC to bob.near")
        XCTAssertEqual(transfer.symbol, .dao)
        guard case let .dao(dao) = try XCTUnwrap(transfer.highlight),
              case let .propose(summary, description) = dao.kind else { return XCTFail("expected a proposal") }
        XCTAssertEqual(dao.dao, "dev.sputnik-dao.near")
        XCTAssertEqual(summary, "Transfer 100 USDC to bob.near")
        XCTAssertEqual(description, "Pay the designer")
        XCTAssertTrue(transfer.primarySections[0].fields.contains { $0.label == "Bond" && $0.value.hasPrefix("0.1 NEAR") })

        let nearTransfer = try display(receiver: "dev.sputnik-dao.near", [call("add_proposal", """
            {"proposal":{"description":"","kind":{"Transfer":{"token_id":"","receiver_id":"bob.near","amount":"1500000000000000000000000"}}}}
            """)])
        XCTAssertEqual(nearTransfer.title, "DAO proposal: Transfer 1.5 NEAR to bob.near")

        let innerArgs = Data(#"{"receiver_id":"bob.near","amount":"7000000"}"#.utf8).base64EncodedString()
        let functionCall = try display(receiver: "dev.sputnik-dao.near", [call("add_proposal", """
            {"proposal":{"description":"payout","kind":{"FunctionCall":{"receiver_id":"usdt.tether-token.near","actions":[
              {"method_name":"ft_transfer","args":"\(innerArgs)","deposit":"1","gas":"30000000000000"}]}}}}
            """)])
        XCTAssertEqual(functionCall.title, "DAO proposal: Transfer 7 USDt to bob.near on usdt.tether-token.near")
        XCTAssertTrue(functionCall.warnings.isEmpty, "the summary already says what the DAO would call")
        let innerCall = try XCTUnwrap(functionCall.primarySections.first { $0.title.contains("Call 1 of 1") })
        XCTAssertTrue(innerCall.fields.contains { $0.label == "Deposit" && $0.value == "1 yoctoNEAR" && $0.style == .text })

        let member = try display(receiver: "dev.sputnik-dao.near", [call("add_proposal", """
            {"proposal":{"description":"","kind":{"AddMemberToRole":{"member_id":"carol.near","role":"council"}}}}
            """)])
        XCTAssertEqual(member.title, "DAO proposal: Add carol.near to role council")
        let poll = try display(receiver: "dev.sputnik-dao.near", [call("add_proposal", #"{"proposal":{"description":"Lunch?","kind":"Vote"}}"#)])
        XCTAssertEqual(poll.title, "DAO proposal: Poll (no action is executed)")

        let vote = try display(receiver: "dev.sputnik-dao.near", [call("act_proposal", """
            {"id":12,"action":"VoteApprove","proposal":{"Transfer":{"token_id":"","receiver_id":"bob.near","amount":"1000000000000000000000000"}}}
            """, deposit: .zero)])
        XCTAssertEqual(vote.title, "Vote Approve on proposal #12")
        XCTAssertEqual(vote.symbol, .vote)
        guard case let .dao(voteAction) = try XCTUnwrap(vote.highlight),
              case let .vote(id, choice, votedOn) = voteAction.kind else { return XCTFail("expected a vote") }
        XCTAssertEqual(id, 12)
        XCTAssertEqual(choice, "Approve")
        XCTAssertEqual(votedOn, "Transfer 1 NEAR to bob.near")
        let finalize = try display(receiver: "dev.sputnik-dao.near", [call("act_proposal", #"{"id":3,"action":"Finalize"}"#)])
        XCTAssertEqual(finalize.title, "Finalize proposal #3")
    }

    func testIntentsMessages() throws {
        func sign(_ message: String) throws -> RequestDisplay {
            let payload = NEP413Payload(message: message, nonce: Data(repeating: 2, count: 32), recipient: "intents.near", callbackUrl: nil)
            return try PreparedRequest(kind: .nep413, payload: payload.borsh).display
        }
        let swap = try sign("""
            {"signer_id":"alice.near","deadline":"2026-10-12T15:00:00Z","intents":[{"intent":"token_diff","diff":{
              "nep141:wrap.near":"-1000000000000000000000000","nep141:\(usdc)":"2980000"}}]}
            """)
        XCTAssertEqual(swap.title, "Swap 1 wNEAR for 2.98 USDC")
        XCTAssertEqual(swap.symbol, .swap)
        guard case let .swap(trade) = try XCTUnwrap(swap.highlight) else { return XCTFail("expected a swap") }
        XCTAssertEqual(trade.give.map(\.text), ["1 wNEAR"])
        XCTAssertEqual(trade.receive.map(\.text), ["2.98 USDC"])
        XCTAssertEqual(trade.deadline, "2026-10-12T15:00:00Z")
        XCTAssertTrue(swap.warnings.isEmpty, "the card says what the intent does; signing it needs no warning")
        XCTAssertTrue(swap.technicalSections.flatMap(\.fields).contains { $0.label == "Signed message" }, "raw message stays visible")

        let withdraw = try sign("""
            {"signer_id":"alice.near","deadline":"2026-10-12T15:00:00Z","intents":[
              {"intent":"ft_withdraw","token":"usdt.tether-token.near","receiver_id":"bob.near","amount":"1000000"}]}
            """)
        XCTAssertEqual(withdraw.title, "Withdraw 1 USDt to bob.near")

        let several = try sign("""
            {"signer_id":"alice.near","deadline":"2026-10-12T15:00:00Z","intents":[
              {"intent":"transfer","receiver_id":"bob.near","tokens":{"nep141:\(usdc)":"1000000"}},
              {"intent":"add_public_key","public_key":"ed25519:3t4F"}]}
            """)
        XCTAssertEqual(several.title, "Sign 2 intents for NEAR Intents")
        XCTAssertNil(several.highlight)
        XCTAssertTrue(several.warnings.contains { $0.contains("full control") })

        // Anything else stays a plain message, as do intents for another contract.
        let elsewhere = try PreparedRequest(kind: .nep413, payload: NEP413Payload(
            message: #"{"signer_id":"alice.near","deadline":"2026-10-12T15:00:00Z","intents":[]}"#,
            nonce: Data(repeating: 2, count: 32), recipient: "phish.near", callbackUrl: nil).borsh).display
        XCTAssertNil(elsewhere.highlight)
        let plain = try sign("Log in to app")
        XCTAssertEqual(plain.title, "Sign message for intents.near")
        XCTAssertNil(plain.highlight)
    }

    func testIntentsOnFAR() throws {
        func sign(_ message: String) throws -> RequestDisplay {
            let payload = NEP413Payload(message: message, nonce: Data(repeating: 2, count: 32), recipient: "intents.far", callbackUrl: nil)
            return try PreparedRequest(kind: .nep413, payload: payload.borsh).display
        }
        let issuer = "51e8f94d77b5e90dc9852ca6113771e11e8382ce69473a75e313e41665de7cbe"
        let recipient = "5bb0a9d256bed6de1daef0721b2bab5caa8d9405c1267cd0cba367bc888123ca"
        // As the FAR app sends it.
        let send = try sign("""
            {"deadline":"2026-10-16T09:28:19.922Z","intents":[{"intent":"transfer","receiver_id":"\(recipient)",\
            "tokens":{"imt:\(issuer):nep141:wrap.near":"1005025125628140703517588"}}],"signer_id":"frol.near"}
            """)
        XCTAssertEqual(send.title, "Send 1.005025125628140703517588 wNEAR to 5bb0a9…8123ca")
        let sent = try move(send)
        XCTAssertEqual(sent.venue, "NEAR Intents on FAR")
        XCTAssertEqual(sent.counterparty, recipient)
        XCTAssertEqual(sent.amount.symbol, "wNEAR")
        XCTAssertEqual(sent.amount.issuer, issuer)
        XCTAssertEqual(sent.amount.text, "1.005025125628140703517588 wNEAR issued by \(issuer)")
        XCTAssertTrue(send.warnings.isEmpty, "the FAR issuer is trusted")
        XCTAssertFalse(sent.amount.hasUntrustedIssuer)
        XCTAssertEqual(send.primarySections[0].title, "NEAR Intents on FAR")

        // The same name from anyone else is flagged.
        let stranger = String(repeating: "cd", count: 32)
        let fake = try sign("""
            {"deadline":"2026-10-16T09:28:19.922Z","intents":[{"intent":"transfer","receiver_id":"bob.near",\
            "tokens":{"imt:\(stranger):nep141:wrap.near":"1000000000000000000000000"}}],"signer_id":"frol.near"}
            """)
        XCTAssertTrue(try move(fake).amount.hasUntrustedIssuer)
        XCTAssertEqual(fake.warnings.count, 1)
        XCTAssertTrue(fake.warnings[0].contains("issued by \(stranger) inside NEAR Intents"))

        // An internal token named after nothing known stays in raw units.
        let odd = try sign("""
            {"deadline":"2026-10-16T09:28:19.922Z","intents":[{"intent":"transfer","receiver_id":"bob.near",\
            "tokens":{"imt:\(issuer):points":"5"}}],"signer_id":"frol.near"}
            """)
        XCTAssertEqual(try move(odd).amount.text, "5 units of imt:\(issuer):points")
        XCTAssertNil(TokenAmount(raw: U128(1), tokenId: "imt::nep141:wrap.near").token, "an issuer is required")

        // On-chain calls to the FAR contract are recognized too.
        let withdraw = try display(receiver: "intents.far", [call("ft_withdraw", #"{"token":"usdt.tether-token.near","receiver_id":"alice.near","amount":"2500000"}"#)])
        XCTAssertEqual(withdraw.title, "Withdraw 2.5 USDt from NEAR Intents on FAR to alice.near")
    }

    func testDAOVoteMetaTransactionHasOneWarning() throws {
        let signArgs = Data(#"{"request":{"domain_id":1,"path":"june-8th.sputnik-dao.near","payload_v2":{"Eddsa":"f2f2"}}}"#.utf8).base64EncodedString()
        let vote = call("act_proposal", """
            {"id":8,"action":"VoteApprove","proposal":{"FunctionCall":{"receiver_id":"v1.signer","actions":[
              {"method_name":"sign","args":"\(signArgs)","deposit":"1","gas":"15000000000000"}]}}}
            """, deposit: .zero)
        let delegate = DelegateAction(senderId: "frol.near", receiverId: "june-8th.sputnik-dao.near", actions: [vote],
                                      nonce: 1, maxBlockHeight: 219_799_141, publicKey: key)
        let display = try PreparedRequest(kind: .nep366, payload: delegate.borsh).display
        XCTAssertEqual(display.title, "Meta-tx: Vote Approve on proposal #8")
        XCTAssertTrue(display.warnings.isEmpty, "the card marks the website's description instead")
        guard case let .dao(action) = try XCTUnwrap(display.highlight) else { return XCTFail("expected a DAO card") }
        XCTAssertEqual(action.details.map { $0.title.trimmingCharacters(in: .whitespaces) }, ["", "Call 1 of 1 on v1.signer"])
        XCTAssertTrue(action.details[1].fields.contains { $0.label == "Method" && $0.value == "sign" })
        XCTAssertTrue(display.technicalSections.flatMap(\.fields).contains { $0.label == "Valid until block" && $0.value == "219799141" })
    }

    func testExtrasBesideTheCard() throws {
        let transfer = try display(receiver: usdc, [
            call("storage_deposit", #"{"account_id":"bob.near"}"#, deposit: U128(decimal: "1250000000000000000000")!),
            call("ft_transfer", #"{"receiver_id":"bob.near","amount":"5000000"}"#),
        ])
        XCTAssertEqual(transfer.extras.map(\.label), ["Storage deposit"])
        XCTAssertTrue(transfer.extras[0].value.hasPrefix("0.00125 NEAR"))
        XCTAssertTrue(try display(receiver: usdc, [call("ft_transfer", #"{"receiver_id":"bob.near","amount":"5"}"#)]).extras.isEmpty)
    }

    func testContractDeploymentsAreSummarized() throws {
        XCTAssertEqual(NearFormat.byteSize(512), "512 bytes")
        XCTAssertEqual(NearFormat.byteSize(1_234_567), "1.2 MB (1\u{202F}234\u{202F}567 bytes)")

        var wasm = Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])
        wasm.append(Data(repeating: 0xAB, count: 300_000))
        let deploy = try display(receiver: "alice.near", [.deployContract(code: wasm)])
        XCTAssertEqual(deploy.title, "Deploy contract to alice.near")
        let fields = deploy.primarySections.flatMap(\.fields)
        XCTAssertEqual(fields.first { $0.label == "Code size" }?.value, "293.0 KB (300\u{202F}008 bytes)")
        XCTAssertEqual(fields.first { $0.label == "Code hash" }?.value, Base58.encode(Data(SHA256.hash(data: wasm))))
        XCTAssertEqual(fields.first { $0.label == "Format" }?.value, "WebAssembly module, version 1")
        XCTAssertTrue(deploy.text.count < 4_000, "the code itself is never rendered")
        XCTAssertFalse(deploy.warnings.contains { $0.contains("not a WebAssembly") })

        let junk = try display(receiver: "alice.near", [.deployContract(code: Data(repeating: 1, count: 64))])
        XCTAssertTrue(junk.warnings.contains { $0.contains("not a WebAssembly module") })
    }

    func testAttachedNearStaysVisible() throws {
        let vote = try display(receiver: "dev.sputnik-dao.near", [call("act_proposal", #"{"id":12,"action":"VoteApprove"}"#,
                                                                       deposit: U128(decimal: "500000000000000000000000000")!)])
        XCTAssertEqual(vote.warnings.first, "Also attaches 500 NEAR to act_proposal on dev.sputnik-dao.near.")
        XCTAssertTrue(vote.primarySections[0].fields.contains { $0.label == "Attached NEAR" && $0.value == "500 NEAR" })

        let notADAO = try display(receiver: "lookalike.near", [call("act_proposal", #"{"id":1,"action":"VoteApprove"}"#, deposit: .zero)])
        XCTAssertTrue(notADAO.warnings.contains { $0.contains("not a Sputnik DAO account") })

        let token = try display(receiver: usdc, [call("ft_transfer", #"{"receiver_id":"bob.near","amount":"1"}"#, deposit: U128(2))])
        XCTAssertTrue(token.warnings.contains { $0.hasPrefix("Also attaches") })
    }
}
