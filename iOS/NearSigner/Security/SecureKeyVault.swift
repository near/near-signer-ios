import CryptoKit
import Foundation
import LocalAuthentication
import NearSignerCore
import Security

enum VaultError: LocalizedError {
    case noPasscode
    case keychain(OSStatus)
    case corrupted
    case authenticationFailed(String)
    case noSecureEnclave
    case biometryChanged
    case biometryUnavailable
    case deleteFailed(OSStatus)
    case enclaveKeyFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPasscode:
            return "Set a device passcode first. NEAR Signer stores keys only on devices protected by a passcode."
        case let .keychain(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain error \(status): \(message)"
        case .corrupted:
            return "The stored key could not be decrypted."
        case let .authenticationFailed(reason):
            return "Authentication failed: \(reason)"
        case .noSecureEnclave:
            return "This device has no Secure Enclave, so NEAR Signer cannot protect keys on it."
        case .biometryChanged:
            return "This wallet can't be unlocked: the enrolled faces or fingers changed since Strict Face ID was turned on. Remove the wallet and restore it from its recovery phrase."
        case .biometryUnavailable:
            return "Strict Face ID needs Face ID or Touch ID to be set up on this phone."
        case let .deleteFailed(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "The key could not be deleted (\(status): \(message))."
        case let .enclaveKeyFailed(reason):
            return "The Secure Enclave could not use this wallet's key: \(reason)"
        }
    }
}

extension VaultError: UserFacingError {
    var userMessage: String { errorDescription ?? String(describing: self) }
}

/// Key storage for the device: one secret per wallet.
///
/// The Secure Enclave cannot hold ed25519 keys (it supports P-256 only), so each wallet's secret
/// is encrypted to its own Secure Enclave P-256 key (ECDH + HKDF-SHA256 + AES-GCM). That P-256 key
/// never leaves the enclave and can only be used after Face ID / Touch ID / passcode, or, with
/// Strict Face ID, only after the biometrics enrolled when the key was made
/// (`.biometryCurrentSet`, enforced by the enclave itself). Each wallet is one keychain item
/// holding the enclave key's handle and the wrapped secret, so it changes atomically. All items are
/// `WhenPasscodeSetThisDeviceOnly`: they are excluded from backups, never sync to iCloud and are
/// destroyed if the passcode is removed. A decrypted secret exists in memory only for the duration
/// of one operation.
///
/// Public data (wallet names, accounts, public keys) lives in the `WalletRegistry`. Known accounts
/// double as the public-key cache: hosts get them without an unlock.
///
/// The iOS Simulator has no Secure Enclave and no passcode; there the secret is stored in the
/// keychain directly and the user-presence check is enforced by LocalAuthentication only.
final class SecureKeyVault: KeyVault, @unchecked Sendable {
    let registry: WalletRegistry
    private let service = "near-signer"

    init(registry: WalletRegistry) {
        self.registry = registry
    }

    static var usesSecureEnclave: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return SecureEnclave.isAvailable
        #endif
    }

    static var deviceHasPasscode: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// SF Symbol for the device's biometry, for buttons that trigger it.
    static var biometrySymbol: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock.fill"
        }
    }

    /// True when Face ID, Touch ID or Optic ID is set up (even if locked out after failed tries).
    static var hasBiometrics: Bool {
        var error: NSError?
        if LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) { return true }
        return error?.code == LAError.Code.biometryLockout.rawValue
    }

    /// "Face ID", "Touch ID", or "Passcode" when the phone has no biometrics set up.
    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    private static func secretAccount(_ id: UUID) -> String { "secret.\(id.uuidString)" }
    private static func enclaveAccount(_ id: UUID) -> String { "enclave.\(id.uuidString)" }

    /// Public facts stored with each keychain item (as `kSecAttrGeneric`), so a wallet can be
    /// recovered if the wallet list is lost, and items left by a deleted install recognized.
    private struct SecretTag: Codable {
        /// Changes when the app is reinstalled (it lives in UserDefaults, which an uninstall wipes).
        var install: String
        var kind: Wallet.Kind
        /// Account 1's public key, hex.
        var firstKey: String
        /// Strict Face ID: the enclave key accepts only the biometrics enrolled when it was made.
        var strict: Bool?
    }

    /// Item layout (Secure Enclave): `0x10 | u16 BE handle length | enclave key handle | wrapped
    /// secret`. Items written before carry only the wrapped secret, with the handle in a separate
    /// `enclave.<id>` item.
    private static let combinedFormat: UInt8 = 0x10

    /// Read only once the phone is unlocked (UserDefaults are unreadable before the first unlock).
    private var installID: String {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "installID") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "installID")
        return id
    }

    var hasKey: Bool { !registry.snapshot.isEmpty }

    // MARK: Authentication

    /// Whether new wallets are made with Strict Face ID.
    private var strictPreferred: Bool {
        get { UserDefaults.standard.bool(forKey: "strictBiometricsPreferred") }
        set { UserDefaults.standard.set(newValue, forKey: "strictBiometricsPreferred") }
    }

    /// Strict Face ID as earlier versions stored it: the app checked this Face ID domain state,
    /// and the enclave keys still accept the passcode. Until the wallets are re-encrypted
    /// (`setStrictBiometrics(true)`), the app keeps enforcing it for wallets without a strict key.
    private static let legacyStrictKey = "strictBiometryState"
    private var legacyStrictState: Data? { UserDefaults.standard.data(forKey: SecureKeyVault.legacyStrictKey) }

    /// Strict Face ID was turned on in an earlier version and the keys are not re-encrypted yet.
    var strictUpgradePending: Bool { legacyStrictState != nil }

    /// Strict Face ID is on when every wallet's key is strict (read from the keychain, so it
    /// survives a reinstall), or, without wallets, when it was chosen for new ones.
    var strictBiometrics: Bool {
        if strictUpgradePending { return true }
        let ids = registry.snapshot.walletIDs
        guard !ids.isEmpty else { return strictPreferred }
        return ids.allSatisfy { readTag(SecureKeyVault.secretAccount($0))?.strict == true }
    }

    /// Whether any key on this phone is strict, listed or not (an earlier installation's wallets
    /// included). Weakening settings then needs Face ID: after a reinstall nothing is listed yet,
    /// and the passcode alone must not open the way to restoring and using those wallets.
    var anyStrict: Bool {
        if strictUpgradePending || strictPreferred { return true }
        return allItems()?.contains { $0.tag?.strict == true } ?? true
    }

    /// Asks for Face ID / Touch ID or the passcode (biometrics only if `biometricsOnly`) and
    /// returns the evaluated context. Removing wallets and similar actions allow the passcode, so a
    /// wallet whose strict key no longer opens can still be removed and restored.
    @discardableResult
    func authenticate(reason: String, biometricsOnly: Bool = false) async throws -> LAContext {
        let context = LAContext()
        context.localizedFallbackTitle = biometricsOnly ? "" : "Enter Passcode"
        context.touchIDAuthenticationAllowableReuseDuration = 0
        let policy: LAPolicy = biometricsOnly ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        var policyError: NSError?
        guard context.canEvaluatePolicy(policy, error: &policyError) else {
            throw biometricsOnly ? VaultError.biometryUnavailable : VaultError.noPasscode
        }
        do {
            _ = try await context.evaluatePolicy(policy, localizedReason: reason)
        } catch let error as LAError where SecureKeyVault.cancelCodes.contains(error.code) {
            throw KeyError.authenticationCancelled
        } catch {
            throw VaultError.authenticationFailed(error.localizedDescription)
        }
        return context
    }

    /// Asks for the device passcode only, never Face ID, for people who would rather not use their
    /// face. There is no passcode-only policy, so this evaluates an access control that requires
    /// the passcode.
    @discardableResult
    func authenticateWithPasscode(reason: String) async throws -> LAContext {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil),
              let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .devicePasscode, nil) else {
            throw VaultError.noPasscode
        }
        do {
            _ = try await context.evaluateAccessControl(access, operation: .useItem, localizedReason: reason)
        } catch let error as LAError where SecureKeyVault.cancelCodes.contains(error.code) {
            throw KeyError.authenticationCancelled
        } catch {
            throw VaultError.authenticationFailed(error.localizedDescription)
        }
        return context
    }

    /// Re-wraps every wallet's secret to a new enclave key: strict (current biometrics only) or
    /// back to Face ID / passcode. Needs Face ID either way. A wallet whose strict key no longer
    /// opens (the biometrics changed) is reported and left as is.
    func setStrictBiometrics(_ enabled: Bool) async throws {
        let context = try await authenticate(reason: enabled ? "Turn on Strict Face ID" : "Turn off Strict Face ID",
                                             biometricsOnly: true)
        // With Strict Face ID from an earlier version, a face enrolled since then can't change it.
        if let legacy = legacyStrictState, context.evaluatedPolicyDomainState != legacy {
            throw VaultError.biometryChanged
        }
        var failure: Error?
        for id in registry.snapshot.walletIDs {
            do {
                try rewrap(walletID: id, strict: enabled, context: context)
            } catch {
                failure = failure ?? error
            }
        }
        strictPreferred = enabled
        if let failure { throw failure }
        UserDefaults.standard.removeObject(forKey: SecureKeyVault.legacyStrictKey)
    }

    // MARK: Wallets

    /// Stores a new wallet's secret and adds the wallet, with Account 1, as the active wallet.
    @discardableResult
    func addWallet(_ material: KeyMaterial, name: String = "") throws -> Wallet {
        #if !targetEnvironment(simulator)
        guard SecureKeyVault.deviceHasPasscode else { throw VaultError.noPasscode }
        #endif
        var wallet = Wallet(name: name, kind: material.derivesFromPath ? .recoveryPhrase : .privateKey)
        let firstKey = try material.privateKey(for: .ledgerDefault).publicKey.rawRepresentation
        try wallet.book.add(path: .ledgerDefault, publicKey: firstKey)
        try registry.snapshot.checkCanAdd(wallet)
        let tag = SecretTag(install: installID, kind: wallet.kind, firstKey: firstKey.hexString,
                            strict: strictBiometrics ? true : nil)
        var secret = material.serialized
        defer { secret.resetBytes(in: 0..<secret.count) }
        wallet.fingerprint = firstKey
        try storeSecret(secret, for: wallet.id, tag: tag)
        do {
            // Saved before it counts as added; on failure the secret goes too.
            try registry.update { try $0.add(wallet) }
        } catch {
            deleteSecret(for: wallet.id)
            throw error
        }
        return registry.snapshot.wallet(id: wallet.id) ?? wallet
    }

    /// Deletes the wallet's keychain items, and only then removes it from the list: a wallet whose
    /// secret survived must not disappear from view (it would come back as "Recovered wallet").
    func removeWallet(id: UUID) throws {
        for account in [SecureKeyVault.secretAccount(id), SecureKeyVault.enclaveAccount(id)] {
            let status = deleteItem(account)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.deleteFailed(status) }
        }
        try registry.update { $0.remove(id: id) }
    }

    func removeAllWallets() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.keychain(status) }
        try registry.update { $0.removeAll() }
    }

    /// Derives a public key for the app itself (Add account). Nothing is remembered.
    func publicKey(walletID: UUID, path: BIP32Path, reason: String) async throws -> Data {
        let material = try await unlock(walletID: walletID, reason: reason)
        return try material.privateKey(for: path).publicKey.rawRepresentation
    }

    // MARK: KeyVault (host requests)

    func cachedPublicKey(for path: BIP32Path) async -> Data? {
        registry.snapshot.activeWallet?.account(for: path)?.publicKey
    }

    func cachedPublicKey(for path: BIP32Path, expecting expectedPublicKey: Data?) async -> Data? {
        let list = registry.snapshot
        return list.walletForRequest(path: path, expectedPublicKey: expectedPublicKey)?.account(for: path)?.publicKey
    }

    /// Called after the user approved sharing: the account joins the active wallet's list.
    func derivePublicKey(for path: BIP32Path, reason: String) async throws -> Data {
        guard let wallet = registry.snapshot.activeWallet else { throw KeyError.noKey }
        let publicKey = try await publicKey(walletID: wallet.id, path: path, reason: reason)
        try? registry.update { $0.rememberAccount(walletID: wallet.id, path: path, publicKey: publicKey) }
        return publicKey
    }

    func sign(digest: Data, path: BIP32Path, expectedPublicKey: Data?, reason: String) async throws -> SignResult {
        guard let wallet = registry.snapshot.walletForRequest(path: path, expectedPublicKey: expectedPublicKey) else {
            throw KeyError.noKey
        }
        let material = try await unlock(walletID: wallet.id, reason: reason)
        let key = try material.privateKey(for: path)
        let publicKey = key.publicKey.rawRepresentation
        if let expectedPublicKey, expectedPublicKey != publicKey {
            throw SignerError.publicKeyMismatch(expected: PublicKey.ed25519(expectedPublicKey).description,
                                                actual: PublicKey.ed25519(publicKey).description)
        }
        let signature = try key.signature(for: digest)
        // Remembered only after the check: a failed request must not count as sharing the key.
        try? registry.update { $0.rememberAccount(walletID: wallet.id, path: path, publicKey: publicKey) }
        return SignResult(signature: signature, publicKey: publicKey)
    }

    // MARK: Housekeeping

    /// A wallet left in the keychain by an earlier installation of the app.
    struct EarlierWallet: Identifiable, Equatable {
        let id: UUID
        let kind: Wallet.Kind
        let firstKey: Data
    }

    /// Run once the phone is unlocked and the wallet list is loaded. Every step leaves secrets in
    /// place unless it is sure.
    ///
    /// 1. Moves the single key of earlier builds into the wallet list.
    /// 2. Recovers wallets of this install that are missing from the list (a lost or damaged file).
    /// 3. Drops listed wallets whose secret is gone (for example after the passcode was removed).
    /// 4. Returns wallets left by an earlier installation (keychain items outlive an uninstall;
    ///    the install id in UserDefaults does not), for the user to restore or delete.
    func migrateAndCleanUp(legacyAccountsURL: URL) -> [EarlierWallet] {
        migrateLegacyKey(accountsURL: legacyAccountsURL)
        guard let items = allItems() else { return [] }   // keychain not readable: change nothing
        let install = installID
        let listed = registry.snapshot.walletIDs

        var secrets: [UUID: SecretTag?] = [:]
        var earlier: [EarlierWallet] = []
        for item in items {
            let parts = item.account.split(separator: ".", maxSplits: 1)
            guard parts.count == 2, parts[0] == "secret", let id = UUID(uuidString: String(parts[1])) else { continue }
            if let tag = item.tag, tag.install != install, !listed.contains(id) {
                if let key = Data(hexString: tag.firstKey) { earlier.append(EarlierWallet(id: id, kind: tag.kind, firstKey: key)) }
                continue
            }
            secrets.updateValue(item.tag, forKey: id)
        }

        for (id, tag) in secrets where !listed.contains(id) {
            guard let tag, tag.install == install, let key = Data(hexString: tag.firstKey) else { continue }
            var wallet = Wallet(id: id, name: "Recovered wallet", kind: tag.kind, fingerprint: key)
            _ = try? wallet.book.add(path: .ledgerDefault, publicKey: key)
            do {
                try registry.update { try $0.add(wallet, activate: false) }
            } catch WalletError.duplicate {
                // The same secret is listed under another id: this copy is an orphan.
                if isRedundant(wallet) { deleteSecret(for: id) }
            } catch {}
        }
        for id in listed where secrets.index(forKey: id) == nil {
            try? registry.update { $0.remove(id: id) }
        }
        return earlier
    }

    /// Adopts wallets from an earlier installation: they are tagged with this install (keeping
    /// Strict Face ID) and listed. A copy of a wallet that is already listed is deleted instead;
    /// a recovery phrase whose first key is listed only as an imported key is kept, unlisted.
    func restoreEarlierWallets(_ wallets: [EarlierWallet]) {
        for earlier in wallets {
            var wallet = Wallet(id: earlier.id, name: "Restored wallet", kind: earlier.kind, fingerprint: earlier.firstKey)
            _ = try? wallet.book.add(path: .ledgerDefault, publicKey: earlier.firstKey)
            do {
                try registry.snapshot.checkCanAdd(wallet)
            } catch {
                if isRedundant(wallet) { deleteSecret(for: earlier.id) }
                continue
            }
            let strict = readTag(SecureKeyVault.secretAccount(earlier.id))?.strict
            let tag = SecretTag(install: installID, kind: earlier.kind, firstKey: earlier.firstKey.hexString, strict: strict)
            retag(SecureKeyVault.secretAccount(earlier.id), tag: tag)
            retag(SecureKeyVault.enclaveAccount(earlier.id), tag: tag)
            try? registry.update { try $0.add(wallet, activate: false) }
        }
    }

    /// Whether a wallet with the same secret and kind is listed. A recovery phrase is not
    /// redundant next to an imported key for its first account: it also holds the other accounts.
    private func isRedundant(_ wallet: Wallet) -> Bool {
        registry.snapshot.wallets.contains { $0.identity == wallet.identity && $0.kind == wallet.kind }
    }

    func deleteEarlierWallets(_ wallets: [EarlierWallet]) {
        for earlier in wallets { deleteSecret(for: earlier.id) }
    }

    private func migrateLegacyKey(accountsURL: URL) {
        let defaults = UserDefaults.standard
        let legacySecret = "wrapped-secret"
        let legacyEnclave = "enclave-key"
        let (blob, status) = readItemWithStatus(legacySecret)
        guard status != errSecItemNotFound else { return }
        // Unreadable now, or its kind unknown: leave it for a later launch rather than guess.
        guard let blob, let kindName = defaults.string(forKey: "keyKind") else { return }
        let kind: Wallet.Kind = kindName == "singleKey" ? .privateKey : .recoveryPhrase
        var book = AccountBook.load(from: accountsURL)
        if book.accounts.isEmpty,
           let hex = (defaults.dictionary(forKey: "publicKeyCache") as? [String: String])?[BIP32Path.ledgerDefault.description],
           let key = Data(hexString: hex) {
            _ = try? book.add(path: .ledgerDefault, publicKey: key)
        }
        let firstKey = book.account(for: .ledgerDefault)?.publicKey ?? book.accounts.first?.publicKey ?? Data()
        let wallet = Wallet(kind: kind, book: book, fingerprint: firstKey.isEmpty ? nil : firstKey)
        let tag = SecretTag(install: installID, kind: kind, firstKey: firstKey.hexString)
        do {
            try addItem(account: SecureKeyVault.secretAccount(wallet.id), data: blob, tag: tag)
            if let enclave = readItem(legacyEnclave) {
                try addItem(account: SecureKeyVault.enclaveAccount(wallet.id), data: enclave, tag: tag)
            } else if SecureKeyVault.usesSecureEnclave {
                throw VaultError.corrupted
            }
            try registry.update { try $0.add(wallet) }
        } catch WalletError.duplicate {
            // Already migrated by an earlier launch that stopped before cleaning up; the old copy
            // goes only if the listed wallet is of the same kind.
            deleteSecret(for: wallet.id)
            guard registry.snapshot.wallets.contains(where: { $0.fingerprint == firstKey && $0.kind == kind }) else { return }
        } catch {
            deleteSecret(for: wallet.id)
            return
        }
        deleteItem(legacySecret)
        deleteItem(legacyEnclave)
        defaults.removeObject(forKey: "keyKind")
        defaults.removeObject(forKey: "publicKeyCache")
        try? FileManager.default.removeItem(at: accountsURL)
    }

    // MARK: Secrets

    private func storeSecret(_ secret: Data, for id: UUID, tag: SecretTag) throws {
        #if !targetEnvironment(simulator)
        guard SecureKeyVault.usesSecureEnclave else { throw VaultError.noSecureEnclave }
        #endif
        let item = SecureKeyVault.usesSecureEnclave ? try sealed(secret, strict: tag.strict == true) : secret
        try addItem(account: SecureKeyVault.secretAccount(id), data: item, tag: tag)
    }

    /// Wraps `secret` to a new enclave key and returns the combined item data.
    private func sealed(_ secret: Data, strict: Bool) throws -> Data {
        let flags: SecAccessControlCreateFlags = strict ? [.privateKeyUsage, .biometryCurrentSet] : [.privateKeyUsage, .userPresence]
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, flags, nil) else {
            throw VaultError.noPasscode
        }
        let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let handle = enclaveKey.dataRepresentation
        guard handle.count <= Int(UInt16.max) else { throw VaultError.corrupted }
        return Data([SecureKeyVault.combinedFormat, UInt8(handle.count >> 8), UInt8(handle.count & 0xFF)])
            + handle + (try SecureKeyVault.wrap(secret, to: enclaveKey.publicKey))
    }

    /// Opens a wallet's item with an evaluated context.
    private func opened(_ item: Data, walletID: UUID, context: LAContext) throws -> Data {
        guard SecureKeyVault.usesSecureEnclave else { return item }
        let handle: Data
        let blob: Data
        if item.first == SecureKeyVault.combinedFormat {
            guard item.count > 3 else { throw VaultError.corrupted }
            let length = Int(item[item.startIndex + 1]) << 8 | Int(item[item.startIndex + 2])
            guard item.count > 3 + length else { throw VaultError.corrupted }
            handle = item.subdata(in: (item.startIndex + 3)..<(item.startIndex + 3 + length))
            blob = item.subdata(in: (item.startIndex + 3 + length)..<item.endIndex)
        } else {
            guard let separate = readItem(SecureKeyVault.enclaveAccount(walletID)) else { throw VaultError.corrupted }
            handle = separate
            blob = item
        }
        // The evaluated context satisfies the key's access control without a second prompt.
        let enclaveKey: SecureEnclave.P256.KeyAgreement.PrivateKey
        do {
            enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: handle, authenticationContext: context)
        } catch {
            throw VaultError.enclaveKeyFailed(error.localizedDescription)
        }
        return try SecureKeyVault.unwrap(blob, with: enclaveKey)
    }

    /// Replaces a wallet's enclave key in one keychain update.
    private func rewrap(walletID: UUID, strict: Bool, context: LAContext) throws {
        let account = SecureKeyVault.secretAccount(walletID)
        guard let item = readItem(account), var tag = readTag(account) else { throw KeyError.noKey }
        guard SecureKeyVault.usesSecureEnclave else {
            tag.strict = strict ? true : nil
            retag(account, tag: tag)
            return
        }
        var secret: Data
        do {
            secret = try opened(item, walletID: walletID, context: context)
        } catch VaultError.enclaveKeyFailed where tag.strict == true {
            throw VaultError.biometryChanged
        }
        defer { secret.resetBytes(in: 0..<secret.count) }
        tag.strict = strict ? true : nil
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [
            kSecValueData as String: try sealed(secret, strict: strict),
            kSecAttrGeneric as String: (try? JSONEncoder().encode(tag)) ?? Data(),
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
        deleteItem(SecureKeyVault.enclaveAccount(walletID))   // a handle from the older layout, now unused
    }

    private func deleteSecret(for id: UUID) {
        deleteItem(SecureKeyVault.secretAccount(id))
        deleteItem(SecureKeyVault.enclaveAccount(id))
    }

    private func unlock(walletID: UUID, reason: String) async throws -> KeyMaterial {
        let account = SecureKeyVault.secretAccount(walletID)
        let strict = readTag(account)?.strict == true
        // A key from before hardware-enforced Strict Face ID: the app enforces it, as before.
        let legacy = strict ? nil : legacyStrictState
        let context = try await authenticate(reason: reason, biometricsOnly: strict || legacy != nil)
        if let legacy, context.evaluatedPolicyDomainState != legacy { throw VaultError.biometryChanged }
        guard let item = readItem(account) else { throw KeyError.noKey }
        var secret: Data
        do {
            secret = try opened(item, walletID: walletID, context: context)
        } catch VaultError.enclaveKeyFailed where strict {
            // A strict key stops working for good when the enrolled biometrics change.
            throw VaultError.biometryChanged
        }
        defer { secret.resetBytes(in: 0..<secret.count) }
        return try KeyMaterial(serialized: secret)
    }

    private static let cancelCodes: [LAError.Code] = [.userCancel, .appCancel, .systemCancel]

    static func wrap(_ secret: Data, to recipient: P256.KeyAgreement.PublicKey) throws -> Data {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = symmetricKey(shared, ephemeralPublicKey: ephemeral.publicKey)
        guard let combined = try AES.GCM.seal(secret, using: key).combined else { throw VaultError.corrupted }
        return Data([1]) + ephemeral.publicKey.x963Representation + combined
    }

    /// Errors: `enclaveKeyFailed` when the enclave refuses the key (its access control, for
    /// example after the enrolled biometrics changed), `corrupted` when the data is damaged.
    static func unwrap(_ blob: Data, with enclaveKey: SecureEnclave.P256.KeyAgreement.PrivateKey) throws -> Data {
        let bytes = Data(blob)
        guard bytes.count > 66, bytes[0] == 1,
              let ephemeralPublicKey = try? P256.KeyAgreement.PublicKey(x963Representation: bytes.subdata(in: 1..<66)) else {
            throw VaultError.corrupted
        }
        let shared: SharedSecret
        do {
            shared = try enclaveKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
        } catch {
            throw VaultError.enclaveKeyFailed(error.localizedDescription)
        }
        let key = symmetricKey(shared, ephemeralPublicKey: ephemeralPublicKey)
        guard let box = try? AES.GCM.SealedBox(combined: bytes.subdata(in: 66..<bytes.count)),
              let secret = try? AES.GCM.open(box, using: key) else { throw VaultError.corrupted }
        return secret
    }

    private static func symmetricKey(_ shared: SharedSecret, ephemeralPublicKey: P256.KeyAgreement.PublicKey) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                       salt: ephemeralPublicKey.x963Representation,
                                       sharedInfo: Data("near-signer key wrap v1".utf8),
                                       outputByteCount: 32)
    }

    // MARK: Keychain

    private static var accessibility: CFString {
        #if targetEnvironment(simulator)
        return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #else
        return kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        #endif
    }

    private func addItem(account: String, data: Data, tag: SecretTag) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: SecureKeyVault.accessibility,
            kSecAttrSynchronizable as String: false,
            kSecAttrGeneric as String: (try? JSONEncoder().encode(tag)) ?? Data(),
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    private func readItem(_ account: String) -> Data? {
        readItemWithStatus(account).data
    }

    private func readItemWithStatus(_ account: String) -> (data: Data?, status: OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status == errSecSuccess ? result as? Data : nil, status)
    }

    @discardableResult
    private func deleteItem(_ account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary)
    }

    private func readTag(_ account: String) -> SecretTag? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any],
              let data = attributes[kSecAttrGeneric as String] as? Data else { return nil }
        return try? JSONDecoder().decode(SecretTag.self, from: data)
    }

    private func retag(_ account: String, tag: SecretTag) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecAttrGeneric as String: (try? JSONEncoder().encode(tag)) ?? Data()]
        SecItemUpdate(query as CFDictionary, update as CFDictionary)
    }

    /// Every keychain item of this app with its tag, or nil if the keychain cannot be read.
    private func allItems() -> [(account: String, tag: SecretTag?)]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return nil }
        return items.compactMap { attributes in
            guard let account = attributes[kSecAttrAccount as String] as? String else { return nil }
            let tag = (attributes[kSecAttrGeneric as String] as? Data).flatMap { try? JSONDecoder().decode(SecretTag.self, from: $0) }
            return (account, tag)
        }
    }
}
