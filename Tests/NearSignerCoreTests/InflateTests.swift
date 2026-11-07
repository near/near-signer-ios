import Foundation
import XCTest
@testable import NearSignerCore

/// Raw DEFLATE decoding of compressed camera-transfer payloads (README "Camera transfer").
/// Vectors come from Python's zlib at raw level: `zlib.compressobj(9, zlib.DEFLATED, -15)`.
final class InflateTests: XCTestCase {
    private let key = try! KeyMaterial.fromMnemonic(Fixtures.phrase)

    private func hex(_ text: String) -> Data {
        var bytes = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            bytes.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }

    /// Writes a DEFLATE stream by hand: bits least significant first, Huffman codes most
    /// significant first, as the format packs them.
    private struct BitWriter {
        var bytes: [UInt8] = []
        private var accumulator = 0
        private var count = 0

        mutating func bits(_ value: Int, _ width: Int) {
            for bit in 0..<width {
                accumulator |= ((value >> bit) & 1) << count
                count += 1
                if count == 8 {
                    bytes.append(UInt8(accumulator))
                    accumulator = 0
                    count = 0
                }
            }
        }

        mutating func code(_ value: Int, _ width: Int) {
            for bit in stride(from: width - 1, through: 0, by: -1) { bits((value >> bit) & 1, 1) }
        }

        /// A fixed-Huffman literal.
        mutating func literal(_ byte: UInt8) {
            byte < 144 ? code(0x30 + Int(byte), 8) : code(0x190 + Int(byte) - 144, 9)
        }

        mutating func finish() -> Data {
            if count > 0 { bytes.append(UInt8(accumulator)) }
            return Data(bytes)
        }
    }

    // MARK: Vectors

    func testFixedHuffmanVector() throws {
        XCTAssertEqual(try Inflate.inflate(hex("cb48cdc9c957c8c04e2a0200"), expectedLength: 30),
                       Data("hello hello hello hello hello!".utf8))
    }

    func testEmptyStreamAndNoInput() throws {
        XCTAssertEqual(try Inflate.inflate(hex("0300"), expectedLength: 0), Data())
        XCTAssertThrowsError(try Inflate.inflate(Data(), expectedLength: 0)) { error in
            XCTAssertEqual(error as? Inflate.Error, .truncated)
        }
        XCTAssertThrowsError(try Inflate.inflate(hex("0300"), expectedLength: 1)) { error in
            XCTAssertEqual(error as? Inflate.Error, .lengthMismatch, "ends short")
        }
    }

    func testStoredBlock() throws {
        let stored = hex("0164009bff000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60616263")
        XCTAssertEqual(try Inflate.inflate(stored, expectedLength: 100), Data((0..<100).map { UInt8($0) }))
        XCTAssertThrowsError(try Inflate.inflate(stored, expectedLength: 99)) { error in
            XCTAssertEqual(error as? Inflate.Error, .lengthMismatch)
        }
        XCTAssertThrowsError(try Inflate.inflate(stored.prefix(50), expectedLength: 100)) { error in
            XCTAssertEqual(error as? Inflate.Error, .truncated)
        }
        // LEN and NLEN disagree.
        var corrupt = stored
        corrupt[3] ^= 0x01
        XCTAssertThrowsError(try Inflate.inflate(corrupt, expectedLength: 100)) { error in
            XCTAssertEqual(error as? Inflate.Error, .invalidData)
        }
    }

    /// 512 generator bytes repeated 100 times, one byte changed per repeat: 51 200 bytes that
    /// zlib packs into 1 261 with dynamic Huffman codes and long matches.
    private func repetitiveData() -> Data {
        var x: UInt32 = 12345
        var base: [UInt8] = []
        for _ in 0..<512 {
            x = (x &* 1_103_515_245 &+ 12345) & 0x7FFF_FFFF
            base.append(UInt8((x >> 16) & 0xFF))
        }
        var data: [UInt8] = []
        for round in 0..<100 {
            var block = base
            block[(round * 7) % 512] ^= UInt8(round & 0xFF)
            data += block
        }
        return Data(data)
    }

    func testDynamicHuffmanVector() throws {
        let compressed = hex(""
            + "eddcfd53137400c7f1c2158328d9060b1c205d5e070868ebe241252e1d4486440f1ec8d2e1b8054eb1a5f3044484d3db"
            + "c01b0881804b3de1f200dd021c02370c0df00866e010c6a1b0112128dc698283413cf483df3fa1dfbe9fbfe175ef5fdf"
            + "c30cc9b5f55acf84878f353c2f1147967e68d979d5bd36d193a169f0b4db18997674cb8c45f46b13738ff159a8b321ea"
            + "fccd7b79beacd5371bc581966d0b1f2f7f51e2d3ed9029d0d9ed2b15e9a65235fd0139870fd48e4e28a32f3226fb82f6"
            + "fa27764dbd4c9f535c992efe605ccc1e78dba03bee2a956e49d1173c9233232fcff6e81c6df747525a6ca2c50d337d4b"
            + "6eca7fbf53ea1b42f8577fe6853967cea7994e8da5da5845be59c5e70decbb713d092ffab96e83eeb718c2ac0b921795"
            + "253f76f869a435211dc73ab5fc10bbf56f6cf5bfb06e69dad5dc9ba21fcdbc65f22ae3a9dfbad45a96f4e0a7a55a4ba5"
            + "aaecfd08f1f488bd44b61a9f27ed9def7e16eef174dc31e5b1b9383fe4e2c9df06850efd93631f09c277aa3a2a0a4dcd"
            + "cdc3fb45c6029fd63def5c8be5c59e9506f94ec82cbb8feb8705a93b5a6a98ef9aeecc9d60ee970d0574b18f083764b5"
            + "8d3dacbfc1b8ec9d2d0f56ff50e83412b8ef88d521aa31de58f6b45d557ff8c1085b20e63bb954d5862f3a994d9c1e8e"
            + "c21077e5b37161ab31a221682077a5efb54f6794f56b4f8be412bd4f24f76b4b6e2567e8f6f6e74dac9b66fb535de9fa"
            + "bfabe377d63c09a8de157b69a2fce0588dbaf7bde8effd540385ace0f2e4bc16edec57f91cadd5a3e2f5124ddd9943d6"
            + "b356bf8c22ebecf54d0abe3e27c23bac3dd92537e358e11f499df6a35e6db2356ae3f02b7f21fca9f627fdb3e04fb53f"
            + "e97f1dfca9f627fdbbc39f6a7fd2ff3cfca9f627fd0fc29f6a7fd2ff0df853ed4ffa6f853fd5fea4ff97f0a7da9ff41f"
            + "037faafd49ff7fc19f6a7fd2bf04fe54fb93fe1de04fb53fe9bf13fe54fb93fec7e14fb53fe9df13fe54fb93fe37c29f"
            + "6a7fd2ffb7f0a7da9ff4df0e7faafd49ff9be14fb53fe9ff73f853ed4ffacf873fd5fea4ffdfe14fb53fe9ff43f853ed"
            + "4ffa8f813fd5fea4ff3fe14fb53fe93f0bfe54fb93feebe04fb53fe9bf0efe54fb93fef9f0a7da9ff47f1ffe54fb93fe"
            + "3f813fd5fea4ff46f853ed4ffacf863fd5fea4ff15f853ed4ffa8f813fd5fea4ff7bf0c7ffcb5c7c1dfef87f0d0a03e1"
            + "8fff97205c0c7ffcbf4ccd45f0c7ffabc0a704fef87ff1622be08fff97cc920e7ffcbf527794c21fffaf3b73bbe18fff"
            + "57405718fcf1ff6a1b9b823ffe5fded911f0c7ffcb69c403fef87f45351e843ffe5faafa04f8e3ff25e687c21fffaf45"
            + "a727f0c7ff4b6148843ffe5fadc693f0c7ff6ba52f14fef87fad3d2d813ffe5f91dc03f0c7ff6be87616fcf1ff32db6f"
            + "873ffe5fd5f172f8e3ffb52bb612fef87fd5a8cfc11fff2fd58011fef87fe5b53c873ffe5f5aab08fef87fd59df1813f"
            + "fe5f194575f0c7ff8bafef843ffe5fc92ebdf0c7ff2ba9f34bf8e3ffb5465dfeca3f0efef83ff1bc5ce08fffd3b2b30e"
            + "fef83f31340bf0c7ff29eda81cfef83f3531b9f0c7ffc9107517fef83fb156e3e08fffd3b68564f8e3ffd4edb009fef8"
            + "3f958a26e18fff5340ce56f8e3ffa48cee863ffe4f7bfd83e18fffd39cc2067ffc9fc46c15fcf17f72956e863ffe4f8f"
            + "e4dfc01fff279de32ff0c7ffc926aa823ffe4f6ecaabf0c7ff2984bf087ffc9f32e7dde08fff938df50ffcf17f32b0ab"
            + "e08fff533ff704fcff2fffff00"
        )
        XCTAssertEqual(compressed.count, 1261)
        XCTAssertEqual(compressed[0] & 0x07, 0b101, "final block, dynamic Huffman")
        let expected = repetitiveData()
        XCTAssertEqual(CRC32.checksum(expected), 0x0316_D7FE)
        XCTAssertEqual(try Inflate.inflate(compressed, expectedLength: 51200), expected)

        XCTAssertThrowsError(try Inflate.inflate(compressed.prefix(700), expectedLength: 51200)) { error in
            XCTAssertEqual(error as? Inflate.Error, .truncated)
        }
        XCTAssertThrowsError(try Inflate.inflate(compressed, expectedLength: 51199)) { error in
            XCTAssertEqual(error as? Inflate.Error, .lengthMismatch, "one byte more than declared")
        }
        XCTAssertThrowsError(try Inflate.inflate(compressed, expectedLength: 60000)) { error in
            XCTAssertEqual(error as? Inflate.Error, .lengthMismatch, "ends short")
        }
        XCTAssertThrowsError(try Inflate.inflate(compressed + Data([0]), expectedLength: 51200)) { error in
            XCTAssertEqual(error as? Inflate.Error, .lengthMismatch, "a byte after the last block")
        }
    }

    func testHandWrittenStreams() throws {
        // "a" then a 3-byte copy from distance 1: "aaaa".
        var writer = BitWriter()
        writer.bits(1, 1) // final
        writer.bits(1, 2) // fixed Huffman
        writer.literal(UInt8(ascii: "a"))
        writer.code(1, 7) // length code 257: 3 bytes
        writer.code(0, 5) // distance code 0: 1 byte back
        writer.code(0, 7) // end of block
        XCTAssertEqual(try Inflate.inflate(writer.finish(), expectedLength: 4), Data("aaaa".utf8))

        // The same copy from distance 5, with one byte of output: nothing there to copy.
        var tooFar = BitWriter()
        tooFar.bits(1, 1)
        tooFar.bits(1, 2)
        tooFar.literal(UInt8(ascii: "a"))
        tooFar.code(1, 7)
        tooFar.code(4, 5) // distance code 4: 5 or 6 back
        tooFar.bits(0, 1) // 5
        tooFar.code(0, 7)
        XCTAssertThrowsError(try Inflate.inflate(tooFar.finish(), expectedLength: 4)) { error in
            XCTAssertEqual(error as? Inflate.Error, .invalidData)
        }

        // Block type 3 doesn't exist.
        var badType = BitWriter()
        badType.bits(1, 1)
        badType.bits(3, 2)
        XCTAssertThrowsError(try Inflate.inflate(badType.finish(), expectedLength: 0)) { error in
            XCTAssertEqual(error as? Inflate.Error, .invalidData)
        }

        // The two spare fixed distance codes (30, 31) are not codes.
        var spareDistance = BitWriter()
        spareDistance.bits(1, 1)
        spareDistance.bits(1, 2)
        spareDistance.literal(UInt8(ascii: "a"))
        spareDistance.code(1, 7)
        spareDistance.code(30, 5)
        spareDistance.code(0, 7)
        XCTAssertThrowsError(try Inflate.inflate(spareDistance.finish(), expectedLength: 4)) { error in
            XCTAssertEqual(error as? Inflate.Error, .invalidData)
        }

        // A dynamic block whose code lengths leave out the end-of-block code.
        var noEnd = BitWriter()
        noEnd.bits(1, 1)
        noEnd.bits(2, 2)
        noEnd.bits(0, 5) // 257 literal/length codes
        noEnd.bits(0, 5) // 1 distance code
        noEnd.bits(0, 4) // 4 code-length codes: for symbols 16, 17, 18, 0
        noEnd.bits(0, 3) // 16: unused
        noEnd.bits(0, 3) // 17: unused
        noEnd.bits(1, 3) // 18: one bit
        noEnd.bits(0, 3) // 0: unused
        // 258 lengths of zero: 18 (code "0") with 127 repeats, twice; 11 + 127 = 138, so 138 + 120.
        noEnd.code(0, 1)
        noEnd.bits(127, 7)
        noEnd.code(0, 1)
        noEnd.bits(109, 7)
        XCTAssertThrowsError(try Inflate.inflate(noEnd.finish(), expectedLength: 0)) { error in
            XCTAssertEqual(error as? Inflate.Error, .invalidData)
        }
    }

    /// Debug builds must still inflate a contract-sized payload quickly: a megabyte of literals
    /// (the slow path, one code per byte) and a megabyte of long copies.
    func testInflatesAMegabyteQuickly() throws {
        var literals = BitWriter()
        literals.bits(1, 1)
        literals.bits(1, 2)
        var x: UInt32 = 7
        var expected: [UInt8] = []
        for _ in 0..<(256 * 1024) {
            x = (x &* 1_103_515_245 &+ 12345) & 0x7FFF_FFFF
            let byte = UInt8((x >> 16) & 0xFF)
            expected.append(byte)
            literals.literal(byte)
        }
        literals.code(0, 7)
        let literalStream = literals.finish()

        // 1 000 literals, then 258-byte copies from 1 000 back: the first kilobyte over and over.
        var copies = BitWriter()
        copies.bits(1, 1)
        copies.bits(1, 2)
        for byte in expected.prefix(1000) { copies.literal(byte) }
        let copyCount = (1024 * 1024 - 1000) / 258
        for _ in 0..<copyCount {
            copies.code(0xC5, 8) // length code 285: 258 bytes
            copies.code(19, 5) // distance code 19: 769 to 1 024 back, 8 extra bits
            copies.bits(1000 - 769, 8)
        }
        copies.code(0, 7)
        let copyStream = copies.finish()
        let copyLength = 1000 + copyCount * 258
        let copyExpected = Data((0..<copyLength).map { expected[$0 % 1000] })

        var start = Date()
        XCTAssertEqual(try Inflate.inflate(literalStream, expectedLength: expected.count), Data(expected))
        let literalSeconds = Date().timeIntervalSince(start)
        start = Date()
        XCTAssertEqual(try Inflate.inflate(copyStream, expectedLength: copyLength), copyExpected)
        let copySeconds = Date().timeIntervalSince(start)
        print("inflate: 256 KB of literals in \(literalSeconds) s, 1 MB of copies in \(copySeconds) s")
        XCTAssertLessThan(literalSeconds + copySeconds, 5)
    }

    // MARK: Requests

    private func transfer(_ sender: OpticalSender) -> Data? {
        let receiver = OpticalReceiver()
        for sequence in 0..<(4 * sender.fragmentCount) {
            if case let .complete(message) = receiver.receive(sender.frame(UInt32(sequence)).text) { return message }
        }
        return nil
    }

    func testCompressedRequestSignsLikeThePlainOne() async throws {
        let fixture = try XCTUnwrap(Fixtures.transactions.first { $0.name == "functionCall" })
        let payload = Data(base64Encoded: fixture.borsh)!
        let deflated = hex("e365606048ccc94c4ed52b492d2ec94b2d61385af8d84ecfecd0718d6be2afca57f4292b9cc8ac5bd3ed6675ff8050f7b4a698fdec0c10c003c4a5c529c9308d965efb36c7159471deeb2fde66ebbc57ca3cff5ffae4985519936b2fcd3ee0976ec30854cfc40d24d24ae24b8a12f38ad3528b0c80dc6aa5a2d4e4d4ccb2d4a2f8cc14252ba5a4fc2498914a3a4a89b9f9a57925406143033050aa657810feda439a81819101150000")
        XCTAssertEqual(payload.count, 202)
        XCTAssertEqual(deflated.count, 169)
        let request = OpticalRequest(kind: .transaction, path: .ledgerDefault, payload: payload)
        let compressed = request.message(deflatedPayload: deflated)
        XCTAssertEqual(compressed[0], 0x82)
        XCTAssertEqual(compressed.count, 21 + 4 + 169)
        XCTAssertEqual(Array(compressed[21..<25]), [0, 0, 0, 202])
        XCTAssertEqual(OpticalRequest(message: compressed), request)

        let sender = try OpticalSender(message: compressed, sessionId: 0xC0DE_0001, fragmentSize: 60)
        let decoded = try XCTUnwrap(OpticalRequest(message: try XCTUnwrap(transfer(sender))))
        XCTAssertEqual(decoded, request)

        let presenter = ScriptedPresenter(answers: [true])
        let service = SignerService(vault: InMemoryKeyVault(material: key), presenter: presenter,
                                    history: HistoryStore(fileURL: nil))
        let signature = try await service.sign(kind: try XCTUnwrap(decoded.signKind), path: decoded.path,
                                               payload: decoded.payload, transport: "Camera").get()
        XCTAssertEqual(presenter.shown.first?.display.title, "Send usdc.testnet tokens to bob.testnet")
        let publicKey = try key.privateKey(for: .ledgerDefault).publicKey
        XCTAssertTrue(publicKey.isValidSignature(signature, for: SigningDigest.transaction(payload)))
    }

    func testCompressedRequestsAreChecked() throws {
        let hello = hex("cb48cdc9c957c8c04e2a0200") // 30 bytes
        let path = BIP32Path.ledgerDefault.serialized
        func message(_ instruction: UInt8, length: UInt32, _ body: Data) -> Data {
            var bytes = Data([instruction]) + path
            bytes.append(bigEndian: length)
            return bytes + body
        }
        let plain = OpticalRequest(kind: .nep413, path: .ledgerDefault, payload: Data("hello hello hello hello hello!".utf8))
        XCTAssertEqual(OpticalRequest(message: message(0x87, length: 30, hello)), plain)
        XCTAssertNil(OpticalRequest(message: message(0x84, length: 30, hello)), "a public key request is never compressed")
        XCTAssertNil(OpticalRequest(message: message(0x87, length: 0, hello)), "length 0")
        XCTAssertNil(OpticalRequest(message: message(0x87, length: 29, hello)), "inflates to more than declared")
        XCTAssertNil(OpticalRequest(message: message(0x87, length: 31, hello)), "inflates to less than declared")
        XCTAssertNil(OpticalRequest(message: message(0x87, length: UInt32(NearAPDU.maxPayload + 1), hello)), "above the limit")
        XCTAssertNil(OpticalRequest(message: message(0x87, length: 30, hello.prefix(5))), "truncated")
        XCTAssertNil(OpticalRequest(message: Data([0x87]) + path + Data([0, 0])), "no length field")
        XCTAssertNil(OpticalRequest(message: message(0x89, length: 30, hello)), "unknown instruction")
    }
}
