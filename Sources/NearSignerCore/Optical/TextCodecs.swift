import Foundation

/// Base45 (RFC 9285): two bytes become three characters of the QR alphanumeric set, so a QR code
/// holds the bytes in its densest text mode. The request frames of the camera transfer use it.
public enum Base45 {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:")
    private static let values: [Character: Int] = {
        var map: [Character: Int] = [:]
        for (index, character) in alphabet.enumerated() { map[character] = index }
        return map
    }()

    public static func encode(_ data: Data) -> String {
        var text = ""
        text.reserveCapacity((data.count + 1) / 2 * 3)
        let bytes = [UInt8](data)
        var index = 0
        while index + 1 < bytes.count {
            let value = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            text.append(alphabet[value % 45])
            text.append(alphabet[value / 45 % 45])
            text.append(alphabet[value / 45 / 45])
            index += 2
        }
        if index < bytes.count {
            let value = Int(bytes[index])
            text.append(alphabet[value % 45])
            text.append(alphabet[value / 45])
        }
        return text
    }

    /// Nil for characters outside the alphabet, a length of 3n + 1, or a group above 65 535 (255
    /// for the final pair).
    public static func decode(_ text: String) -> Data? {
        let characters = Array(text)
        guard characters.count % 3 != 1 else { return nil }
        var data = Data(capacity: characters.count / 3 * 2 + 1)
        var index = 0
        while index < characters.count {
            let remaining = characters.count - index
            guard let c = values[characters[index]], let d = values[characters[index + 1]] else { return nil }
            if remaining >= 3 {
                guard let e = values[characters[index + 2]] else { return nil }
                let value = c + d * 45 + e * 45 * 45
                guard value <= 0xFFFF else { return nil }
                data.append(UInt8(value >> 8))
                data.append(UInt8(value & 0xFF))
                index += 3
            } else {
                let value = c + d * 45
                guard value <= 0xFF else { return nil }
                data.append(UInt8(value))
                index += 2
            }
        }
        return data
    }
}

/// Crockford's base32: the response of the camera transfer is shown in it, because a person may
/// have to type it. Encoding is uppercase without padding; decoding forgives case, spaces,
/// hyphens, and the look-alikes `I`, `L` (1) and `O` (0).
public enum Base32Crockford {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let values: [Character: Int] = {
        var map: [Character: Int] = [:]
        for (index, character) in alphabet.enumerated() { map[character] = index }
        map["I"] = 1
        map["L"] = 1
        map["O"] = 0
        return map
    }()

    public static func encode(_ data: Data) -> String {
        var text = ""
        text.reserveCapacity((data.count * 8 + 4) / 5)
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = buffer << 8 | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                text.append(alphabet[buffer >> bits & 0x1F])
            }
        }
        if bits > 0 {
            text.append(alphabet[buffer << (5 - bits) & 0x1F])
        }
        return text
    }

    /// Nil for any other character, or when the characters don't end on a byte boundary with
    /// zero padding bits (a typo in the last character).
    public static func decode(_ text: String) -> Data? {
        var data = Data(capacity: text.count * 5 / 8)
        var buffer = 0
        var bits = 0
        for character in text.uppercased() {
            if character == " " || character == "-" { continue }
            guard let value = values[character] else { return nil }
            buffer = buffer << 5 | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                data.append(UInt8(buffer >> bits & 0xFF))
            }
            buffer &= (1 << bits) - 1
        }
        guard bits < 5, buffer == 0 else { return nil }
        return data
    }
}

/// CRC-32 (IEEE 802.3, the one zlib and PNG use).
public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
