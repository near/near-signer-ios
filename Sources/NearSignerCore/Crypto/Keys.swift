import Foundation

/// BIP-32 derivation path. NEAR uses hardened components only (SLIP-10 ed25519).
public struct BIP32Path: Hashable, Codable, Sendable, CustomStringConvertible {
    public static let hardenedOffset: UInt32 = 0x8000_0000
    /// Default path of the NEAR Ledger app and of `near-cli-rs ... sign-with-ledger`.
    public static let ledgerDefault = BIP32Path(hardened: [44, 397, 0, 0, 1])
    /// Default path of `near-cli-rs` seed-phrase import (`m/44'/397'/0'`).
    public static let nearCliSeedPhraseDefault = BIP32Path(hardened: [44, 397, 0])

    public var components: [UInt32]

    public init(components: [UInt32]) {
        self.components = components
    }

    public init(hardened indexes: [UInt32]) {
        self.components = indexes.map { $0 | BIP32Path.hardenedOffset }
    }

    /// Parses `m/44'/397'/0'/0'/1'` (the `m/` prefix is optional; `h` or `'` marks hardened).
    public init?(_ string: String) {
        var parts = string.trimmingCharacters(in: .whitespaces).split(separator: "/").map(String.init)
        if parts.first == "m" { parts.removeFirst() }
        guard !parts.isEmpty, parts.count <= 10 else { return nil }
        var components: [UInt32] = []
        for part in parts {
            var text = part
            var hardened = false
            if text.hasSuffix("'") || text.hasSuffix("h") || text.hasSuffix("H") {
                hardened = true
                text.removeLast()
            }
            guard let value = UInt32(text), value < BIP32Path.hardenedOffset else { return nil }
            components.append(hardened ? value | BIP32Path.hardenedOffset : value)
        }
        self.components = components
    }

    /// Big-endian u32 per component, no count prefix (NEAR Ledger app wire format).
    public var serialized: Data {
        var data = Data()
        for component in components {
            withUnsafeBytes(of: component.bigEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    public init?(serialized data: Data) {
        guard !data.isEmpty, data.count % 4 == 0 else { return nil }
        let bytes = [UInt8](data)
        components = stride(from: 0, to: bytes.count, by: 4).map { offset in
            bytes[offset..<(offset + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
    }

    public var isFullyHardened: Bool { components.allSatisfy { $0 >= BIP32Path.hardenedOffset } }

    public var description: String {
        "m/" + components.map { component in
            component >= BIP32Path.hardenedOffset ? "\(component - BIP32Path.hardenedOffset)'" : "\(component)"
        }.joined(separator: "/")
    }
}

public enum KeyError: Error, Equatable, CustomStringConvertible {
    case nonHardenedPath(String)
    case invalidSecretKey(String)
    case noKey
    case locked
    /// The user cancelled the Face ID / passcode prompt. Treated as a rejection.
    case authenticationCancelled

    public var description: String {
        switch self {
        case let .nonHardenedPath(path): return "ed25519 supports hardened derivation only (\(path))"
        case let .invalidSecretKey(reason): return "invalid secret key: \(reason)"
        case .noKey: return "no signing key is configured"
        case .locked: return "the key is locked"
        case .authenticationCancelled: return "authentication was cancelled"
        }
    }
}

/// SLIP-0010 ed25519 key derivation (hardened only).
public enum SLIP10 {
    public static func derive(seed: Data, path: BIP32Path) throws -> Data {
        try derive(secret: seed, path: path).data
    }

    /// Derives into wiped-on-release memory and overwrites the intermediate keys.
    static func derive<Seed: ContiguousBytes>(secret seed: Seed, path: BIP32Path) throws -> SecretBytes {
        guard path.isFullyHardened else { throw KeyError.nonHardenedPath(path.description) }
        var digest = seed.withUnsafeBytes { hmac(key: Data("ed25519 seed".utf8), data: Data($0)) }
        defer { digest.resetBytes(in: 0..<digest.count) }
        for component in path.components {
            var data = Data([0]) + digest.prefix(32)
            withUnsafeBytes(of: component.bigEndian) { data.append(contentsOf: $0) }
            let chainCode = Data(digest.suffix(32))
            digest.resetBytes(in: 0..<digest.count)
            digest = hmac(key: chainCode, data: data)
            data.resetBytes(in: 0..<data.count)
        }
        return SecretBytes(digest.prefix(32))
    }

    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA512>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}

/// Secret material stored on the device, held in memory that is wiped when released.
public enum KeyMaterial: Equatable, Sendable {
    /// 64-byte BIP-39 seed. Any hardened path can be derived from it.
    case bip39Seed(SecretBytes)
    /// A single 32-byte ed25519 private key (seed). The derivation path is ignored.
    case ed25519(SecretBytes)

    public func privateKey(for path: BIP32Path) throws -> Curve25519.Signing.PrivateKey {
        switch self {
        case let .bip39Seed(seed):
            return try Curve25519.Signing.PrivateKey(rawRepresentation: SLIP10.derive(secret: seed, path: path))
        case let .ed25519(secret):
            return try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        }
    }

    public var derivesFromPath: Bool {
        if case .bip39Seed = self { return true }
        return false
    }

    /// Compact storage format: 1 tag byte + secret bytes. The caller should wipe the result
    /// (`resetBytes`) once stored.
    public var serialized: Data {
        switch self {
        case let .bip39Seed(seed): return Data([1]) + seed.data
        case let .ed25519(secret): return Data([2]) + secret.data
        }
    }

    public init(serialized data: Data) throws {
        guard let tag = data.first else { throw KeyError.invalidSecretKey("empty") }
        let body = data.dropFirst()
        switch (tag, body.count) {
        case (1, 64): self = .bip39Seed(SecretBytes(body))
        case (2, 32): self = .ed25519(SecretBytes(body))
        default: throw KeyError.invalidSecretKey("unknown stored format")
        }
    }

    public static func fromMnemonic(_ phrase: String, passphrase: String = "") throws -> KeyMaterial {
        let words = BIP39.normalize(phrase)
        try BIP39.validate(words)
        var seed = BIP39.seed(from: words, passphrase: passphrase)
        defer { seed.resetBytes(in: 0..<seed.count) }
        return .bip39Seed(SecretBytes(seed))
    }

    /// Parses NEAR's `ed25519:<base58>` secret key (64 bytes: seed + public key, or a bare 32-byte seed).
    public static func fromNearSecretKey(_ string: String) throws -> KeyMaterial {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ed25519:") else {
            throw KeyError.invalidSecretKey("expected the ed25519: prefix")
        }
        guard var bytes = Base58.decode(String(trimmed.dropFirst("ed25519:".count))) else {
            throw KeyError.invalidSecretKey("not valid base58")
        }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        switch bytes.count {
        case 32:
            return .ed25519(SecretBytes(bytes))
        case 64:
            let seed = SecretBytes(bytes.prefix(32))
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            guard key.publicKey.rawRepresentation == bytes.suffix(32) else {
                throw KeyError.invalidSecretKey("public key half does not match the private key")
            }
            return .ed25519(seed)
        default:
            throw KeyError.invalidSecretKey("expected 32 or 64 bytes, got \(bytes.count)")
        }
    }
}

public extension Curve25519.Signing.PublicKey {
    /// `ed25519:<base58>`
    var nearString: String { "ed25519:" + Base58.encode(rawRepresentation) }
}
