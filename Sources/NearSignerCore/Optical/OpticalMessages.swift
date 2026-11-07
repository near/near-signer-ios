import Foundation

/// The message carried by the request frames: what the Ledger APDU would carry, with the
/// instruction in front. The instruction's bit 0x80 marks a payload sent compressed (its length,
/// then raw DEFLATE), which `init(message:)` inflates: from there the request is the same.
public struct OpticalRequest: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case transaction = 0x02
        case publicKey = 0x04
        case nep413 = 0x07
        case nep366 = 0x08
    }

    /// Set on the instruction byte when the payload is compressed.
    public static let compressedFlag: UInt8 = 0x80

    public var kind: Kind
    public var path: BIP32Path
    public var payload: Data

    public init(kind: Kind, path: BIP32Path, payload: Data) {
        self.kind = kind
        self.path = path
        self.payload = payload
    }

    /// Nil if `parse` refuses the message.
    public init?(message: Data) {
        guard case let .success(request) = OpticalRequest.parse(message) else { return nil }
        self = request
    }

    /// The request, or the status word the phone answers instead, as over Bluetooth: `6D00` for an
    /// unknown instruction, `B00B` for a path that isn't a NEAR account path (5 hardened levels
    /// under 44'/397', as the APDUs require), and `6A80` for a message too short, a public key
    /// request with a payload, or a compressed payload that doesn't inflate to exactly the length
    /// it declares (1 to `NearAPDU.maxPayload` bytes).
    public static func parse(_ message: Data) -> Result<OpticalRequest, StatusWord> {
        let bytes = Data(message)
        let headerLength = 1 + NearAPDU.pathLength
        guard bytes.count >= headerLength else { return .failure(.invalidData) }
        guard let kind = Kind(rawValue: bytes[0] & ~OpticalRequest.compressedFlag) else { return .failure(.insNotSupported) }
        guard let path = BIP32Path(serialized: bytes.subdata(in: 1..<headerLength)),
              AccountBook.isValidAccountPath(path) else { return .failure(.badPath) }
        var payload = bytes.subdata(in: headerLength..<bytes.count)
        if bytes[0] & OpticalRequest.compressedFlag != 0 {
            guard kind != .publicKey, payload.count >= 4 else { return .failure(.invalidData) }
            let length = Int(payload.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard length >= 1, length <= NearAPDU.maxPayload,
                  let inflated = try? Inflate.inflate(payload.dropFirst(4), expectedLength: length) else { return .failure(.invalidData) }
            payload = inflated
        }
        if kind == .publicKey, !payload.isEmpty { return .failure(.invalidData) }
        return .success(OpticalRequest(kind: kind, path: path, payload: payload))
    }

    public var message: Data {
        Data([kind.rawValue]) + path.serialized + payload
    }

    /// The compressed form of the message, from the payload's raw DEFLATE bytes (the core has no
    /// encoder; computers compress, the phone inflates). The payload's own length goes in front.
    public func message(deflatedPayload: Data) -> Data {
        var bytes = Data([kind.rawValue | OpticalRequest.compressedFlag]) + path.serialized
        bytes.append(bigEndian: UInt32(payload.count))
        bytes.append(deflatedPayload)
        return bytes
    }

    /// Nil for a public key request.
    public var signKind: SignerService.SignKind? {
        switch kind {
        case .transaction: return .transaction
        case .nep413: return .nep413
        case .nep366: return .nep366
        case .publicKey: return nil
        }
    }
}

/// The phone's answer, one QR code (and typed text) in Crockford base32.
public struct OpticalResponse: Equatable, Sendable {
    static let type: UInt8 = 0x02

    public var sessionId: UInt32
    public var status: StatusWord
    /// A 64-byte signature or a 32-byte public key; empty on an error.
    public var result: Data

    public init(sessionId: UInt32, status: StatusWord, result: Data) {
        self.sessionId = sessionId
        self.status = status
        self.result = result
    }

    /// Reads typed or scanned text: forgiving about case, spaces and look-alike letters, strict
    /// about the checksum.
    public init?(text: String) {
        guard let bytes = Base32Crockford.decode(text), bytes.count >= 11, bytes[0] == OpticalResponse.type else { return nil }
        let body = bytes.prefix(bytes.count - 4)
        let crc = bytes.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard CRC32.checksum(body) == crc,
              let status = StatusWord(rawValue: UInt16(bytes[5]) << 8 | UInt16(bytes[6])) else { return nil }
        sessionId = bytes[1..<5].reduce(0) { $0 << 8 | UInt32($1) }
        self.status = status
        result = Data(body.dropFirst(7))
    }

    public var text: String {
        var bytes = Data(capacity: 11 + result.count)
        bytes.append(OpticalResponse.type)
        bytes.append(bigEndian: sessionId)
        bytes.append(UInt8(status.rawValue >> 8))
        bytes.append(UInt8(status.rawValue & 0xFF))
        bytes.append(result)
        bytes.append(bigEndian: CRC32.checksum(bytes))
        return Base32Crockford.encode(bytes)
    }

    /// The text in groups of five, for reading out or typing.
    public var groupedText: String {
        let characters = Array(text)
        return stride(from: 0, to: characters.count, by: 5)
            .map { String(characters[$0..<min($0 + 5, characters.count)]) }
            .joined(separator: " ")
    }
}
