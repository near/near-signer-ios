import Foundation

/// Human-readable rendering of a request. Built once by the core and shown verbatim by the UI,
/// so the iOS app, the simulator and the tests all display exactly the same information.
public struct RequestDisplay: Equatable, Sendable {
    public var title: String
    /// Category of the request, used by the UI to pick an icon.
    public var symbol: DisplaySymbol
    /// "mainnet" or "testnet" when the account names tell; nil otherwise.
    public var network: String?
    public var warnings: [String]
    public var sections: [DisplaySection]
    /// Summary of a recognized operation (token transfer, swap, DAO action) for a dedicated card.
    public var highlight: Highlight?
    /// What a recognized request does besides what its card shows, such as a storage deposit paid
    /// first. Shown next to the card; the sections list them too.
    public var extras: [DisplayField]

    public init(title: String, symbol: DisplaySymbol = .multiple, network: String? = nil,
                warnings: [String] = [], sections: [DisplaySection] = [], highlight: Highlight? = nil,
                extras: [DisplayField] = []) {
        self.title = title
        self.symbol = symbol
        self.network = network
        self.warnings = warnings
        self.sections = sections
        self.highlight = highlight
        self.extras = extras
    }

    /// Sections a person needs to decide: accounts, amounts, actions.
    public var primarySections: [DisplaySection] { sections.filter { !$0.isTechnical } }

    /// Hashes, nonces and paths: shown on demand.
    public var technicalSections: [DisplaySection] { sections.filter(\.isTechnical) }

    /// The same display with every string passed through `NearFormat.visible`.
    public func sanitized() -> RequestDisplay {
        RequestDisplay(
            title: NearFormat.visible(title),
            symbol: symbol,
            network: network.map { NearFormat.visible($0) },
            warnings: warnings.map { NearFormat.visible($0) },
            sections: sections.map { $0.sanitized() },
            highlight: highlight?.sanitized(),
            extras: extras.map { DisplayField(NearFormat.visible($0.label), NearFormat.visible($0.value), style: $0.style) })
    }

    /// Plain-text rendering, used by the terminal simulator.
    public var text: String {
        var lines = [title]
        for warning in warnings { lines.append("  ! \(warning)") }
        for section in sections {
            lines.append("")
            lines.append("[\(section.title)]")
            for field in section.fields {
                if field.value.contains("\n") {
                    lines.append("  \(field.label):")
                    lines.append(contentsOf: field.value.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { "    \($0)" })
                } else {
                    lines.append("  \(field.label): \(field.value)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

public struct DisplaySection: Equatable, Sendable {
    public var title: String
    public var fields: [DisplayField]
    public var isTechnical: Bool

    public init(title: String, fields: [DisplayField], isTechnical: Bool = false) {
        self.title = title
        self.fields = fields
        self.isTechnical = isTechnical
    }

    /// The same section with every string passed through `NearFormat.visible`.
    func sanitized() -> DisplaySection {
        DisplaySection(title: NearFormat.visible(title), fields: fields.map { field in
            DisplayField(NearFormat.visible(field.label),
                         NearFormat.visible(field.value, allowNewlines: field.style == .code),
                         style: field.style)
        }, isTechnical: isTechnical)
    }
}

/// What a request does, in one word. The UI maps it to an icon.
public enum DisplaySymbol: String, Codable, Sendable, CaseIterable {
    case send
    case call
    case createAccount
    case deploy
    case stake
    case addKey
    case deleteKey
    case deleteAccount
    case relay
    case initialize
    case gasKey
    case message
    case publicKey
    case multiple
    case swap
    case deposit
    case withdraw
    case dao
    case vote
}

public struct DisplayField: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case text
        /// Keys, hashes, account ids: show in a monospaced font, never truncate.
        case monospace
        /// NEAR amounts: show prominently.
        case amount
        /// Multi-line content such as function call arguments.
        case code
        case warning
    }

    public var label: String
    public var value: String
    public var style: Style

    public init(_ label: String, _ value: String, style: Style = .text) {
        self.label = label
        self.value = value
        self.style = style
    }
}

public enum NearFormat {
    /// Makes invisible and layout-changing characters visible as `\u{…}`: controls, format
    /// characters (bidi overrides, zero-width), default-ignorable characters (fillers, variation
    /// selectors), the blank Braille pattern, spaces other than U+0020 and the narrow no-break
    /// space used for digit grouping, and line and paragraph separators. A host could otherwise
    /// hide or reorder text on the approval screen. `allowNewlines` keeps `\n` and `\t` (for
    /// multi-line values such as function-call arguments).
    public static func visible(_ text: String, allowNewlines: Bool = false) -> String {
        var result = ""
        result.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if isHidden(scalar, allowNewlines: allowNewlines) {
                result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func isHidden(_ scalar: Unicode.Scalar, allowNewlines: Bool) -> Bool {
        switch scalar.properties.generalCategory {
        case .control:
            return !(allowNewlines && (scalar == "\n" || scalar == "\t"))
        case .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned:
            return true
        case .spaceSeparator:
            return scalar != " " && scalar != "\u{202F}"
        default:
            return scalar.properties.isDefaultIgnorableCodePoint || scalar == "\u{2800}"
        }
    }

    /// Formats yoctoNEAR without rounding: every significant digit is kept. A single yoctoNEAR,
    /// the confirmation many contracts require, reads "1 yoctoNEAR" rather than 24 decimals.
    public static func near(_ yocto: U128) -> String {
        if yocto == U128(1) { return "1 yoctoNEAR" }
        let digits = yocto.description
        let decimals = 24
        let padded = String(repeating: "0", count: max(0, decimals + 1 - digits.count)) + digits
        let integer = padded.dropLast(decimals)
        var fraction = String(padded.suffix(decimals))
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return (fraction.isEmpty ? String(integer) : "\(integer).\(fraction)") + " NEAR"
    }

    /// Formats gas as Tgas without rounding.
    public static func gas(_ gas: UInt64) -> String {
        let tera: UInt64 = 1_000_000_000_000
        let integer = gas / tera
        var fraction = String(gas % tera)
        fraction = String(repeating: "0", count: 12 - fraction.count) + fraction
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return (fraction.isEmpty ? "\(integer)" : "\(integer).\(fraction)") + " Tgas"
    }

    /// Network guessed from the account suffix. Transactions do not carry a chain id;
    /// the block hash binds them to one chain.
    public static func inferredNetwork(_ accountId: String) -> String? {
        if accountId.hasSuffix(".near") || accountId == "near" { return "mainnet" }
        if accountId.hasSuffix(".testnet") || accountId == "testnet" { return "testnet" }
        return nil
    }

    /// NEAR account id rules: 2–64 characters; lowercase letters and digits, with `-` or `_`
    /// between them, in parts separated by dots.
    public static func isValidAccountId(_ accountId: String) -> Bool {
        guard (2...64).contains(accountId.count) else { return false }
        var previousWasSeparator = true
        for character in accountId {
            if character.isASCII && (character.isLowercase || character.isNumber) {
                previousWasSeparator = false
            } else if character == "-" || character == "_" || character == "." {
                if previousWasSeparator { return false }
                previousWasSeparator = true
            } else {
                return false
            }
        }
        return !previousWasSeparator
    }

    /// True for named accounts (alice.near), false for implicit ones (64 hex characters, 0x…).
    public static func isNamedAccount(_ accountId: String) -> Bool {
        accountKind(accountId) == nil
    }

    public static func accountKind(_ accountId: String) -> String? {
        if accountId.count == 64, accountId.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
            return "implicit account"
        }
        if accountId.count == 42, accountId.hasPrefix("0x") { return "ETH-implicit account" }
        if accountId.count == 42, accountId.hasPrefix("0s") { return "deterministic account" }
        return nil
    }

    /// For titles: implicit ids shortened to "5bb0a9…8123ca", named accounts as they are. The
    /// cards and fields show the full id.
    public static func shortAccountId(_ accountId: String) -> String {
        accountKind(accountId) == nil ? accountId : "\(accountId.prefix(6))…\(accountId.suffix(6))"
    }

    /// A function call's attached deposit. Real amounts show large; the 1 yoctoNEAR contracts ask
    /// as a confirmation doesn't.
    static func depositField(_ deposit: U128) -> DisplayField {
        DisplayField("Deposit", near(deposit), style: deposit > U128(1) ? .amount : .text)
    }

    /// Pretty JSON if the bytes are UTF-8 JSON, otherwise base64.
    public static func arguments(_ data: Data, limit: Int = 16_000) -> String {
        if data.isEmpty { return "(none)" }
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           var text = String(data: pretty, encoding: .utf8) {
            text = text.replacingOccurrences(of: "\\/", with: "/")
            return truncated(text, limit: limit, totalBytes: data.count)
        }
        if let text = String(data: data, encoding: .utf8), text.allSatisfy({ !$0.isNewline || $0 == "\n" }),
           text.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0 == "\n" || $0 == "\t" }) {
            return truncated("text: " + text, limit: limit, totalBytes: data.count)
        }
        return truncated("base64: " + data.base64EncodedString(), limit: limit, totalBytes: data.count)
    }

    private static func truncated(_ text: String, limit: Int, totalBytes: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n… (truncated, \(totalBytes) bytes total; the hash covers all bytes)"
    }

    /// "1.2 MB (1,234,567 bytes)".
    public static func byteSize(_ count: Int) -> String {
        let exact = "\(tokenAmount(U128(UInt64(count)), decimals: 0)) bytes"
        guard count >= 1024 else { return exact }
        let units = ["KB", "MB", "GB"]
        var value = Double(count) / 1024
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: "%.1f %@ (%@)", value, units[unit], exact)
    }

    /// Readable fields for contract code: size, the code hash explorers show (base58 sha256),
    /// and whether it is a WebAssembly module. The bytes themselves are never displayed.
    static func codeFields(_ code: Data) -> (fields: [DisplayField], warnings: [String]) {
        let isWasm = code.starts(with: [0x00, 0x61, 0x73, 0x6D])
        var fields = [
            DisplayField("Code size", byteSize(code.count)),
            DisplayField("Code hash", Base58.encode(Data(SHA256.hash(data: code))), style: .monospace),
            DisplayField("Format", isWasm ? "WebAssembly module" : "Not WebAssembly"),
        ]
        if isWasm, code.count >= 8 {
            let version = code[code.startIndex + 4..<code.startIndex + 8].enumerated()
                .reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
            fields[2] = DisplayField("Format", "WebAssembly module, version \(version)")
        }
        let warnings = isWasm ? [] : ["The code is not a WebAssembly module, so it cannot run as a contract."]
        return (fields, warnings)
    }

    static func codeSummary(_ code: Data) -> String {
        "\(code.count) bytes, sha256 " + Base58.encode(Data(SHA256.hash(data: code)))
    }
}

// MARK: - Transaction rendering

public enum RequestRenderer {
    public static func render(transaction tx: Transaction, hash: Data) -> RequestDisplay {
        var warnings: [String] = []
        var overview: [DisplayField] = [
            DisplayField("From (signer)", tx.signerId, style: .monospace),
            DisplayField("To (receiver)", tx.receiverId, style: .monospace),
        ]
        if let kind = NearFormat.accountKind(tx.receiverId) {
            overview.append(DisplayField("Receiver type", kind))
        }
        let network = NearFormat.inferredNetwork(tx.signerId) ?? NearFormat.inferredNetwork(tx.receiverId)
        if let network {
            overview.append(DisplayField("Network (from account names)", network))
        }
        let total = totalDeposit(tx.actions)
        if !total.isZero {
            overview.append(DisplayField("Total attached NEAR", NearFormat.near(total), style: total > U128(1) ? .amount : .text))
        }

        var sections = [DisplaySection(title: "Transaction", fields: overview)]
        var depositWarnings: [String] = []
        for (index, action) in tx.actions.enumerated() {
            let rendered = render(action: action, signerId: tx.signerId, receiverId: tx.receiverId,
                                  signingKey: tx.publicKey)
            warnings.append(contentsOf: rendered.warnings)
            depositWarnings.append(contentsOf: rendered.depositWarning.map { [$0] } ?? [])
            sections.append(DisplaySection(
                title: tx.actions.count > 1 ? "Action \(index + 1) of \(tx.actions.count): \(rendered.name)" : rendered.name,
                fields: rendered.fields))
            sections.append(contentsOf: rendered.nested)
        }

        var details: [DisplayField] = [
            DisplayField("Transaction hash", Base58.encode(hash), style: .monospace),
            DisplayField("Signer public key", tx.publicKey.description, style: .monospace),
            DisplayField("Nonce", tx.nonce.description),
            DisplayField("Block hash", Base58.encode(tx.blockHash), style: .monospace),
        ]
        if case let .v1(mode) = tx.version {
            details.append(DisplayField("Format", "TransactionV1, nonce mode \(mode == .strict ? "strict" : "monotonic")"))
        }
        sections.append(DisplaySection(title: "Details", fields: details, isTechnical: true))

        if let recognized = Recognizers.recognize(actions: tx.actions, signerId: tx.signerId, receiverId: tx.receiverId) {
            // The summary's warnings come first, then every generic one except "attaches NEAR"
            // (the card shows the attached total itself).
            return RequestDisplay(title: recognized.title, symbol: recognized.symbol, network: network,
                                  warnings: unique(recognized.warnings + warnings),
                                  sections: recognizedSections(recognized, from: tx.signerId, network: network,
                                                               total: totalDeposit(tx.actions), generic: sections),
                                  highlight: recognized.highlight, extras: recognized.extras)
        }
        return RequestDisplay(title: title(for: tx.actions, signerId: tx.signerId, receiverId: tx.receiverId),
                              symbol: symbol(for: tx.actions), network: network,
                              warnings: unique(depositWarnings + warnings), sections: sections)
    }

    public static func render(delegateAction action: DelegateAction, digest: Data) -> RequestDisplay {
        // That a relayer submits it is how meta-transactions work, not a risk: the expiry block is
        // in the details.
        var warnings: [String] = []
        if NearFormat.inferredNetwork(action.senderId) == nil && NearFormat.inferredNetwork(action.receiverId) == nil {
            warnings.append("The network can't be told from the account names, and meta-transactions are not tied to one: it is valid on any network where this account and key exist.")
        }
        var overview: [DisplayField] = [
            DisplayField("Sender", action.senderId, style: .monospace),
            DisplayField("Receiver", action.receiverId, style: .monospace),
        ]
        let network = NearFormat.inferredNetwork(action.senderId) ?? NearFormat.inferredNetwork(action.receiverId)
        if let network {
            overview.append(DisplayField("Network (from account names)", network))
        }
        let total = totalDeposit(action.actions)
        if !total.isZero {
            overview.append(DisplayField("Total attached NEAR", NearFormat.near(total), style: total > U128(1) ? .amount : .text))
        }
        var sections = [DisplaySection(title: "Delegate action", fields: overview)]
        var depositWarnings: [String] = []
        for (index, inner) in action.actions.enumerated() {
            let rendered = render(action: inner, signerId: action.senderId, receiverId: action.receiverId,
                                  signingKey: action.publicKey)
            warnings.append(contentsOf: rendered.warnings)
            depositWarnings.append(contentsOf: rendered.depositWarning.map { [$0] } ?? [])
            sections.append(DisplaySection(
                title: action.actions.count > 1 ? "Action \(index + 1) of \(action.actions.count): \(rendered.name)" : rendered.name,
                fields: rendered.fields))
        }
        sections.append(DisplaySection(title: "Details", fields: [
            DisplayField("Signed digest", Base58.encode(digest), style: .monospace),
            DisplayField("Signer public key", action.publicKey.description, style: .monospace),
            DisplayField("Nonce", String(action.nonce)),
            DisplayField("Valid until block", String(action.maxBlockHeight)),
        ], isTechnical: true))
        if let recognized = Recognizers.recognize(actions: action.actions, signerId: action.senderId, receiverId: action.receiverId) {
            return RequestDisplay(title: "Meta-tx: " + recognized.title, symbol: recognized.symbol, network: network,
                                  warnings: unique(recognized.warnings + warnings),
                                  sections: recognizedSections(recognized, from: action.senderId, network: network,
                                                               total: totalDeposit(action.actions), generic: sections),
                                  highlight: recognized.highlight, extras: recognized.extras)
        }
        return RequestDisplay(
            title: "Meta-tx: " + title(for: action.actions, signerId: action.senderId, receiverId: action.receiverId),
            symbol: symbol(for: action.actions), network: network,
            warnings: unique(depositWarnings + warnings), sections: sections)
    }

    public static func render(message payload: NEP413Payload, digest: Data) -> RequestDisplay {
        if let recognized = Recognizers.intentsMessage(payload, digest: digest) {
            return RequestDisplay(title: recognized.title, symbol: recognized.symbol, warnings: unique(recognized.warnings),
                                  sections: recognized.sections, highlight: recognized.highlight)
        }
        var fields = [
            DisplayField("Recipient (app)", payload.recipient, style: .monospace),
            DisplayField("Message", payload.message, style: .code),
        ]
        if let callbackUrl = payload.callbackUrl {
            fields.append(DisplayField("Callback URL", callbackUrl, style: .monospace))
        }
        let details = [
            DisplayField("Nonce", payload.nonce.base64EncodedString(), style: .monospace),
            DisplayField("Signed digest", Base58.encode(digest), style: .monospace),
        ]
        return RequestDisplay(
            title: "Sign message for \(payload.recipient)",
            symbol: .message,
            warnings: ["A signed message can approve actions in some apps, such as trades. Sign only for websites you trust."],
            sections: [DisplaySection(title: "Message", fields: fields),
                       DisplaySection(title: "Details", fields: details, isTechnical: true)])
    }

    public static func render(publicKeyRequest path: BIP32Path, publicKey: String?) -> RequestDisplay {
        var fields = [DisplayField("Derivation path", path.description, style: .monospace)]
        if let publicKey { fields.append(DisplayField("Public key", publicKey, style: .monospace)) }
        return RequestDisplay(title: "Share public key", symbol: .publicKey,
                              sections: [DisplaySection(title: "Public key request", fields: fields, isTechnical: true)])
    }

    /// A recognized request shows its own sections; the signer overview (also shown by the app's
    /// account card) and the generic per-action rendering move to the technical details, so
    /// nothing is hidden.
    static func recognizedSections(_ recognized: Recognized, from signer: String, network: String?, total: U128,
                                   generic: [DisplaySection]) -> [DisplaySection] {
        var overview = [DisplayField("From", signer, style: .monospace)]
        if let network { overview.append(DisplayField("Network (from account names)", network)) }
        var sections = recognized.sections
        // Everything the request attaches stays in plain sight, whatever the summary says.
        if total > U128(1), !recognized.showsTotal, !sections.isEmpty {
            sections[0].fields.append(DisplayField("Total attached NEAR", NearFormat.near(total), style: .amount))
        }
        var result = sections + [DisplaySection(title: "Account", fields: overview, isTechnical: true)]
        for var section in generic.dropFirst() where !(recognized.coversActions && !section.isTechnical) {
            section.isTechnical = true
            result.append(section)
        }
        return result
    }

    // MARK: Actions

    struct RenderedAction {
        var name: String
        var fields: [DisplayField]
        var warnings: [String] = []
        var nested: [DisplaySection] = []
        /// "Attaches N NEAR to method": shown by the generic rendering only, since a recognized
        /// summary shows the attached total itself.
        var depositWarning: String?
    }

    static func render(action: Action, signerId: String, receiverId: String, signingKey: PublicKey) -> RenderedAction {
        switch action {
        case .createAccount:
            return RenderedAction(name: "Create account", fields: [DisplayField("New account", receiverId, style: .monospace)])

        case let .deployContract(code):
            let summary = NearFormat.codeFields(code)
            return RenderedAction(
                name: "Deploy contract",
                fields: [DisplayField("Account", receiverId, style: .monospace)] + summary.fields,
                warnings: ["Replaces the contract code of \(receiverId). Compare the code hash with the one you expect."]
                    + summary.warnings)

        case let .functionCall(call):
            var fields = [
                DisplayField("Contract", receiverId, style: .monospace),
                DisplayField("Method", call.methodName, style: .monospace),
                NearFormat.depositField(call.deposit),
                DisplayField("Gas", NearFormat.gas(call.gas)),
                DisplayField("Arguments", NearFormat.arguments(call.args), style: .code),
            ]
            var warnings: [String] = []
            // The 1 yoctoNEAR confirmation is no payment worth a warning.
            let depositWarning = call.deposit > U128(1)
                ? "Attaches \(NearFormat.near(call.deposit)) to \(call.methodName) on \(receiverId)." : nil
            if let hint = tokenHint(call) { fields.insert(hint, at: 2) }
            if JSONInspector.hasDuplicateKeys(call.args),
               (try? JSONSerialization.jsonObject(with: call.args)) != nil {
                warnings.append("The arguments repeat a key. Contracts may read a different value than shown.")
            }
            if Recognizers.isTruncated(call.args) {
                // Only the start is shown: name every top-level field so none is hidden entirely.
                var message = "The arguments are \(NearFormat.byteSize(call.args.count)) long and only the start is shown."
                if let object = try? JSONSerialization.jsonObject(with: call.args) as? [String: Any] {
                    message += " Top-level fields: \(object.keys.sorted().joined(separator: ", "))."
                }
                warnings.append(message)
            }
            return RenderedAction(name: "Function call", fields: fields, warnings: warnings, depositWarning: depositWarning)

        case let .transfer(deposit):
            return RenderedAction(name: "Transfer", fields: [
                DisplayField("Amount", NearFormat.near(deposit), style: .amount),
                DisplayField("Recipient", receiverId, style: .monospace),
            ])

        case let .stake(stake, publicKey):
            return RenderedAction(
                name: "Stake",
                fields: [DisplayField("Amount", NearFormat.near(stake), style: .amount),
                         DisplayField("Validator key", publicKey.description, style: .monospace)],
                warnings: ["Stakes \(NearFormat.near(stake)) directly from \(signerId) as a validator."])

        case let .addKey(publicKey, accessKey):
            var fields = [
                DisplayField("Account", receiverId, style: .monospace),
                DisplayField("New key", publicKey.description, style: .monospace),
            ]
            var warnings: [String] = []
            switch accessKey.permission {
            case .fullAccess:
                fields.append(DisplayField("Permission", "FULL ACCESS", style: .warning))
                warnings.append("Adds a FULL ACCESS key: its holder gets complete control of \(receiverId).")
            case let .functionCall(permission):
                fields.append(contentsOf: functionCallPermissionFields(permission))
            case let .gasKeyFullAccess(info):
                fields.append(DisplayField("Permission", "FULL ACCESS gas key", style: .warning))
                fields.append(contentsOf: gasKeyFields(info))
                warnings.append("Adds a FULL ACCESS gas key: its holder gets complete control of \(receiverId).")
            case let .gasKeyFunctionCall(info, permission):
                fields.append(DisplayField("Key type", "Gas key"))
                fields.append(contentsOf: gasKeyFields(info))
                fields.append(contentsOf: functionCallPermissionFields(permission))
            }
            fields.append(DisplayField("Key nonce", String(accessKey.nonce)))
            return RenderedAction(name: "Add key", fields: fields, warnings: warnings)

        case let .deleteKey(publicKey):
            var warnings: [String] = []
            if publicKey == signingKey {
                warnings.append("Deletes the key that signs this transaction.")
            }
            return RenderedAction(name: "Delete key", fields: [
                DisplayField("Account", receiverId, style: .monospace),
                DisplayField("Key", publicKey.description, style: .monospace),
            ], warnings: warnings)

        case let .deleteAccount(beneficiaryId):
            return RenderedAction(
                name: "Delete account",
                fields: [DisplayField("Account", receiverId, style: .monospace),
                         DisplayField("Beneficiary", beneficiaryId, style: .monospace)],
                warnings: ["Deletes account \(receiverId). Its remaining balance goes to \(beneficiaryId)."])

        case let .delegate(signed):
            let inner = signed.delegateAction
            var nested: [DisplaySection] = []
            var warnings = ["Submits a meta-transaction signed by \(inner.senderId) (you pay its gas)."]
            for (index, action) in inner.actions.enumerated() {
                let rendered = render(action: action, signerId: inner.senderId, receiverId: inner.receiverId,
                                      signingKey: inner.publicKey)
                warnings.append(contentsOf: (rendered.depositWarning.map { [$0] } ?? []) + rendered.warnings)
                nested.append(DisplaySection(title: "  Inner action \(index + 1): \(rendered.name)", fields: rendered.fields))
            }
            return RenderedAction(name: "Relay meta-transaction", fields: [
                DisplayField("Sender", inner.senderId, style: .monospace),
                DisplayField("Receiver", inner.receiverId, style: .monospace),
                DisplayField("Sender key", inner.publicKey.description, style: .monospace),
                DisplayField("Valid until block", String(inner.maxBlockHeight)),
            ], warnings: warnings, nested: nested)

        case let .deployGlobalContract(code, mode):
            let summary = NearFormat.codeFields(code)
            return RenderedAction(
                name: "Deploy global contract",
                fields: summary.fields
                    + [DisplayField("Referenced by", mode == .codeHash ? "code hash (immutable)" : "account id (\(receiverId), upgradable)")],
                warnings: ["Publishes global contract code; storage is paid by burning NEAR from \(signerId)."] + summary.warnings)

        case let .useGlobalContract(identifier):
            return RenderedAction(
                name: "Use global contract",
                fields: [DisplayField("Account", receiverId, style: .monospace),
                         DisplayField("Contract", identifier.description, style: .monospace)],
                warnings: ["Replaces the contract code of \(receiverId) with a global contract."])

        case let .deterministicStateInit(stateInit, deposit):
            return RenderedAction(name: "Deterministic state init", fields: [
                DisplayField("Account", receiverId, style: .monospace),
                DisplayField("Contract", stateInit.code.description, style: .monospace),
                DisplayField("Initial storage entries", String(stateInit.data.count)),
                DisplayField("Deposit", NearFormat.near(deposit), style: .amount),
            ])

        case let .transferToGasKey(publicKey, deposit):
            return RenderedAction(name: "Fund gas key", fields: [
                DisplayField("Gas key", publicKey.description, style: .monospace),
                DisplayField("Amount", NearFormat.near(deposit), style: .amount),
            ])

        case let .withdrawFromGasKey(publicKey, amount):
            return RenderedAction(name: "Withdraw from gas key", fields: [
                DisplayField("Gas key", publicKey.description, style: .monospace),
                DisplayField("Amount", NearFormat.near(amount), style: .amount),
            ])

        case let .delegateV2(signed):
            let inner = signed.delegateAction
            var nested: [DisplaySection] = []
            var warnings = ["Submits a v2 meta-transaction signed by \(inner.senderId) (you pay its gas)."]
            for (index, action) in inner.actions.enumerated() {
                let rendered = render(action: action, signerId: inner.senderId, receiverId: inner.receiverId,
                                      signingKey: inner.publicKey)
                warnings.append(contentsOf: (rendered.depositWarning.map { [$0] } ?? []) + rendered.warnings)
                nested.append(DisplaySection(title: "  Inner action \(index + 1): \(rendered.name)", fields: rendered.fields))
            }
            return RenderedAction(name: "Relay meta-transaction (v2)", fields: [
                DisplayField("Sender", inner.senderId, style: .monospace),
                DisplayField("Receiver", inner.receiverId, style: .monospace),
                DisplayField("Sender key", inner.publicKey.description, style: .monospace),
                DisplayField("Nonce", inner.nonce.description),
                DisplayField("Valid until block", String(inner.maxBlockHeight)),
            ], warnings: warnings, nested: nested)

        case let .universalStateInit(raw, deposit):
            return RenderedAction(
                name: "Universal state init",
                fields: [DisplayField("Account", receiverId, style: .monospace),
                         DisplayField("State init", NearFormat.codeSummary(raw), style: .monospace),
                         DisplayField("Deposit", NearFormat.near(deposit), style: .amount)],
                warnings: ["Universal state init content is shown as a hash only."])
        }
    }

    static func title(for actions: [Action], signerId: String, receiverId: String) -> String {
        guard actions.count == 1, let action = actions.first else {
            return actions.isEmpty ? "Empty transaction to \(receiverId)" : "\(actions.count) actions on \(receiverId)"
        }
        switch action {
        case let .transfer(deposit): return "Send \(NearFormat.near(deposit)) to \(receiverId)"
        case let .functionCall(call): return "Call \(call.methodName) on \(receiverId)"
        case .createAccount: return "Create account \(receiverId)"
        case .deployContract: return "Deploy contract to \(receiverId)"
        case let .stake(stake, _): return "Stake \(NearFormat.near(stake))"
        case let .addKey(_, accessKey):
            return accessKey.permission.isFullAccess ? "Add FULL ACCESS key to \(receiverId)" : "Add limited key to \(receiverId)"
        case .deleteKey: return "Delete key from \(receiverId)"
        case let .deleteAccount(beneficiaryId): return "Delete account \(receiverId) → \(beneficiaryId)"
        case let .delegate(signed): return "Relay meta-tx from \(signed.delegateAction.senderId)"
        case .deployGlobalContract: return "Deploy global contract"
        case .useGlobalContract: return "Use global contract on \(receiverId)"
        case .deterministicStateInit: return "Initialize \(receiverId)"
        case let .transferToGasKey(_, deposit): return "Fund gas key with \(NearFormat.near(deposit))"
        case let .withdrawFromGasKey(_, amount): return "Withdraw \(NearFormat.near(amount)) from gas key"
        case let .delegateV2(signed): return "Relay meta-tx from \(signed.delegateAction.senderId)"
        case .universalStateInit: return "Initialize \(receiverId)"
        }
    }

    static func symbol(for actions: [Action]) -> DisplaySymbol {
        guard actions.count == 1, let action = actions.first else {
            // The most consequential action names a batch.
            if actions.contains(where: { if case .deleteAccount = $0 { return true } else { return false } }) {
                return .deleteAccount
            }
            if actions.contains(where: { if case .createAccount = $0 { return true } else { return false } }) {
                return .createAccount
            }
            return .multiple
        }
        switch action {
        case .transfer: return .send
        case .functionCall: return .call
        case .createAccount: return .createAccount
        case .deployContract, .deployGlobalContract, .useGlobalContract: return .deploy
        case .stake: return .stake
        case .addKey: return .addKey
        case .deleteKey: return .deleteKey
        case .deleteAccount: return .deleteAccount
        case .delegate, .delegateV2: return .relay
        case .deterministicStateInit, .universalStateInit: return .initialize
        case .transferToGasKey, .withdrawFromGasKey: return .gasKey
        }
    }

    static func totalDeposit(_ actions: [Action]) -> U128 {
        var total = U128.zero
        for action in actions {
            let amount: U128
            switch action {
            case let .transfer(deposit): amount = deposit
            case let .functionCall(call): amount = call.deposit
            case let .deterministicStateInit(_, deposit): amount = deposit
            case let .transferToGasKey(_, deposit): amount = deposit
            case let .universalStateInit(_, deposit): amount = deposit
            default: continue
            }
            // Saturate instead of overflowing; the per-action amounts stay exact.
            total = total.adding(amount) ?? U128(high: .max, low: .max)
        }
        return total
    }

    static func functionCallPermissionFields(_ permission: FunctionCallPermission) -> [DisplayField] {
        [
            DisplayField("Permission", "Function calls only"),
            DisplayField("Allowed contract", permission.receiverId, style: .monospace),
            DisplayField("Allowed methods", permission.methodNames.isEmpty ? "any method" : permission.methodNames.joined(separator: ", ")),
            DisplayField("Gas allowance", permission.allowance.map(NearFormat.near) ?? "unlimited"),
        ]
    }

    static func gasKeyFields(_ info: GasKeyInfo) -> [DisplayField] {
        [DisplayField("Gas key balance", NearFormat.near(info.balance), style: .amount),
         DisplayField("Gas key nonces", String(info.numNonces))]
    }

    /// Highlights fungible / non-fungible token standard calls. Amounts stay in raw token units,
    /// because token decimals cannot be verified offline.
    static func tokenHint(_ call: FunctionCallAction) -> DisplayField? {
        guard let object = try? JSONSerialization.jsonObject(with: call.args) as? [String: Any] else { return nil }
        switch call.methodName {
        case "ft_transfer", "ft_transfer_call":
            guard let receiver = object["receiver_id"] as? String, let amount = object["amount"] as? String else { return nil }
            return DisplayField("Token transfer", "\(amount) raw token units → \(receiver)", style: .amount)
        case "nft_transfer", "nft_transfer_call":
            guard let receiver = object["receiver_id"] as? String, let token = object["token_id"] as? String else { return nil }
            return DisplayField("NFT transfer", "token \(token) → \(receiver)", style: .amount)
        default:
            return nil
        }
    }

    private static func unique(_ warnings: [String]) -> [String] {
        var seen = Set<String>()
        return warnings.filter { seen.insert($0).inserted }
    }
}

extension U128 {
    func adding(_ other: U128) -> U128? {
        let (low, carry) = self.low.addingReportingOverflow(other.low)
        let (high1, overflow1) = self.high.addingReportingOverflow(other.high)
        let (high2, overflow2) = high1.addingReportingOverflow(carry ? 1 : 0)
        return overflow1 || overflow2 ? nil : U128(high: high2, low: low)
    }
}
