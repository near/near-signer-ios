import Foundation

/// ISO 7816 APDU: short `CLA INS P1 P2 [Lc data]`, or extended `CLA INS P1 P2 00 Lc_hi Lc_lo data`
/// for more than 255 data bytes. Ledger devices accept short APDUs only; extended ones are used by
/// hosts that found NEAR Signer's fast mode (see `SignerCapabilities`).
public struct APDUCommand: Equatable, Sendable {
    public var cla: UInt8
    public var ins: UInt8
    public var p1: UInt8
    public var p2: UInt8
    public var data: Data

    public init(cla: UInt8, ins: UInt8, p1: UInt8, p2: UInt8, data: Data = Data()) {
        self.cla = cla
        self.ins = ins
        self.p1 = p1
        self.p2 = p2
        self.data = data
    }

    public init?(_ bytes: Data) {
        let bytes = [UInt8](bytes)
        guard bytes.count >= 4 else { return nil }
        cla = bytes[0]
        ins = bytes[1]
        p1 = bytes[2]
        p2 = bytes[3]
        if bytes.count == 4 {
            data = Data()
        } else if bytes.count >= 7, bytes[4] == 0, Int(bytes[5]) << 8 | Int(bytes[6]) == bytes.count - 7 {
            // A short APDU with Lc = 0 is exactly 5 bytes, so this cannot be confused with one.
            data = Data(bytes[7...])
        } else {
            let length = Int(bytes[4])
            guard bytes.count == 5 + length else { return nil }
            data = Data(bytes[5...])
        }
    }

    /// Short encoding up to 255 data bytes, extended above.
    public var serialized: Data {
        if data.count <= 255 {
            return Data([cla, ins, p1, p2, UInt8(data.count)]) + data
        }
        return Data([cla, ins, p1, p2, 0, UInt8(data.count >> 8), UInt8(data.count & 0xFF)]) + data
    }
}

/// Status words. Values match the NEAR Ledger app (LedgerHQ/app-near) and BOLOS where possible,
/// so existing host software reports sensible errors.
public enum StatusWord: UInt16, Error, Sendable, CustomStringConvertible {
    case ok = 0x9000
    case userRejected = 0x6985
    case wrongLength = 0x6700
    case wrongP1P2 = 0x6A86
    case insNotSupported = 0x6D00
    case claNotSupported = 0x6E00
    case invalidData = 0x6A80
    /// No key configured or the key could not be unlocked (BOLOS "locked device").
    case locked = 0x5515
    case parseFailed = 0xB005
    case badPath = 0xB00B
    case publicKeyMismatch = 0xB00D
    case busy = 0x6601

    public var bytes: Data { Data([UInt8(rawValue >> 8), UInt8(rawValue & 0xFF)]) }

    public var description: String {
        switch self {
        case .ok: return "OK"
        case .userRejected: return "rejected by user"
        case .wrongLength: return "wrong length"
        case .wrongP1P2: return "wrong P1/P2"
        case .insNotSupported: return "instruction not supported"
        case .claNotSupported: return "class not supported"
        case .invalidData: return "invalid data"
        case .locked: return "signer locked or no key"
        case .parseFailed: return "could not decode payload"
        case .badPath: return "unsupported derivation path"
        case .publicKeyMismatch: return "public key does not match this signer"
        case .busy: return "another request is pending"
        }
    }
}

public enum NearAPDU {
    public static let cla: UInt8 = 0x80
    public static let insSignTransaction: UInt8 = 0x02
    public static let insGetPublicKey: UInt8 = 0x04
    public static let insGetWalletId: UInt8 = 0x05
    public static let insGetVersion: UInt8 = 0x06
    public static let insSignNep413: UInt8 = 0x07
    public static let insSignNep366: UInt8 = 0x08
    /// NEAR Signer only: reports `SignerCapabilities`. A Ledger answers `6D00`.
    public static let insGetCapabilities: UInt8 = 0x20

    public static let p1More: UInt8 = 0x00
    public static let p1Last: UInt8 = 0x80
    public static let p1GetPublicKeyDisplay: UInt8 = 0x00
    public static let p1GetPublicKeySilent: UInt8 = 0x01
    public static let networkMainnet = UInt8(ascii: "W")

    /// BOLOS dashboard commands sent by near-ledger-rs and the near-connect Ledger executor.
    public static let claDashboard: UInt8 = 0xB0
    public static let insGetAppName: UInt8 = 0x01
    public static let insQuitApp: UInt8 = 0xA7
    public static let claOpenApp: UInt8 = 0xE0
    public static let insOpenApp: UInt8 = 0xD8

    /// The NEAR Ledger app requires exactly 5 path components (20 bytes).
    public static let pathLength = 20
    /// Upper bound for one chunked payload. Large contract deployments need more than a BLE
    /// round-trip budget allows, but 1.5 MiB covers NEAR's 1.5 MiB contract size limit.
    public static let maxPayload = 1_600_000
    /// Version reported to hosts. Hosts gate features on the Ledger NEAR app version,
    /// so report the newest app version whose APDUs this signer implements.
    public static let reportedAppVersion: [UInt8] = [2, 4, 3]

    /// Largest data field of one extended APDU: a Ledger BLE frame carries at most 0xFFFF bytes,
    /// 7 of them APDU header.
    public static let maxExtendedChunk = 0xFFFF - 7

    public static func getCapabilities() -> APDUCommand {
        APDUCommand(cla: cla, ins: insGetCapabilities, p1: 0, p2: 0)
    }

    public static func getVersion() -> APDUCommand {
        APDUCommand(cla: cla, ins: insGetVersion, p1: 0, p2: 0)
    }

    public static func getPublicKey(path: BIP32Path, display: Bool) -> APDUCommand {
        APDUCommand(cla: cla, ins: insGetPublicKey, p1: display ? p1GetPublicKeyDisplay : p1GetPublicKeySilent,
                    p2: networkMainnet, data: path.serialized)
    }

    /// Splits `path || payload` into chunks with P1 = 0x80 on the last one. Chunks over 255 bytes
    /// serialize as extended APDUs (fast mode).
    public static func signCommands(ins: UInt8, path: BIP32Path, payload: Data, chunkSize: Int = 250) -> [APDUCommand] {
        let all = path.serialized + payload
        var commands: [APDUCommand] = []
        var offset = 0
        while offset < all.count {
            let end = min(offset + chunkSize, all.count)
            commands.append(APDUCommand(cla: cla, ins: ins, p1: end == all.count ? p1Last : p1More,
                                        p2: networkMainnet, data: Data(all[offset..<end])))
            offset = end
        }
        return commands
    }
}
