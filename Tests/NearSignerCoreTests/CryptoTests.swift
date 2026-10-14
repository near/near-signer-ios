import Foundation
import XCTest
@testable import NearSignerCore

final class CryptoTests: XCTestCase {
    func testSeedPhraseDerivationMatchesNearSeedPhrase() throws {
        let material = try KeyMaterial.fromMnemonic(Fixtures.phrase)
        let ledgerKey = try material.privateKey(for: XCTUnwrap(BIP32Path(Fixtures.ledgerPath)))
        XCTAssertEqual(ledgerKey.publicKey.nearString, Fixtures.ledgerPublicKey)
        let cliKey = try material.privateKey(for: XCTUnwrap(BIP32Path(Fixtures.cliPath)))
        XCTAssertEqual(cliKey.publicKey.nearString, Fixtures.cliPublicKey)
    }

    func testNearSecretKeyImport() throws {
        let material = try KeyMaterial.fromNearSecretKey(Fixtures.ledgerSecretKey)
        XCTAssertFalse(material.derivesFromPath)
        let key = try material.privateKey(for: .ledgerDefault)
        XCTAssertEqual(key.publicKey.nearString, Fixtures.ledgerPublicKey)
        XCTAssertThrowsError(try KeyMaterial.fromNearSecretKey("secp256k1:abc"))
        // 64-byte key whose public half belongs to a different key.
        let ledger = Base58.decode(String(Fixtures.ledgerSecretKey.dropFirst(8)))!
        let cli = Base58.decode(String(Fixtures.cliSecretKey.dropFirst(8)))!
        let mixed = "ed25519:" + Base58.encode(ledger.prefix(32) + cli.suffix(32))
        XCTAssertThrowsError(try KeyMaterial.fromNearSecretKey(mixed))
    }

    func testKeyMaterialSerializationRoundTrip() throws {
        let seed = try KeyMaterial.fromMnemonic(Fixtures.phrase)
        XCTAssertEqual(try KeyMaterial(serialized: seed.serialized), seed)
        let single = try KeyMaterial.fromNearSecretKey(Fixtures.ledgerSecretKey)
        XCTAssertEqual(try KeyMaterial(serialized: single.serialized), single)
        XCTAssertThrowsError(try KeyMaterial(serialized: Data([9, 1, 2])))
    }

    /// SLIP-0010 test vector 1 for ed25519.
    func testSLIP10Vector() throws {
        let seed = Data(hexString: "000102030405060708090a0b0c0d0e0f")!
        XCTAssertEqual(try SLIP10.derive(seed: seed, path: BIP32Path(hardened: [0])).hexString,
                       "68e0fe46dfb67e368c75379acec591dad19df3cde26e63b93a8e704f1dade7a3")
        XCTAssertEqual(try SLIP10.derive(seed: seed, path: BIP32Path(hardened: [0, 1, 2, 2, 1_000_000_000])).hexString,
                       "8f94d394a8e8fd6b1bc2f3f49f5c47e385281d5c17e65324b0f62483e37e8793")
        XCTAssertThrowsError(try SLIP10.derive(seed: seed, path: BIP32Path(components: [0])))
    }

    /// Trezor BIP-39 reference vector (passphrase "TREZOR").
    func testBIP39Vector() throws {
        let words = try BIP39.mnemonic(fromEntropy: Data(repeating: 0, count: 16))
        XCTAssertEqual(words.joined(separator: " "), Fixtures.phrase)
        XCTAssertEqual(BIP39.seed(from: words, passphrase: "TREZOR").hexString,
                       "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04")
        let entropy = Data(repeating: 0x7f, count: 32)
        let phrase = try BIP39.mnemonic(fromEntropy: entropy)
        XCTAssertEqual(phrase.count, 24)
        XCTAssertEqual(try BIP39.validate(phrase), entropy)
    }

    /// More Trezor reference vectors (passphrase "TREZOR"); recomputed independently with Python's
    /// hashlib as well.
    func testBIP39MoreVectors() throws {
        let letter = try BIP39.mnemonic(fromEntropy: Data(repeating: 0x80, count: 32))
        XCTAssertEqual(letter.joined(separator: " "),
                       "letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic bless")
        XCTAssertEqual(BIP39.seed(from: letter, passphrase: "TREZOR").hexString,
                       "c0c519bd0e91a2ed54357d9d1ebef6f5af218a153624cf4f2da911a0ed8f7a09e2ef61af0aca007096df430022f7a2b6fb91661a9589097069720d015e4e982f")
        let zoo = try BIP39.mnemonic(fromEntropy: Data(repeating: 0xff, count: 32))
        XCTAssertEqual(zoo.joined(separator: " "), Array(repeating: "zoo", count: 23).joined(separator: " ") + " vote")
        XCTAssertEqual(BIP39.seed(from: zoo, passphrase: "TREZOR").hexString,
                       "dd48c104698c30cfe2b6142103248622fb7bb0ff692eebb00089b32d22484e1613912f0a5b694407be899ffd31ed3992c456cdf60f5d4564b8ba3f05a69890ad")
    }

    /// The core's BIP-39 passphrase support (the app doesn't offer a passphrase) is normalized as
    /// BIP-39 requires (NFKD) and changes every key. The expected key was computed independently in Python (hashlib PBKDF2 + SLIP-10).
    func testPassphrase() throws {
        let composed = "Ünïcödé ㍍ガバヴァ"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(composed.unicodeScalars), Array(decomposed.unicodeScalars))
        let material = try KeyMaterial.fromMnemonic(Fixtures.phrase, passphrase: composed)
        XCTAssertEqual(material, try KeyMaterial.fromMnemonic(Fixtures.phrase, passphrase: decomposed))
        XCTAssertEqual(try material.privateKey(for: .ledgerDefault).rawRepresentation.hexString,
                       "d771dcb552abb0c4ebe6af2d185af4c85f5326226e990aed8e9ca6797673f134")
        let plain = try KeyMaterial.fromMnemonic(Fixtures.phrase)
        XCTAssertNotEqual(try plain.privateKey(for: .ledgerDefault).rawRepresentation,
                          try material.privateKey(for: .ledgerDefault).rawRepresentation)
        // Spaces count: "TREZOR " is a different wallet.
        let words = BIP39.normalize(Fixtures.phrase)
        XCTAssertNotEqual(BIP39.seed(from: words, passphrase: "TREZOR"), BIP39.seed(from: words, passphrase: "TREZOR "))
    }

    /// New phrases come from the system CSPRNG; output only a broken generator produces is refused.
    func testSecureRandomAndGeneration() throws {
        XCTAssertThrowsError(try SecureRandom.bytes(32) { Data(repeating: 0, count: $0) }) {
            XCTAssertEqual($0 as? SecureRandomError, .failedHealthCheck)
        }
        let fixed = Data((0..<32).map { UInt8($0) })
        XCTAssertThrowsError(try SecureRandom.bytes(32) { _ in fixed }, "the same output twice")
        XCTAssertThrowsError(try SecureRandom.bytes(32) { _ in Data(count: 31) }, "short output")
        let first = try SecureRandom.bytes(32)
        XCTAssertEqual(first.count, 32)
        XCTAssertNotEqual(first, try SecureRandom.bytes(32))

        // 200 phrases: all different, 256 bits each, and the bits balanced (a sanity check, not a
        // proof of randomness: 51,200 bits, mean 25,600, standard deviation about 113, 10σ bounds).
        var seen = Set<String>()
        var ones = 0
        for _ in 0..<200 {
            let words = try BIP39.generateMnemonic()
            XCTAssertEqual(words.count, 24)
            XCTAssertTrue(seen.insert(words.joined(separator: " ")).inserted)
            let entropy = try BIP39.validate(words)
            XCTAssertEqual(entropy.count, 32)
            ones += entropy.reduce(0) { $0 + $1.nonzeroBitCount }
        }
        XCTAssertTrue((24_470...26_730).contains(ones), "\(ones) one bits")
        XCTAssertThrowsError(try BIP39.generateMnemonic(wordCount: 13))
    }

    func testBIP39Validation() throws {
        XCTAssertThrowsError(try BIP39.validate(BIP39.normalize("abandon abandon"))) {
            XCTAssertEqual($0 as? BIP39Error, .invalidWordCount(2))
        }
        var words = BIP39.normalize(Fixtures.phrase)
        words[11] = "abandon"
        XCTAssertThrowsError(try BIP39.validate(words)) { XCTAssertEqual($0 as? BIP39Error, .invalidChecksum) }
        words[11] = "notaword"
        XCTAssertThrowsError(try BIP39.validate(words)) { XCTAssertEqual($0 as? BIP39Error, .unknownWord("notaword")) }
        XCTAssertEqual(try BIP39.generateMnemonic(wordCount: 24).count, 24)
        XCTAssertEqual(try BIP39.generateMnemonic(wordCount: 12).count, 12)
        XCTAssertNoThrow(try BIP39.validate(BIP39.normalize("  ABANDON abandon abandon abandon abandon abandon\nabandon abandon abandon abandon abandon about ")))
    }

    func testBIP32PathParsing() throws {
        XCTAssertEqual(BIP32Path("m/44'/397'/0'/0'/1'"), .ledgerDefault)
        XCTAssertEqual(BIP32Path("44h/397h/0h"), .nearCliSeedPhraseDefault)
        XCTAssertEqual(BIP32Path.ledgerDefault.description, "m/44'/397'/0'/0'/1'")
        XCTAssertEqual(BIP32Path.ledgerDefault.serialized.hexString, "8000002c8000018d800000008000000080000001")
        XCTAssertEqual(BIP32Path(serialized: BIP32Path.ledgerDefault.serialized), .ledgerDefault)
        XCTAssertNil(BIP32Path("m/abc"))
        XCTAssertNil(BIP32Path("m/2147483648"))
    }

    func testBase58() {
        XCTAssertEqual(Base58.encode(Data()), "")
        XCTAssertEqual(Base58.encode(Data([0, 0, 1])), "112")
        XCTAssertEqual(Base58.encode(Data("hello world".utf8)), "StV1DL6CwTryKyV")
        XCTAssertEqual(Base58.decode("StV1DL6CwTryKyV"), Data("hello world".utf8))
        XCTAssertEqual(Base58.decode("112"), Data([0, 0, 1]))
        XCTAssertNil(Base58.decode("0OIl"))
        for length in [1, 31, 32, 64] {
            let data = Data((0..<length).map { UInt8(($0 * 37 + 11) % 256) })
            XCTAssertEqual(Base58.decode(Base58.encode(data)), data)
        }
    }

    func testU128() {
        let max = "340282366920938463463374607431768211455"
        XCTAssertEqual(U128(decimal: max)?.description, max)
        XCTAssertNil(U128(decimal: "340282366920938463463374607431768211456"))
        XCTAssertNil(U128(decimal: "12a"))
        XCTAssertEqual(U128(decimal: "1000000000000000000000000")?.description, "1000000000000000000000000")
        XCTAssertEqual(U128.zero.description, "0")
        XCTAssertLessThan(U128(5), U128(high: 1, low: 0))
    }

    func testAmountFormatting() {
        XCTAssertEqual(NearFormat.near(U128(decimal: "1500000000000000000000000")!), "1.5 NEAR")
        XCTAssertEqual(NearFormat.near(U128(1)), "1 yoctoNEAR")
        XCTAssertEqual(NearFormat.near(U128(2)), "0.000000000000000000000002 NEAR")
        XCTAssertEqual(NearFormat.near(.zero), "0 NEAR")
        XCTAssertEqual(NearFormat.near(U128(decimal: "123000000000000000000000000000")!), "123000 NEAR")
        XCTAssertEqual(NearFormat.gas(30_000_000_000_000), "30 Tgas")
        XCTAssertEqual(NearFormat.gas(1), "0.000000000001 Tgas")
        XCTAssertEqual(NearFormat.gas(2_500_000_000_000), "2.5 Tgas")
    }
}
