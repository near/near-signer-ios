import Foundation

/// `UniversalStateInit::V1` (NEP-655): what a universal account is created with. The account id
/// is the hash of these bytes, so the encoding is canonical: the storage entries sorted by key
/// and the access keys sorted, without duplicates, as nearcore's `BTreeMap` and `BTreeSet` write
/// them.
public struct UniversalStateInit: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var key: Data
        public var value: Data

        public init(key: Data, value: Data) {
            self.key = key
            self.value = value
        }
    }

    /// The contract the account runs, if any.
    public var code: GlobalContractIdentifier?
    /// The initial contract storage.
    public var data: [Entry]
    /// The full-access keys the account starts with.
    public var accessKeys: [PublicKeyHandle]

    public init(code: GlobalContractIdentifier?, data: [Entry], accessKeys: [PublicKeyHandle]) {
        self.code = code
        self.data = data
        self.accessKeys = accessKeys
    }

    /// A state init that commits to one key only: no contract, no storage. This is what a
    /// quantum-safe account made from a single ML-DSA-65 key is created with.
    public init(keyOnly handle: PublicKeyHandle) {
        self.init(code: nil, data: [], accessKeys: [handle])
    }

    /// The canonical borsh bytes: discriminant 0 (V1), the optional code, the entries sorted by
    /// key (a later entry replaces an earlier one with the same key, as inserting into a map
    /// does), and the keys sorted without duplicates.
    public var borsh: Data {
        var writer = BorshWriter()
        writer.writeU8(0)
        writer.writeOption(code) { $1.encode(&$0) }
        var entries: [Entry] = []
        for entry in data {
            if let index = entries.firstIndex(where: { $0.key == entry.key }) {
                entries[index] = entry
            } else {
                entries.append(entry)
            }
        }
        entries.sort { $0.key.lexicographicallyPrecedes($1.key) }
        writer.writeVector(entries) { writer, entry in
            writer.writeByteVector(entry.key)
            writer.writeByteVector(entry.value)
        }
        writer.writeVector(Array(Set(accessKeys)).sorted()) { $1.encode(&$0) }
        return writer.data
    }

    /// Decodes exactly `raw`: V1 only, nothing trailing, and in canonical form. Bytes that decode
    /// but re-encode differently (entries out of order, a repeated key) are refused as
    /// `nonCanonical` rather than shown as the account they would merely resemble.
    public static func decode(_ raw: Data) throws -> UniversalStateInit {
        var reader = BorshReader(raw)
        let version = try reader.readU8()
        guard version == 0 else { throw BorshError.invalidEnumTag(type: "UniversalStateInit", tag: version) }
        let code = try reader.readOption { try GlobalContractIdentifier.decode(&$0) }
        let data = try reader.readVector(maxCount: Limits.stateInitEntries) { reader in
            Entry(key: try reader.readByteVector(), value: try reader.readByteVector())
        }
        let accessKeys = try reader.readVector(maxCount: Limits.stateInitEntries) { try PublicKeyHandle.decode(&$0) }
        try reader.ensureAtEnd()
        let stateInit = UniversalStateInit(code: code, data: data, accessKeys: accessKeys)
        guard stateInit.borsh == raw else { throw BorshError.nonCanonical }
        return stateInit
    }
}

/// Universal account ids (NEP-655): `0u` followed by the SHA3-256 of the state init in Crockford
/// base32 (lowercase, 52 symbols, the last one carrying four zero padding bits), 54 characters in
/// all. The network creates the account only from the state init whose hash the id is.
public enum UniversalAccount {
    private static let alphabet = Set("0123456789abcdefghjkmnpqrstvwxyz".utf8)

    /// The id the network derives from exactly these state init bytes.
    public static func id(stateInit raw: Data) -> String {
        "0u" + Base32Crockford.encode(SHA3.hash256(raw)).lowercased()
    }

    /// The id of the account a single key creates (a key-only V1 state init with the key's
    /// handle): the account id of an ML-DSA-65 key, as the hex implicit id is of an ed25519 key.
    public static func id(forKey key: PublicKey) -> String {
        id(stateInit: UniversalStateInit(keyOnly: key.handle).borsh)
    }

    /// Whether `accountId` has the shape of a universal account id: the `0u` prefix (the `u`
    /// itself is not a base32 symbol), 52 symbols, and a final symbol of `0` or `g`, the only
    /// ones whose four padding bits are zero.
    public static func isUniversalId(_ accountId: String) -> Bool {
        let bytes = Array(accountId.utf8)
        guard bytes.count == 54, bytes[0] == UInt8(ascii: "0"), bytes[1] == UInt8(ascii: "u"),
              bytes[2...].allSatisfy({ alphabet.contains($0) }) else { return false }
        return bytes[53] == UInt8(ascii: "0") || bytes[53] == UInt8(ascii: "g")
    }
}
