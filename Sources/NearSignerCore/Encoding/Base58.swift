import Foundation

/// Bitcoin-alphabet Base58, as used by NEAR for keys, signatures and hashes.
public enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
    private static let decodeTable: [Int8] = {
        var table = [Int8](repeating: -1, count: 128)
        for (index, character) in alphabet.enumerated() {
            table[Int(character)] = Int8(index)
        }
        return table
    }()

    public static func encode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        let zeros = bytes.prefix(while: { $0 == 0 }).count
        // log(256) / log(58) ≈ 1.37
        var digits = [UInt8](repeating: 0, count: bytes.count * 138 / 100 + 1)
        var length = 0
        for byte in bytes[zeros...] {
            var carry = Int(byte)
            var index = 0
            var position = digits.count - 1
            while carry != 0 || index < length {
                carry += 256 * Int(digits[position])
                digits[position] = UInt8(carry % 58)
                carry /= 58
                index += 1
                position -= 1
            }
            length = index
        }
        let significant = digits.suffix(length)
        return String(repeating: "1", count: zeros)
            + String(decoding: significant.map { alphabet[Int($0)] }, as: UTF8.self)
    }

    /// Longest accepted input: decoding is quadratic, and the largest value this signer handles
    /// (an ML-DSA-65 public key, 1,952 bytes) is about 2,700 characters.
    public static let maxDecodeLength = 4096

    public static func decode(_ string: String) -> Data? {
        guard string.utf8.count <= maxDecodeLength else { return nil }
        let characters = Array(string.utf8)
        let zeros = characters.prefix(while: { $0 == UInt8(ascii: "1") }).count
        var bytes = [UInt8](repeating: 0, count: characters.count * 733 / 1000 + 1)
        var length = 0
        for character in characters[zeros...] {
            guard character < 128 else { return nil }
            let value = decodeTable[Int(character)]
            guard value >= 0 else { return nil }
            var carry = Int(value)
            var index = 0
            var position = bytes.count - 1
            while carry != 0 || index < length {
                carry += 58 * Int(bytes[position])
                bytes[position] = UInt8(carry % 256)
                carry /= 256
                index += 1
                position -= 1
            }
            length = index
        }
        return Data(repeating: 0, count: zeros) + Data(bytes.suffix(length))
    }
}

public extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hexString: String) {
        var string = hexString
        if string.hasPrefix("0x") { string.removeFirst(2) }
        guard string.count % 2 == 0 else { return nil }
        var data = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }

    var base58: String { Base58.encode(self) }
}
