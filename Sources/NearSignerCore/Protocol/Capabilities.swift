import Foundation

/// NEAR Signer's answer to `80 20`, which tells a host that this is not a Ledger and what it can
/// do faster. Hosts that get `6D00` (a real Ledger) keep the standard protocol.
///
/// Layout: `"NS"` (2 bytes), format version (1), flags (1), largest chunk (u32 big-endian).
/// Flag bit 0: extended APDUs, so a host may send signing payloads in chunks of up to
/// `maxChunk` bytes instead of 250, with one reply per chunk.
public struct SignerCapabilities: Equatable, Sendable {
    public static let magic = Data("NS".utf8)
    public static let flagExtendedAPDU: UInt8 = 0x01
    /// 32 KiB: few round trips, while progress and Cancel still react within a second or two.
    public static let current = SignerCapabilities(version: 1, flags: flagExtendedAPDU, maxChunk: 32 * 1024)

    public var version: UInt8
    public var flags: UInt8
    public var maxChunk: Int

    public init(version: UInt8, flags: UInt8, maxChunk: Int) {
        self.version = version
        self.flags = flags
        self.maxChunk = maxChunk
    }

    public var supportsExtendedAPDU: Bool { flags & SignerCapabilities.flagExtendedAPDU != 0 }

    public var serialized: Data {
        var data = SignerCapabilities.magic + Data([version, flags])
        withUnsafeBytes(of: UInt32(maxChunk).bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// Parses a response's data (status word removed).
    public init?(response data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, Data(bytes[0..<2]) == SignerCapabilities.magic else { return nil }
        version = bytes[2]
        flags = bytes[3]
        maxChunk = bytes[4..<8].reduce(0) { $0 << 8 | Int($1) }
    }
}
