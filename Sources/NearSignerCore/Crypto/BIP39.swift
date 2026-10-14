import Foundation

public enum BIP39Error: Error, Equatable, CustomStringConvertible {
    case invalidWordCount(Int)
    case unknownWord(String)
    case invalidChecksum
    case invalidEntropyLength(Int)

    public var description: String {
        switch self {
        case let .invalidWordCount(count): return "seed phrase must have 12, 15, 18, 21 or 24 words (got \(count))"
        case let .unknownWord(word): return "\"\(word)\" is not a BIP-39 English word"
        case .invalidChecksum: return "seed phrase checksum is invalid"
        case let .invalidEntropyLength(length): return "invalid entropy length \(length)"
        }
    }
}

/// BIP-39 mnemonic generation, validation and seed derivation (English wordlist only).
public enum BIP39 {
    private static let wordIndex: [String: Int] = {
        var index: [String: Int] = [:]
        for (position, word) in englishWords.enumerated() { index[word] = position }
        return index
    }()

    public static func normalize(_ phrase: String) -> [String] {
        phrase.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    public static func isWord(_ word: String) -> Bool { wordIndex[word] != nil }

    public static func mnemonic(fromEntropy entropy: Data) throws -> [String] {
        guard [16, 20, 24, 28, 32].contains(entropy.count) else {
            throw BIP39Error.invalidEntropyLength(entropy.count)
        }
        let checksumBits = entropy.count / 4
        let hash = Data(SHA256.hash(data: entropy))
        var bits: [Bool] = []
        for byte in entropy { bits.append(contentsOf: byteBits(byte)) }
        bits.append(contentsOf: byteBits(hash[0]).prefix(checksumBits))
        return stride(from: 0, to: bits.count, by: 11).map { start in
            var index = 0
            for bit in bits[start..<(start + 11)] { index = index << 1 | (bit ? 1 : 0) }
            return englishWords[index]
        }
    }

    /// A new phrase from the system's cryptographically secure generator (`SecureRandom`): 256 bits
    /// of entropy for 24 words. The phrase is decoded again and must give back the same entropy.
    public static func generateMnemonic(wordCount: Int = 24) throws -> [String] {
        guard [12, 15, 18, 21, 24].contains(wordCount) else { throw BIP39Error.invalidWordCount(wordCount) }
        var entropy = try SecureRandom.bytes(wordCount * 11 * 32 / 33 / 8)
        defer { entropy.resetBytes(in: 0..<entropy.count) }
        let words = try mnemonic(fromEntropy: entropy)
        guard try validate(words) == entropy else { throw BIP39Error.invalidChecksum }
        return words
    }

    /// Checks word membership and the checksum. Returns the entropy.
    @discardableResult
    public static func validate(_ words: [String]) throws -> Data {
        guard [12, 15, 18, 21, 24].contains(words.count) else {
            throw BIP39Error.invalidWordCount(words.count)
        }
        var bits: [Bool] = []
        for word in words {
            guard let index = wordIndex[word] else { throw BIP39Error.unknownWord(word) }
            for shift in (0..<11).reversed() { bits.append((index >> shift) & 1 == 1) }
        }
        let checksumBits = words.count * 11 / 33
        let entropyBits = bits.count - checksumBits
        var entropy = Data()
        for start in stride(from: 0, to: entropyBits, by: 8) {
            var byte: UInt8 = 0
            for bit in bits[start..<(start + 8)] { byte = byte << 1 | (bit ? 1 : 0) }
            entropy.append(byte)
        }
        let hash = Data(SHA256.hash(data: entropy))
        let expected = byteBits(hash[0]).prefix(checksumBits)
        guard Array(bits[entropyBits...]) == Array(expected) else { throw BIP39Error.invalidChecksum }
        return entropy
    }

    /// PBKDF2-HMAC-SHA512(mnemonic, "mnemonic" + passphrase, 2048 iterations, 64 bytes).
    public static func seed(from words: [String], passphrase: String = "") -> Data {
        let password = Data(words.joined(separator: " ").decomposedStringWithCompatibilityMapping.utf8)
        let salt = Data(("mnemonic" + passphrase).decomposedStringWithCompatibilityMapping.utf8)
        return pbkdf2SHA512(password: password, salt: salt, iterations: 2048, keyLength: 64)
    }

    static func pbkdf2SHA512(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        let key = SymmetricKey(data: password)
        var derived = Data()
        var blockIndex: UInt32 = 1
        while derived.count < keyLength {
            var blockSalt = salt
            withUnsafeBytes(of: blockIndex.bigEndian) { blockSalt.append(contentsOf: $0) }
            var u = Data(HMAC<SHA512>.authenticationCode(for: blockSalt, using: key))
            var block = [UInt8](u)
            for _ in 1..<iterations {
                u = Data(HMAC<SHA512>.authenticationCode(for: u, using: key))
                for (index, byte) in u.enumerated() { block[index] ^= byte }
            }
            derived.append(contentsOf: block)
            blockIndex += 1
        }
        return derived.prefix(keyLength)
    }

    private static func byteBits(_ byte: UInt8) -> [Bool] {
        (0..<8).reversed().map { (byte >> $0) & 1 == 1 }
    }
}
