import Foundation

/// A named derivation path. Accounts hold public data only; the secret stays in the key vault.
public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var path: BIP32Path
    /// Raw 32-byte ed25519 public key.
    public var publicKey: Data
    public var createdAt: Date
    /// Named NEAR account (such as alice.near) this key controls. Entered by the user or learned
    /// from approved transactions; the phone is offline, so it is not checked on chain.
    public var accountId: String?

    public init(id: UUID = UUID(), name: String, path: BIP32Path, publicKey: Data, createdAt: Date = Date(),
                accountId: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.publicKey = publicKey
        self.createdAt = createdAt
        self.accountId = accountId
    }

    /// `ed25519:<base58>`, the form NEAR tools use for access keys.
    public var publicKeyString: String { PublicKey.ed25519(publicKey).description }

    /// The implicit account id (hex of the public key). Sending NEAR to it creates the account.
    public var implicitAccountId: String { publicKey.hexString }

    /// The named account if there is one, else the implicit account id.
    public var address: String { accountId ?? implicitAccountId }

    /// The named account, or `a1b2c3…d4e5f6`, for lists.
    public var shortDisplayAddress: String { accountId ?? shortAddress }

    /// `a1b2c3…d4e5f6`, for lists.
    public var shortAddress: String {
        let id = implicitAccountId
        guard id.count > 14 else { return id }
        return "\(id.prefix(6))…\(id.suffix(6))"
    }

    /// N in m/44'/397'/0'/0'/N', the path family NEAR wallets use for Ledger accounts.
    public var index: UInt32? { AccountBook.standardIndex(of: path) }

    /// Named accounts (such as alice.near) this key has signed for, newest first. The phone is
    /// offline, so this is learned from the signing history rather than looked up on chain.
    public func linkedAccountIds(in history: [HistoryRecord]) -> [String] {
        let key = publicKeyString
        let implicit = implicitAccountId
        var seen = Set<String>()
        var result: [String] = []
        for record in history where record.outcome == .approved && record.publicKey == key {
            guard let signer = record.signerId, signer != implicit, seen.insert(signer).inserted else { continue }
            result.append(signer)
        }
        return result
    }

    /// Names this key may control, from requests the user approved: named accounts that signed
    /// with it, and accounts created with it. Only suggestions: a host can send a request that
    /// fails on chain, so the user confirms a name before the app uses it.
    public func suggestedAccountIds(in history: [HistoryRecord]) -> [String] {
        let key = publicKeyString
        var seen = Set([accountId].compactMap { $0 })
        var result: [String] = []
        // Recent requests only, and no large payloads (contract code): this runs while drawing.
        for record in history.prefix(300) where record.outcome == .approved {
            var names: [String] = []
            if record.publicKey == key, let signer = record.signerId { names.append(signer) }
            if record.kind == .transaction, record.payload.count < 64 * 1024, let prepared = PreparedRequest(record: record) {
                names += prepared.createdAccounts.filter { $0.publicKey.description == key }.map(\.accountId)
            }
            for name in names where NearFormat.isNamedAccount(name) && seen.insert(name).inserted {
                result.append(name)
            }
        }
        return result
    }
}

public enum AccountError: Error, Equatable, CustomStringConvertible {
    case invalidPath(String)
    case duplicatePath(String)
    case emptyName
    case invalidAccountId(String)

    public var description: String {
        switch self {
        case let .invalidPath(path):
            return "\(path) is not a valid account path. Use 5 hardened levels starting with 44'/397', such as m/44'/397'/0'/0'/1'."
        case let .duplicatePath(path): return "An account with path \(path) already exists."
        case .emptyName: return "Enter a name."
        case let .invalidAccountId(accountId):
            return "\"\(accountId)\" is not a valid NEAR account name. Use lowercase letters, digits, - and _, separated by dots, such as alice.near."
        }
    }
}

/// The user's list of accounts, ordered by account number. Custom paths come last.
public struct AccountBook: Codable, Equatable, Sendable {
    public private(set) var accounts: [Account] = []

    public static let maxNameLength = 40

    public init(accounts: [Account] = []) {
        self.accounts = accounts
        sort()
    }

    // MARK: Paths

    public static func standardPath(index: UInt32) -> BIP32Path {
        BIP32Path(hardened: [44, 397, 0, 0, index])
    }

    public static func standardIndex(of path: BIP32Path) -> UInt32? {
        let prefix = BIP32Path(hardened: [44, 397, 0, 0]).components
        guard path.components.count == 5, Array(path.components.prefix(4)) == prefix,
              path.components[4] >= BIP32Path.hardenedOffset else { return nil }
        return path.components[4] - BIP32Path.hardenedOffset
    }

    /// The NEAR Ledger protocol addresses exactly 5 hardened levels; the first two must be
    /// `44'/397'` (BIP-44, NEAR's coin type).
    public static func isValidAccountPath(_ path: BIP32Path) -> Bool {
        let nearPrefix = BIP32Path(hardened: [44, 397]).components
        return path.components.count == NearAPDU.pathLength / 4 && path.isFullyHardened
            && Array(path.components.prefix(2)) == nearPrefix
    }

    public static func defaultName(for path: BIP32Path) -> String {
        standardIndex(of: path).map { "Account \($0)" } ?? "Custom account"
    }

    /// The lowest unused account number, starting at 1 (the Ledger default path).
    public var nextStandardPath: BIP32Path {
        let used = Set(accounts.compactMap(\.index))
        var index: UInt32 = 1
        while used.contains(index) { index += 1 }
        return AccountBook.standardPath(index: index)
    }

    // MARK: Lookup

    public func account(for path: BIP32Path) -> Account? {
        accounts.first { $0.path == path }
    }

    public func account(id: UUID) -> Account? {
        accounts.first { $0.id == id }
    }

    // MARK: Editing

    @discardableResult
    public mutating func add(path: BIP32Path, publicKey: Data, name: String? = nil, date: Date = Date()) throws -> Account {
        guard AccountBook.isValidAccountPath(path) else { throw AccountError.invalidPath(path.description) }
        guard account(for: path) == nil else { throw AccountError.duplicatePath(path.description) }
        let trimmed = AccountBook.clean(name ?? "")
        let account = Account(name: trimmed.isEmpty ? AccountBook.defaultName(for: path) : trimmed,
                              path: path, publicKey: publicKey, createdAt: date)
        accounts.append(account)
        sort()
        return account
    }

    public mutating func rename(id: UUID, to name: String) throws {
        let trimmed = AccountBook.clean(name)
        guard !trimmed.isEmpty else { throw AccountError.emptyName }
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].name = trimmed
    }

    public mutating func remove(id: UUID) {
        accounts.removeAll { $0.id == id }
    }

    /// Sets or (with nil or an empty string) clears the named account of an account.
    public mutating func setAccountId(id: UUID, to accountId: String?) throws {
        let trimmed = accountId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard trimmed.isEmpty || NearFormat.isValidAccountId(trimmed) else { throw AccountError.invalidAccountId(trimmed) }
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].accountId = trimmed.isEmpty ? nil : trimmed
    }

    public mutating func removeAll() {
        accounts.removeAll()
    }

    private static func clean(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
    }

    private mutating func sort() {
        accounts.sort { lhs, rhs in
            switch (lhs.index, rhs.index) {
            case let (left?, right?): return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.createdAt < rhs.createdAt
            }
        }
    }

    // MARK: Persistence

    /// Returns an empty book if the file is missing or unreadable.
    public static func load(from url: URL) -> AccountBook {
        guard let data = try? Data(contentsOf: url),
              let book = try? decoder.decode(AccountBook.self, from: data) else { return AccountBook() }
        return AccountBook(accounts: book.accounts)
    }

    public func save(to url: URL, options: Data.WritingOptions = [.atomic]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AccountBook.encoder.encode(self).write(to: url, options: options)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
