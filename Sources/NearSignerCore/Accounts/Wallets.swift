import Foundation

/// One secret on the device: a recovery phrase (many accounts, one per derivation path) or an
/// imported private key (a single account). Holds public data only; the secret stays in the vault.
public struct Wallet: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case recoveryPhrase
        case privateKey
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var createdAt: Date
    public var book: AccountBook
    /// Account 1's public key, fixed when the wallet is added: identifies the secret even after
    /// accounts are hidden. Absent in lists written by older builds.
    public var fingerprint: Data?

    public init(id: UUID = UUID(), name: String = "", kind: Kind, createdAt: Date = Date(), book: AccountBook = AccountBook(),
                fingerprint: Data? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
        self.book = book
        self.fingerprint = fingerprint
    }

    public var accounts: [Account] { book.accounts }

    /// More accounts need more derivation paths, which only a recovery phrase has.
    public var canAddAccounts: Bool { kind == .recoveryPhrase || book.accounts.isEmpty }

    /// The account that answers a host request for `path`. An imported key answers every path.
    public func account(for path: BIP32Path) -> Account? {
        kind == .privateKey ? book.accounts.first : book.account(for: path)
    }

    /// Account 1's key identifies the secret: two wallets with the same one are the same wallet.
    public var identity: Data? { fingerprint ?? book.account(for: .ledgerDefault)?.publicKey ?? book.accounts.first?.publicKey }
}

public enum WalletError: Error, Equatable, CustomStringConvertible {
    case duplicate(existing: String)
    case emptyName

    public var description: String {
        switch self {
        case let .duplicate(existing): return "This wallet is already on this phone as \"\(existing)\"."
        case .emptyName: return "Enter a name."
        }
    }
}

/// All wallets on the device and which one is active. Hosts that ask for a public key get the
/// active wallet's; signing requests go to whichever wallet owns the key they name.
public struct WalletList: Codable, Equatable, Sendable {
    public private(set) var wallets: [Wallet] = []
    public private(set) var activeWalletID: UUID?

    public init(wallets: [Wallet] = [], activeWalletID: UUID? = nil) {
        self.wallets = wallets
        self.activeWalletID = activeWalletID
    }

    public var isEmpty: Bool { wallets.isEmpty }

    public var activeWallet: Wallet? {
        wallets.first { $0.id == activeWalletID } ?? wallets.first
    }

    public func wallet(id: UUID) -> Wallet? {
        wallets.first { $0.id == id }
    }

    public func nextDefaultName(for kind: Wallet.Kind) -> String {
        let base = kind == .recoveryPhrase ? "Wallet" : "Imported key"
        let names = Set(wallets.map(\.name))
        var index = wallets.filter { $0.kind == kind }.count + 1
        while names.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    // MARK: Wallets

    /// Ids of the wallets in the list.
    public var walletIDs: Set<UUID> { Set(wallets.map(\.id)) }

    /// Throws if the same secret is already on the device.
    public func checkCanAdd(_ wallet: Wallet) throws {
        guard let identity = wallet.identity else { return }
        if let existing = wallets.first(where: { $0.identity == identity }) {
            throw WalletError.duplicate(existing: existing.name)
        }
    }

    /// Adds a wallet (named by default if its name is empty) and makes it active.
    public mutating func add(_ wallet: Wallet, activate: Bool = true) throws {
        try checkCanAdd(wallet)
        var wallet = wallet
        if wallet.fingerprint == nil { wallet.fingerprint = wallet.identity }
        let trimmed = wallet.name.trimmingCharacters(in: .whitespacesAndNewlines)
        wallet.name = trimmed.isEmpty ? nextDefaultName(for: wallet.kind) : String(trimmed.prefix(AccountBook.maxNameLength))
        wallets.append(wallet)
        if activate || activeWalletID == nil { activeWalletID = wallet.id }
    }

    public mutating func remove(id: UUID) {
        wallets.removeAll { $0.id == id }
        if activeWalletID == id { activeWalletID = wallets.first?.id }
    }

    public mutating func removeAll() {
        wallets.removeAll()
        activeWalletID = nil
    }

    public mutating func activate(id: UUID) {
        guard wallet(id: id) != nil else { return }
        activeWalletID = id
    }

    public mutating func rename(id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WalletError.emptyName }
        guard let index = wallets.firstIndex(where: { $0.id == id }) else { return }
        wallets[index].name = String(trimmed.prefix(AccountBook.maxNameLength))
    }

    // MARK: Accounts

    public mutating func updateBook(of walletID: UUID, _ change: (inout AccountBook) throws -> Void) rethrows {
        guard let index = wallets.firstIndex(where: { $0.id == walletID }) else { return }
        try change(&wallets[index].book)
    }

    /// Records a key the user approved for `path`, so the account joins the wallet's list and
    /// later requests can be answered without unlocking.
    public mutating func rememberAccount(walletID: UUID, path: BIP32Path, publicKey: Data) {
        guard let index = wallets.firstIndex(where: { $0.id == walletID }) else { return }
        let wallet = wallets[index]
        guard wallet.kind == .recoveryPhrase || wallet.book.accounts.isEmpty,
              wallet.book.account(for: path) == nil else { return }
        _ = try? wallets[index].book.add(path: path, publicKey: publicKey)
    }

    /// The wallet and account with this account id.
    public func account(id: UUID) -> (wallet: Wallet, account: Account)? {
        for wallet in wallets {
            if let account = wallet.book.account(id: id) { return (wallet, account) }
        }
        return nil
    }

    public mutating func renameAccount(id: UUID, to name: String) throws {
        guard let owner = account(id: id) else { return }
        try updateBook(of: owner.wallet.id) { try $0.rename(id: id, to: name) }
    }

    /// Hides an account; every wallet keeps at least one.
    public mutating func removeAccount(id: UUID) {
        guard let owner = account(id: id), owner.wallet.accounts.count > 1 else { return }
        updateBook(of: owner.wallet.id) { $0.remove(id: id) }
    }

    public mutating func setAccountId(accountID: UUID, to accountId: String?) throws {
        guard let owner = account(id: accountID) else { return }
        try updateBook(of: owner.wallet.id) { try $0.setAccountId(id: accountID, to: accountId) }
    }

    // MARK: Routing

    /// The wallet that answers a request for `path`. A request that names a key goes to the wallet
    /// whose account at that path has it (the active wallet first); anything else goes to the
    /// active wallet.
    public func walletForRequest(path: BIP32Path, expectedPublicKey: Data?) -> Wallet? {
        if let expectedPublicKey, !expectedPublicKey.isEmpty {
            let ordered = (activeWallet.map { [$0] } ?? []) + wallets.filter { $0.id != activeWallet?.id }
            if let owner = ordered.first(where: { $0.account(for: path)?.publicKey == expectedPublicKey }) {
                return owner
            }
        }
        return activeWallet
    }

    /// The wallet and account that own an `ed25519:…` public key.
    public func owner(ofPublicKey publicKey: String) -> (wallet: Wallet, account: Account)? {
        for wallet in wallets {
            if let account = wallet.accounts.first(where: { $0.publicKeyString == publicKey }) { return (wallet, account) }
        }
        return nil
    }

    // MARK: Persistence

    public enum LoadResult: Sendable {
        case missing
        case loaded(WalletList)
        /// The file exists but cannot be read or decoded. Callers must not treat this as "no wallets".
        case unreadable(String)
    }

    public static func load(from url: URL) -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            return .loaded(try decoder.decode(WalletList.self, from: Data(contentsOf: url)))
        } catch {
            return .unreadable(String(describing: error))
        }
    }

    public func save(to url: URL, options: Data.WritingOptions = [.atomic]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WalletList.encoder.encode(self).write(to: url, options: options)
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
