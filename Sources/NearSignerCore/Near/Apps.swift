import Foundation

// MARK: - Highlight model

/// A request recognized as a common operation, for a dedicated summary card in the UI. The full
/// field list stays available in the display's sections.
public enum Highlight: Equatable, Sendable {
    case tokenMove(TokenMove)
    case swap(Swap)
    case dao(DAOAction)
}

extension Highlight {
    func sanitized() -> Highlight {
        let visible = { (text: String) in NearFormat.visible(text) }
        switch self {
        case var .tokenMove(move):
            move.amount.tokenId = visible(move.amount.tokenId)
            move.counterparty = move.counterparty.map(visible)
            move.memo = move.memo.map(visible)
            return .tokenMove(move)
        case var .swap(swap):
            swap.give = swap.give.map { var amount = $0; amount.tokenId = visible(amount.tokenId); return amount }
            swap.receive = swap.receive.map { var amount = $0; amount.tokenId = visible(amount.tokenId); return amount }
            swap.deadline = swap.deadline.map(visible)
            return .swap(swap)
        case var .dao(action):
            action.dao = visible(action.dao)
            action.details = action.details.map { $0.sanitized() }
            switch action.kind {
            case let .propose(summary, description):
                action.kind = .propose(summary: visible(summary), description: NearFormat.visible(description, allowNewlines: true))
            case let .vote(id, vote, summary):
                action.kind = .vote(proposalId: id, vote: visible(vote), summary: summary.map(visible))
            }
            return .dao(action)
        }
    }
}

/// Tokens moving from the signer: a transfer, a deposit or withdrawal, wrapping NEAR.
public struct TokenMove: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case send
        case deposit
        case withdraw
        case wrap
        case unwrap
    }

    public var kind: Kind
    public var amount: TokenAmount
    /// Recipient (send, withdraw) or the account credited (deposit).
    public var counterparty: String?
    public var memo: String?
    /// "NEAR Intents" when the move happens there.
    public var venue: String?

    public init(kind: Kind, amount: TokenAmount, counterparty: String? = nil, memo: String? = nil, venue: String? = nil) {
        self.kind = kind
        self.amount = amount
        self.counterparty = counterparty
        self.memo = memo
        self.venue = venue
    }
}

/// A NEAR Intents trade: tokens given for tokens received.
public struct Swap: Equatable, Sendable {
    public var give: [TokenAmount]
    public var receive: [TokenAmount]
    /// RFC 3339 deadline of the signed intent.
    public var deadline: String?
}

/// A Sputnik DAO proposal or vote.
public struct DAOAction: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case propose(summary: String, description: String)
        case vote(proposalId: UInt64, vote: String, summary: String?)
    }

    public var dao: String
    public var kind: Kind
    /// Proposal bond attached to `add_proposal`, formatted.
    public var bond: String? = nil
    /// What the proposal does: amounts, recipients, the calls it makes. For a vote these come
    /// from the website, like the summary.
    public var details: [DisplaySection] = []
}

/// What a recognizer contributes to a `RequestDisplay`.
struct Recognized {
    var title: String
    var symbol: DisplaySymbol
    var highlight: Highlight?
    var sections: [DisplaySection]
    var warnings: [String] = []
    /// The sections already show every NEAR the request attaches (a plain transfer).
    var showsTotal = false
    /// The sections already show every field of the actions, so the per-action rendering is
    /// not repeated in the technical details.
    var coversActions = false
    /// What the request does besides the summarized call, such as a storage deposit paid first.
    var extras: [DisplayField] = []
}

/// Recognizes NEAR transfers, fungible-token transfers (NEP-141), wrapped NEAR, Sputnik DAO proposals and votes,
/// and NEAR Intents (deposits, withdrawals and signed intents).
enum Recognizers {
    /// NEAR Intents contracts and the names the app shows for them: the one on NEAR, and the one
    /// on the FAR chain (the contract's `far` build, which adds internal `imt:` tokens).
    static let intentsContracts = ["intents.near": "NEAR Intents", "intents.far": "NEAR Intents on FAR"]

    static func intentsVenue(_ contract: String) -> String? { intentsContracts[contract] }

    // MARK: Transactions

    /// Recognizes a plain NEAR transfer or a batch of function calls on `receiverId`. Returns nil
    /// for anything else.
    static func recognize(actions: [Action], signerId: String, receiverId: String) -> Recognized? {
        if actions.count == 1, case let .transfer(deposit) = actions[0] {
            return nearTransfer(deposit, signerId: signerId, receiverId: receiverId)
        }
        var calls: [FunctionCallAction] = []
        for action in actions {
            guard case let .functionCall(call) = action else { return nil }
            calls.append(call)
        }
        guard !calls.isEmpty else { return nil }

        // Calls that wallets put before the real one.
        var extras: [DisplayField] = []
        var extraWarnings: [String] = []
        var main: [FunctionCallAction] = []
        for call in calls {
            if calls.count > 1, call.methodName == "storage_deposit" {
                // `account_id` defaults to the caller. Arguments that can't be read get the generic view.
                let storageArgs = call.args.isEmpty ? [:] : json(call.args)
                guard let storageArgs else { return nil }
                let registered = storageArgs["account_id"] as? String ?? signerId
                extras.append(DisplayField("Storage deposit", "\(NearFormat.near(call.deposit)), registers \(registered) with \(receiverId)",
                                           style: .amount))
                if call.deposit > largeStorageDeposit {
                    extraWarnings.append("The storage deposit of \(NearFormat.near(call.deposit)) is unusually large (it is normally under 0.01 NEAR).")
                }
            } else if calls.count > 1, call.methodName == "near_deposit", TokenRegistry.isWrappedNear(receiverId) {
                extras.append(DisplayField("Wraps first", "\(NearFormat.near(call.deposit)) into wNEAR"))
            } else {
                main.append(call)
            }
        }
        guard main.count == 1, let call = main.first else { return nil }
        let args = json(call.args) ?? [:]

        let venue = intentsVenue(receiverId)
        var result: Recognized?
        switch call.methodName {
        case "ft_transfer", "ft_transfer_call":
            result = fungibleTransfer(call, args: args, contract: receiverId, signerId: signerId)
        case "near_deposit" where TokenRegistry.isWrappedNear(receiverId):
            result = wrap(deposit: call.deposit, contract: receiverId)
        case "near_withdraw" where TokenRegistry.isWrappedNear(receiverId):
            result = unwrap(args: args, contract: receiverId)
        case "add_proposal":
            result = daoProposal(args: args, dao: receiverId, bond: call.deposit)
        case "act_proposal":
            result = daoVote(args: args, dao: receiverId)
        case "ft_withdraw" where venue != nil:
            result = venue.flatMap { intentsWithdraw(args: args, venue: $0) }
        case "mt_transfer" where venue != nil:
            result = venue.flatMap { intentsTransfer(args: args, venue: $0) }
        case "add_public_key" where venue != nil, "remove_public_key" where venue != nil:
            if let venue, let key = args["public_key"] as? String {
                result = intentsKey(add: call.methodName == "add_public_key", publicKey: key, venue: venue)
            }
        default:
            result = nil
        }
        guard var recognized = result else { return nil }
        recognized.extras = extras
        // NEAR attached beyond the 1 yoctoNEAR security deposit must stay in plain sight, except
        // where the card already shows it (wrapping, the proposal bond).
        if call.deposit > U128(1), call.methodName != "near_deposit", call.methodName != "add_proposal" {
            extras.insert(DisplayField("Attached NEAR", NearFormat.near(call.deposit), style: .amount), at: 0)
            recognized.warnings.insert("Also attaches \(NearFormat.near(call.deposit)) to \(call.methodName) on \(receiverId).", at: 0)
        }
        if call.methodName == "add_proposal" || call.methodName == "act_proposal", !isSputnikDAO(receiverId) {
            recognized.warnings.append("\(receiverId) is not a Sputnik DAO account; this summary assumes the Sputnik DAO format.")
        }
        recognized.warnings.append(contentsOf: extraWarnings)
        if !extras.isEmpty, !recognized.sections.isEmpty {
            recognized.sections[0].fields.append(contentsOf: extras)
        }
        return recognized
    }

    /// Storage deposits register an account with a contract and cost well under 0.01 NEAR.
    static let largeStorageDeposit = U128(decimal: "100000000000000000000000")!   // 0.1 NEAR
    /// Sputnik DAOs usually ask 0.1 NEAR; the DAO keeps the bond if a proposal is removed as spam.
    static let largeBond = U128(decimal: "1000000000000000000000000")!            // 1 NEAR

    static func isSputnikDAO(_ account: String) -> Bool {
        account.hasSuffix(".sputnik-dao.near") || account.hasSuffix(".sputnikv2.testnet")
    }

    // MARK: NEAR

    static func nearTransfer(_ deposit: U128, signerId: String, receiverId: String) -> Recognized {
        let amount = TokenAmount(raw: deposit, tokenId: "")
        var fields = [
            DisplayField("Amount", amount.text, style: .amount),
            DisplayField("Recipient", receiverId, style: .monospace),
        ]
        if let kind = NearFormat.accountKind(receiverId) {
            fields.append(DisplayField("Recipient type", kind))
        }
        return Recognized(
            title: "Send \(amount.text) to \(NearFormat.shortAccountId(receiverId))",
            symbol: .send,
            highlight: .tokenMove(TokenMove(kind: .send, amount: amount, counterparty: receiverId)),
            sections: [DisplaySection(title: "Transfer", fields: fields)],
            warnings: recipientWarnings(receiverId, signerId: signerId, asset: "NEAR"),
            showsTotal: true,
            coversActions: true)
    }

    /// Mistakes a plain transfer (NEAR, or tokens with `ft_transfer`) can't undo or won't get
    /// through. `asset` is "NEAR" or "tokens".
    static func recipientWarnings(_ receiver: String, signerId: String, asset: String) -> [String] {
        var warnings: [String] = []
        // A plain transfer doesn't run the receiver's code, so a contract can't credit the sender.
        if let venue = intentsVenue(receiver) {
            warnings.append("\(receiver) is the \(venue) contract. A plain transfer doesn't deposit into \(venue): the \(asset) would most likely be lost.")
        } else if TokenRegistry.isWrappedNear(receiver), asset == "NEAR" {
            warnings.append("\(receiver) is the wNEAR token contract. Sending NEAR to it doesn't wrap it: the NEAR would most likely be lost. Use Wrap in your app instead.")
        } else if let token = TokenRegistry.tokens.first(where: { $0.contract == receiver }) {
            warnings.append("\(receiver) is the \(token.symbol) token contract, not someone's account. A plain transfer doesn't credit anyone: the \(asset) would most likely be lost.")
        }
        if receiver == signerId {
            warnings.append("Sends \(asset) from \(signerId) to itself. Nothing moves except the fee.")
        }
        if let from = NearFormat.inferredNetwork(signerId), let to = NearFormat.inferredNetwork(receiver), from != to {
            warnings.append("\(receiver) is a \(to) name, but \(signerId) is a \(from) account. Check the recipient and the network.")
        }
        if NearFormat.isNamedAccount(receiver), !NearFormat.isValidAccountId(receiver) {
            warnings.append("\(receiver) is not a valid NEAR account name, so the network will reject this transfer.")
        }
        return warnings
    }

    // MARK: Fungible tokens

    static func fungibleTransfer(_ call: FunctionCallAction, args: [String: Any], contract: String, signerId: String) -> Recognized? {
        guard let receiver = args["receiver_id"] as? String, let raw = amount(args["amount"]) else { return nil }
        let tokens = TokenAmount(raw: raw, tokenId: contract)
        let memo = args["memo"] as? String
        var fields = [
            DisplayField("Amount", tokens.text, style: .amount),
            DisplayField("Token", tokenLabel(tokens), style: .monospace),
        ]
        var warnings = unknownTokenWarnings([tokens])

        if call.methodName == "ft_transfer_call" {
            let msg = args["msg"] as? String ?? ""
            // A message that repeats a key, or is too long to show whole, gets the generic view.
            guard !repeatsKey(Data(msg.utf8)), !isTruncated(Data(msg.utf8)) else { return nil }
            if let venue = intentsVenue(receiver) {
                // NEAR Intents credits the account named in `msg` (empty: the sender).
                let message = json(Data(msg.utf8))
                let credited = (message?["receiver_id"] as? String) ?? (msg.isEmpty || message != nil ? signerId : msg)
                fields.insert(DisplayField("Credited to", credited, style: .monospace), at: 1)
                if let intents = message?["execute_intents"] as? [Any], !intents.isEmpty {
                    warnings.append("Also executes \(intents.count) signed intent\(intents.count == 1 ? "" : "s") after the deposit.")
                }
                if let memo { fields.append(DisplayField("Memo", memo)) }
                if !msg.isEmpty { fields.append(DisplayField("Message", msg, style: .code)) }
                return Recognized(
                    title: "Deposit \(tokens.shortText) to \(venue)",
                    symbol: .deposit,
                    highlight: .tokenMove(TokenMove(kind: .deposit, amount: tokens, counterparty: credited, memo: memo, venue: venue)),
                    sections: [DisplaySection(title: "Deposit to \(venue)", fields: fields)],
                    warnings: warnings)
            }
            fields.insert(DisplayField("Recipient", receiver, style: .monospace), at: 1)
            if let memo { fields.append(DisplayField("Memo", memo)) }
            fields.append(DisplayField("Message to the recipient", msg.isEmpty ? "(empty)" : NearFormat.arguments(Data(msg.utf8)), style: .code))
            warnings.append("\(receiver) receives the tokens and runs its own code with them (ft_transfer_call). Unused tokens are usually refunded.")
            return Recognized(
                title: "Send \(tokens.shortText) to \(NearFormat.shortAccountId(receiver))",
                symbol: .send,
                highlight: .tokenMove(TokenMove(kind: .send, amount: tokens, counterparty: receiver, memo: memo)),
                sections: [DisplaySection(title: "Token transfer and call", fields: fields)],
                warnings: warnings)
        }

        fields.insert(DisplayField("Recipient", receiver, style: .monospace), at: 1)
        if let memo { fields.append(DisplayField("Memo", memo)) }
        warnings += recipientWarnings(receiver, signerId: signerId, asset: "tokens")
        return Recognized(
            title: "Send \(tokens.shortText) to \(NearFormat.shortAccountId(receiver))",
            symbol: .send,
            highlight: .tokenMove(TokenMove(kind: .send, amount: tokens, counterparty: receiver, memo: memo)),
            sections: [DisplaySection(title: "Token transfer", fields: fields)],
            warnings: warnings)
    }

    static func wrap(deposit: U128, contract: String) -> Recognized {
        let amount = TokenAmount(raw: deposit, tokenId: "")
        return Recognized(
            title: "Wrap \(amount.text) into wNEAR",
            symbol: .swap,
            highlight: .tokenMove(TokenMove(kind: .wrap, amount: amount, counterparty: contract)),
            sections: [DisplaySection(title: "Wrap NEAR", fields: [
                DisplayField("Amount", amount.text, style: .amount),
                DisplayField("Receive", "\(amount.formatted) wNEAR"),
                DisplayField("Contract", contract, style: .monospace),
            ])])
    }

    static func unwrap(args: [String: Any], contract: String) -> Recognized? {
        guard let raw = amount(args["amount"]) else { return nil }
        let amount = TokenAmount(raw: raw, tokenId: contract)
        return Recognized(
            title: "Unwrap \(amount.text) into NEAR",
            symbol: .swap,
            highlight: .tokenMove(TokenMove(kind: .unwrap, amount: amount, counterparty: contract)),
            sections: [DisplaySection(title: "Unwrap NEAR", fields: [
                DisplayField("Amount", amount.text, style: .amount),
                DisplayField("Receive", "\(amount.formatted) NEAR"),
                DisplayField("Contract", contract, style: .monospace),
            ])])
    }

    // MARK: Sputnik DAO

    static func daoProposal(args: [String: Any], dao: String, bond: U128) -> Recognized? {
        guard let proposal = args["proposal"] as? [String: Any], let kind = proposal["kind"] else { return nil }
        let description = proposal["description"] as? String ?? ""
        let parsed = proposalKind(kind)
        var warnings = parsed.warnings
        if bond > largeBond {
            warnings.insert("The proposal bond is \(NearFormat.near(bond)). The DAO keeps it if the proposal is removed as spam.", at: 0)
        }
        var fields = [
            DisplayField("DAO", dao, style: .monospace),
            DisplayField("Proposal", parsed.summary),
        ]
        fields.append(contentsOf: parsed.fields)
        if !description.isEmpty {
            fields.append(DisplayField("Description", description, style: description.count > 120 ? .code : .text))
        }
        fields.append(DisplayField("Bond", "\(NearFormat.near(bond)), returned unless the proposal is removed as spam", style: .amount))
        return Recognized(
            title: "DAO proposal: \(parsed.summary)",
            symbol: .dao,
            highlight: .dao(DAOAction(dao: dao, kind: .propose(summary: parsed.summary, description: description),
                                      bond: NearFormat.near(bond), details: parsed.details)),
            sections: [DisplaySection(title: "New proposal", fields: fields)] + parsed.nested,
            warnings: warnings)
    }

    static func daoVote(args: [String: Any], dao: String) -> Recognized? {
        guard let id = uint64(args["id"]), let action = args["action"] as? String else { return nil }
        let vote: String
        switch action {
        case "VoteApprove": vote = "Approve"
        case "VoteReject": vote = "Reject"
        case "VoteRemove": vote = "Remove (spam)"
        case "Finalize": vote = "Finalize"
        case "MoveToHub": vote = "Move to hub"
        case "AddProposal": vote = "Add proposal"
        case "RemoveProposal": vote = "Remove proposal"
        default: vote = action
        }
        let isVote = action.hasPrefix("Vote")
        var fields = [
            DisplayField("DAO", dao, style: .monospace),
            DisplayField("Proposal", "#\(id)"),
            DisplayField(isVote ? "Your vote" : "Action", vote, style: action == "VoteApprove" || action == "VoteReject" ? .amount : .text),
        ]
        var summary: String?
        var details: [DisplaySection] = []
        var nested: [DisplaySection] = []
        var warnings: [String] = []
        if let kind = args["proposal"] {
            // The vote itself names only the proposal number. This description is the website's
            // claim (newer Sputnik DAOs check it, older ones ignore it), and the label and the
            // card's mark say so.
            let parsed = proposalKind(kind)
            summary = parsed.summary
            fields.append(DisplayField("Described by the website as", parsed.summary))
            fields.append(contentsOf: parsed.fields)
            nested = parsed.nested
            details = parsed.details
            if action == "VoteApprove" { warnings = parsed.warnings }
        }
        if let memo = args["memo"] as? String { fields.append(DisplayField("Memo", memo)) }
        return Recognized(
            title: isVote ? "Vote \(vote) on proposal #\(id)" : "\(vote) proposal #\(id)",
            symbol: .vote,
            highlight: .dao(DAOAction(dao: dao, kind: .vote(proposalId: id, vote: vote, summary: summary), details: details)),
            sections: [DisplaySection(title: isVote ? "DAO vote" : "DAO proposal", fields: fields)] + nested,
            warnings: warnings)
    }

    struct ProposalKind {
        var summary: String
        var fields: [DisplayField] = []
        var nested: [DisplaySection] = []
        var warnings: [String] = []

        /// The fields and calls, for the card.
        var details: [DisplaySection] {
            (fields.isEmpty ? [] : [DisplaySection(title: "", fields: fields)]) + nested
        }
    }

    /// Sputnik DAO v2 `ProposalKind` as JSON: `"Vote"` or `{"Transfer": {...}}`.
    static func proposalKind(_ value: Any) -> ProposalKind {
        if let name = value as? String {
            return name == "Vote" ? ProposalKind(summary: "Poll (no action is executed)") : ProposalKind(summary: name)
        }
        guard let object = value as? [String: Any], object.count == 1, let entry = object.first else {
            return ProposalKind(summary: "Unknown proposal", fields: [DisplayField("Details", prettyJSON(value), style: .code)])
        }
        let (name, body) = (entry.key, entry.value)
        let fields = body as? [String: Any] ?? [:]
        switch name {
        case "Transfer":
            let token = fields["token_id"] as? String ?? ""
            let receiver = fields["receiver_id"] as? String ?? "?"
            guard let raw = amount(fields["amount"]) else { return unparsed(name, body) }
            let amount = TokenAmount(raw: raw, tokenId: token)
            var result = ProposalKind(summary: "Transfer \(amount.shortText) to \(receiver)", fields: [
                DisplayField("Amount", amount.text, style: .amount),
                DisplayField("Recipient", receiver, style: .monospace),
            ])
            if !token.isEmpty { result.fields.append(DisplayField("Token", tokenLabel(amount), style: .monospace)) }
            if let msg = fields["msg"] as? String { result.fields.append(DisplayField("Message to the recipient", msg, style: .code)) }
            result.warnings = unknownTokenWarnings([amount])
            return result
        case "FunctionCall":
            let receiver = fields["receiver_id"] as? String ?? "?"
            let actions = fields["actions"] as? [[String: Any]] ?? []
            var nested: [DisplaySection] = []
            var summaries: [String] = []
            for (index, action) in actions.enumerated() {
                let method = action["method_name"] as? String ?? "?"
                guard let args = (action["args"] as? String).flatMap({ Data(base64Encoded: $0) }),
                      let deposit = amount(action["deposit"]),
                      !repeatsKey(args), !isTruncated(args) else { return unparsed(name, body) }
                var callFields = [
                    DisplayField("Method", method, style: .monospace),
                    NearFormat.depositField(deposit),
                    DisplayField("Gas", uint64(action["gas"]).map(NearFormat.gas) ?? "?"),
                    DisplayField("Arguments", NearFormat.arguments(args), style: .code),
                ]
                // A DAO paying out tokens: describe it like a transfer.
                if method == "ft_transfer" || method == "ft_transfer_call", let inner = json(args),
                   let to = inner["receiver_id"] as? String, let raw = amount(inner["amount"]) {
                    let amount = TokenAmount(raw: raw, tokenId: receiver)
                    callFields.insert(DisplayField("Token transfer", "\(amount.text) to \(to)", style: .amount), at: 1)
                    summaries.append("Transfer \(amount.shortText) to \(to)")
                } else {
                    summaries.append("Call \(method)")
                }
                nested.append(DisplaySection(title: "  Call \(index + 1) of \(actions.count) on \(receiver)", fields: callFields))
            }
            guard !actions.isEmpty else { return unparsed(name, body) }
            let summary = summaries.count == 1 ? "\(summaries[0]) on \(receiver)" : "\(actions.count) calls on \(receiver)"
            return ProposalKind(summary: summary, fields: [DisplayField("Contract called", receiver, style: .monospace)],
                                nested: nested)
        case "AddMemberToRole":
            let member = fields["member_id"] as? String ?? "?"
            let role = fields["role"] as? String ?? "?"
            return ProposalKind(summary: "Add \(member) to role \(role)",
                                fields: [DisplayField("Member", member, style: .monospace), DisplayField("Role", role)])
        case "RemoveMemberFromRole":
            let member = fields["member_id"] as? String ?? "?"
            let role = fields["role"] as? String ?? "?"
            return ProposalKind(summary: "Remove \(member) from role \(role)",
                                fields: [DisplayField("Member", member, style: .monospace), DisplayField("Role", role)])
        case "ChangeConfig":
            return ProposalKind(summary: "Change the DAO's name, purpose or metadata",
                                fields: [DisplayField("New config", prettyJSON(body), style: .code)])
        case "ChangePolicy", "ChangePolicyAddOrUpdateRole", "ChangePolicyRemoveRole",
             "ChangePolicyUpdateDefaultVotePolicy", "ChangePolicyUpdateParameters":
            let summary: String
            switch name {
            case "ChangePolicy": summary = "Replace the DAO policy"
            case "ChangePolicyAddOrUpdateRole":
                summary = "Add or update role \(((fields["role"] as? [String: Any])?["name"] as? String) ?? "?")"
            case "ChangePolicyRemoveRole": summary = "Remove role \(fields["role"] as? String ?? "?")"
            case "ChangePolicyUpdateDefaultVotePolicy": summary = "Change the default voting rules"
            default: summary = "Change bonds and voting periods"
            }
            return ProposalKind(summary: summary, fields: [DisplayField("Details", prettyJSON(body), style: .code)],
                                warnings: ["Changes who can do what in the DAO."])
        case "UpgradeSelf":
            return ProposalKind(summary: "Upgrade the DAO contract",
                                fields: [DisplayField("Code hash", fields["hash"] as? String ?? "?", style: .monospace)],
                                warnings: ["Replaces the DAO's contract code."])
        case "UpgradeRemote":
            let receiver = fields["receiver_id"] as? String ?? "?"
            return ProposalKind(summary: "Upgrade \(receiver)", fields: [
                DisplayField("Contract", receiver, style: .monospace),
                DisplayField("Method", fields["method_name"] as? String ?? "?", style: .monospace),
                DisplayField("Code hash", fields["hash"] as? String ?? "?", style: .monospace),
            ], warnings: ["Replaces the contract code of \(receiver)."])
        case "SetStakingContract":
            return ProposalKind(summary: "Set the staking contract",
                                fields: [DisplayField("Staking contract", fields["staking_id"] as? String ?? "?", style: .monospace)])
        case "AddBounty":
            let bounty = fields["bounty"] as? [String: Any] ?? [:]
            guard let raw = amount(bounty["amount"]) else { return unparsed(name, body) }
            let amount = TokenAmount(raw: raw, tokenId: bounty["token"] as? String ?? "")
            return ProposalKind(summary: "Add a bounty of \(amount.shortText)", fields: [
                DisplayField("Reward", amount.text, style: .amount),
                DisplayField("Bounty", bounty["description"] as? String ?? ""),
            ])
        case "BountyDone":
            let receiver = fields["receiver_id"] as? String ?? "?"
            let id = uint64(fields["bounty_id"]).map(String.init) ?? "?"
            return ProposalKind(summary: "Mark bounty #\(id) done by \(receiver)",
                                fields: [DisplayField("Paid to", receiver, style: .monospace)])
        case "FactoryInfoUpdate":
            return ProposalKind(summary: "Update factory settings",
                                fields: [DisplayField("Details", prettyJSON(body), style: .code)])
        default:
            break
        }
        return ProposalKind(summary: name, fields: [DisplayField("Details", prettyJSON(body), style: .code)])
    }

    /// A proposal kind whose amounts or structure could not be read: shown raw, never summarized
    /// with a guess.
    static func unparsed(_ name: String, _ body: Any) -> ProposalKind {
        ProposalKind(summary: "\(name) (could not be fully read)",
                     fields: [DisplayField("Details", prettyJSON([name: body]), style: .code)],
                     warnings: ["NEAR Signer could not read every value of this \(name) proposal. Check the raw details."])
    }

    // MARK: NEAR Intents (on-chain calls)

    static func intentsWithdraw(args: [String: Any], venue: String) -> Recognized? {
        guard let token = args["token"] as? String, let receiver = args["receiver_id"] as? String,
              let raw = amount(args["amount"]) else { return nil }
        let amount = TokenAmount(raw: raw, tokenId: token)
        var fields = [
            DisplayField("Amount", amount.text, style: .amount),
            DisplayField("Recipient", receiver, style: .monospace),
            DisplayField("Token", tokenLabel(amount), style: .monospace),
        ]
        if let memo = args["memo"] as? String { fields.append(DisplayField("Memo", memo)) }
        if let msg = args["msg"] as? String { fields.append(DisplayField("Message to the recipient", msg, style: .code)) }
        return Recognized(
            title: "Withdraw \(amount.shortText) from \(venue) to \(NearFormat.shortAccountId(receiver))",
            symbol: .withdraw,
            highlight: .tokenMove(TokenMove(kind: .withdraw, amount: amount, counterparty: receiver,
                                            memo: args["memo"] as? String, venue: venue)),
            sections: [DisplaySection(title: "Withdraw from \(venue)", fields: fields)],
            warnings: unknownTokenWarnings([amount]))
    }

    static func intentsTransfer(args: [String: Any], venue: String) -> Recognized? {
        guard let receiver = args["receiver_id"] as? String, let tokenId = args["token_id"] as? String,
              let raw = amount(args["amount"]) else { return nil }
        let amount = TokenAmount(raw: raw, tokenId: tokenId)
        var fields = [
            DisplayField("Amount", amount.text, style: .amount),
            DisplayField("Recipient", receiver, style: .monospace),
            DisplayField("Token", tokenId, style: .monospace),
        ]
        if let memo = args["memo"] as? String { fields.append(DisplayField("Memo", memo)) }
        return Recognized(
            title: "Send \(amount.shortText) to \(NearFormat.shortAccountId(receiver)) in \(venue)",
            symbol: .send,
            highlight: .tokenMove(TokenMove(kind: .send, amount: amount, counterparty: receiver,
                                            memo: args["memo"] as? String, venue: venue)),
            sections: [DisplaySection(title: "Transfer in \(venue)", fields: fields)],
            warnings: unknownTokenWarnings([amount]))
    }

    static func intentsKey(add: Bool, publicKey: String, venue: String) -> Recognized {
        Recognized(
            title: add ? "Add a key to your \(venue) account" : "Remove a key from your \(venue) account",
            symbol: add ? .addKey : .deleteKey,
            sections: [DisplaySection(title: venue, fields: [
                DisplayField(add ? "New key" : "Key", publicKey, style: .monospace),
            ])],
            warnings: add ? ["The key gets full control of your \(venue) balances."] : [])
    }

    // MARK: NEAR Intents (signed messages)

    /// A NEP-413 message carrying NEAR Intents: `{"signer_id", "deadline", "intents": [...]}`.
    static func intentsMessage(_ payload: NEP413Payload, digest: Data) -> Recognized? {
        guard let venue = intentsVenue(payload.recipient), let message = json(Data(payload.message.utf8)),
              let intents = message["intents"] as? [[String: Any]], let signer = message["signer_id"] as? String else { return nil }
        let deadline = message["deadline"] as? String

        var sections: [DisplaySection] = []
        var warnings: [String] = []
        var amounts: [TokenAmount] = []
        var single: (title: String, symbol: DisplaySymbol, highlight: Highlight?)?
        // Fields of the message and of each intent beyond the ones shown below: they are listed
        // with a warning, and the request gets no summary card.
        var unknownFields = Set(message.keys).subtracting(["signer_id", "deadline", "intents"]).sorted()

        for (index, intent) in intents.enumerated() {
            let kind = intent["intent"] as? String ?? "?"
            var fields: [DisplayField] = []
            var title = kind
            var symbol = DisplaySymbol.multiple
            var highlight: Highlight?
            var known: Set<String> = ["intent", "memo"]
            switch kind {
            case "token_diff":
                known.formUnion(["diff", "referral"])
                guard let diff = intent["diff"] as? [String: Any], !diff.isEmpty else { return nil }
                var give: [TokenAmount] = []
                var receive: [TokenAmount] = []
                for (tokenId, value) in diff.sorted(by: { $0.key < $1.key }) {
                    // Every amount must parse, or the whole message is shown raw.
                    guard let parsed = signedAmount(value) else { return nil }
                    let amount = TokenAmount(raw: parsed.1, tokenId: tokenId)
                    if parsed.negative { give.append(amount) } else { receive.append(amount) }
                }
                amounts += give + receive
                fields += give.map { DisplayField("You give", $0.text, style: .amount) }
                fields += receive.map { DisplayField("You receive", $0.text, style: .amount) }
                if let referral = intent["referral"] as? String { fields.append(DisplayField("Referral", referral, style: .monospace)) }
                title = give.count == 1 && receive.count == 1
                    ? "Swap \(give[0].shortText) for \(receive[0].shortText)"
                    : "Swap \(give.count + receive.count) tokens"
                symbol = .swap
                highlight = .swap(Swap(give: give, receive: receive, deadline: deadline))
            case "transfer":
                known.formUnion(["receiver_id", "tokens", "msg", "min_gas"])
                guard let receiver = intent["receiver_id"] as? String,
                      let tokenMap = intent["tokens"] as? [String: Any], !tokenMap.isEmpty else { return nil }
                var tokens: [TokenAmount] = []
                for (tokenId, value) in tokenMap.sorted(by: { $0.key < $1.key }) {
                    guard let raw = amount(value) else { return nil }
                    tokens.append(TokenAmount(raw: raw, tokenId: tokenId))
                }
                amounts += tokens
                fields.append(DisplayField("Recipient", receiver, style: .monospace))
                fields += tokens.map { DisplayField("Amount", $0.text, style: .amount) }
                if let msg = intent["msg"] as? String {
                    fields.append(DisplayField("Message to the recipient", msg, style: .code))
                    warnings.append("\(receiver) is notified and runs its own code with the transfer.")
                }
                if let minGas = intent["min_gas"] { fields.append(DisplayField("Minimum gas", "\(minGas)")) }
                let to = NearFormat.shortAccountId(receiver)
                title = tokens.count == 1 ? "Send \(tokens[0].shortText) to \(to)" : "Send \(tokens.count) tokens to \(to)"
                symbol = .send
                if tokens.count == 1 {
                    highlight = .tokenMove(TokenMove(kind: .send, amount: tokens[0], counterparty: receiver,
                                                     memo: intent["memo"] as? String, venue: venue))
                }
            case "ft_withdraw", "native_withdraw":
                known.formUnion(kind == "native_withdraw" ? ["receiver_id", "amount"]
                    : ["token", "receiver_id", "amount", "msg", "storage_deposit", "min_gas"])
                guard let receiver = intent["receiver_id"] as? String, let raw = amount(intent["amount"]) else { return nil }
                let tokenId: String
                if kind == "native_withdraw" {
                    tokenId = ""
                } else {
                    guard let token = intent["token"] as? String else { return nil }
                    tokenId = token
                }
                let amount = TokenAmount(raw: raw, tokenId: tokenId)
                amounts.append(amount)
                fields.append(DisplayField("Amount", amount.text, style: .amount))
                fields.append(DisplayField("Recipient", receiver, style: .monospace))
                if let deposit = intent["storage_deposit"] {
                    guard let raw = self.amount(deposit) else { return nil }
                    fields.append(DisplayField("Storage deposit", NearFormat.near(raw), style: .amount))
                    warnings.append("Also pays a storage deposit of \(NearFormat.near(raw)) from your wNEAR in \(venue), which is not refunded if the withdrawal fails.")
                }
                if let msg = intent["msg"] as? String {
                    fields.append(DisplayField("Message to the recipient", msg, style: .code))
                    warnings.append("\(receiver) receives the tokens and runs its own code with them.")
                }
                if let minGas = intent["min_gas"] { fields.append(DisplayField("Minimum gas", "\(minGas)")) }
                title = "Withdraw \(amount.shortText) to \(NearFormat.shortAccountId(receiver))"
                highlight = .tokenMove(TokenMove(kind: .withdraw, amount: amount, counterparty: receiver,
                                                 memo: intent["memo"] as? String, venue: venue))
                symbol = .withdraw
            case "add_public_key", "remove_public_key":
                known.insert("public_key")
                let add = kind == "add_public_key"
                guard let key = intent["public_key"] as? String else { return nil }
                fields.append(DisplayField(add ? "New key" : "Key", key, style: .monospace))
                title = add ? "Add a key to your \(venue) account" : "Remove a key from your \(venue) account"
                symbol = add ? .addKey : .deleteKey
                if add { warnings.append("The new key gets full control of your \(venue) balances.") }
            default:
                known = Set(intent.keys)
                fields.append(DisplayField("Details", prettyJSON(intent), style: .code))
                warnings.append("Contains a \"\(kind)\" intent, shown as raw data. Check it before signing.")
            }
            if let memo = intent["memo"] as? String { fields.append(DisplayField("Memo", memo)) }
            let extra = Set(intent.keys).subtracting(known).sorted()
            if !extra.isEmpty {
                unknownFields += extra.map { "\(kind).\($0)" }
                fields.append(DisplayField("Other fields", prettyJSON(intent.filter { extra.contains($0.key) }), style: .code))
            }
            sections.append(DisplaySection(title: intents.count > 1 ? "Intent \(index + 1) of \(intents.count): \(title)" : title,
                                           fields: fields))
            if intents.count == 1 { single = (title, symbol, highlight) }
        }
        if !unknownFields.isEmpty {
            warnings.append("Contains fields NEAR Signer doesn't know (\(unknownFields.joined(separator: ", "))). They are shown as raw data.")
            single?.highlight = nil
        }

        var overviewFields = [
            DisplayField("Signer", signer, style: .monospace),
            DisplayField("Contract", payload.recipient, style: .monospace),
            DisplayField("Valid until", deadline ?? "no deadline"),
        ]
        if let callbackUrl = payload.callbackUrl {
            overviewFields.append(DisplayField("Callback URL", callbackUrl, style: .monospace))
        }
        let overview = DisplaySection(title: venue, fields: overviewFields)
        let details = DisplaySection(title: "Details", fields: [
            DisplayField("Nonce", payload.nonce.base64EncodedString(), style: .monospace),
            DisplayField("Signed digest", Base58.encode(digest), style: .monospace),
            DisplayField("Signed message", payload.message, style: .code),
        ], isTechnical: true)
        // The card spells out what the intents do, so the signature itself needs no warning.
        warnings += unknownTokenWarnings(amounts)
        return Recognized(
            title: single?.title ?? "Sign \(intents.count) intents for \(venue)",
            symbol: single?.symbol ?? .multiple,
            highlight: single?.highlight,
            sections: [overview] + sections + [details],
            warnings: warnings)
    }

    // MARK: Helpers

    /// Parses a JSON object. Nil if the JSON has duplicate keys anywhere: parsers disagree on
    /// which value wins, so the summary could show a different value than the contract reads.
    static func json(_ data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !JSONInspector.hasDuplicateKeys(data) else { return nil }
        return object
    }

    /// Whether `data` is JSON with a repeated key (text that is not JSON has none).
    static func repeatsKey(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
            && JSONInspector.hasDuplicateKeys(data)
    }

    /// Whether `NearFormat.arguments` would show only the start of `data`.
    static func isTruncated(_ data: Data) -> Bool {
        NearFormat.arguments(data).hasSuffix("the hash covers all bytes)")
    }

    static func prettyJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "\(value)" }
        return text.replacingOccurrences(of: "\\/", with: "/")
    }

    /// A u128 amount as NEAR contracts read it: a JSON string parsed like Rust's
    /// `u128::from_str`, which accepts an optional leading "+". Numbers and anything else return
    /// nil, so the caller shows the request raw instead of guessing.
    static func amount(_ value: Any?) -> U128? {
        guard let text = value as? String else { return nil }
        return U128(decimal: text.hasPrefix("+") ? String(text.dropFirst()) : text)
    }

    /// A signed amount (NEAR Intents token deltas), parsed like Rust's `i128::from_str`.
    static func signedAmount(_ value: Any?) -> (negative: Bool, U128)? {
        guard let text = value as? String else { return nil }
        if text.hasPrefix("-") {
            guard let raw = U128(decimal: String(text.dropFirst())) else { return nil }
            return (!raw.isZero, raw)
        }
        guard let raw = amount(text) else { return nil }
        return (false, raw)
    }

    static func uint64(_ value: Any?) -> UInt64? {
        if let text = value as? String { return UInt64(text) }
        if let number = value as? NSNumber, number.int64Value >= 0 { return UInt64(number.int64Value) }
        return nil
    }

    static func tokenLabel(_ amount: TokenAmount) -> String {
        guard let token = amount.token, amount.issuer == nil else { return amount.tokenId }
        return token.contract.isEmpty ? "NEAR" : "\(token.name), \(token.contract)"
    }

    /// Tokens whose name can't be taken at face value: ones missing from the token list, and
    /// internal NEAR Intents tokens from an issuer that isn't trusted.
    static func unknownTokenWarnings(_ amounts: [TokenAmount]) -> [String] {
        var seen = Set<String>()
        return amounts.filter { seen.insert($0.tokenId).inserted }.compactMap { amount in
            if !amount.isKnown {
                return "\(amount.symbol) is not in NEAR Signer's token list: its amount is shown in the smallest units. Check the contract name."
            }
            if amount.hasUntrustedIssuer, let issuer = amount.issuer {
                return "This \(amount.symbol) is issued by \(issuer) inside NEAR Intents. Anyone can issue a token under any name: check that this is the issuer you expect."
            }
            return nil
        }
    }
}
