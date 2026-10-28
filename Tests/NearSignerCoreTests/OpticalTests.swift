import Foundation
import XCTest
@testable import NearSignerCore

/// The camera transfer: QR frames in, one QR answer out (README "Camera transfer").
final class OpticalTests: XCTestCase {
    private let key = try! KeyMaterial.fromMnemonic(Fixtures.phrase)

    // MARK: Text codecs

    func testBase45MatchesRFC9285() {
        XCTAssertEqual(Base45.encode(Data("AB".utf8)), "BB8")
        XCTAssertEqual(Base45.encode(Data("Hello!!".utf8)), "%69 VD92EX0")
        XCTAssertEqual(Base45.encode(Data("base-45".utf8)), "UJCLQE7W581")
        XCTAssertEqual(Base45.decode("QED8WEX0"), Data("ietf!".utf8))
        XCTAssertEqual(Base45.decode("BB8"), Data("AB".utf8))
        XCTAssertEqual(Base45.encode(Data()), "")
        XCTAssertEqual(Base45.decode(""), Data())
        XCTAssertNil(Base45.decode("GGW"), "45 * 45 * 44 + ... is above 65 535")
        XCTAssertNil(Base45.decode(":::"), "above 65 535")
        XCTAssertNil(Base45.decode("A"), "3n + 1 characters")
        XCTAssertNil(Base45.decode("abc"), "lower case is outside the alphabet")
        XCTAssertNil(Base45.decode("::"), "a final pair above 255")
        for count in [0, 1, 2, 3, 100, 1219] {
            let data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
            XCTAssertEqual(Base45.decode(Base45.encode(data)), data)
        }
    }

    func testCRC32() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
        XCTAssertEqual(CRC32.checksum(Data("hello".utf8)), 0x3610_A686)
    }

    func testCrockfordBase32() {
        XCTAssertEqual(Base32Crockford.encode(Data("f".utf8)), "CR")
        XCTAssertEqual(Base32Crockford.encode(Data("foobar".utf8)), "CSQPYRK1E8")
        XCTAssertEqual(Base32Crockford.decode("csqpyrk1e8"), Data("foobar".utf8))
        XCTAssertEqual(Base32Crockford.decode("CSQPY-RKIE8"), Data("foobar".utf8), "hyphens skipped, I reads as 1")
        XCTAssertEqual(Base32Crockford.decode("CSQPY RKLE8"), Data("foobar".utf8), "L reads as 1")
        XCTAssertEqual(Base32Crockford.decode("CSQPYRK1E8".replacingOccurrences(of: "0", with: "O")), Data("foobar".utf8))
        XCTAssertNil(Base32Crockford.decode("CSQPYRK1E8U"), "U is not in the alphabet")
        XCTAssertNil(Base32Crockford.decode("CSQPYRK1E9"), "the padding bits are not zero")
        for count in [0, 1, 2, 3, 4, 5, 6, 75, 200] {
            let data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) })
            let text = Base32Crockford.encode(data)
            XCTAssertTrue(text.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) })
            XCTAssertEqual(Base32Crockford.decode(text), data)
        }
    }

    // MARK: Frames

    func testFountainIndexes() {
        XCTAssertEqual(Fountain.indexes(sessionId: 7, sequence: 3, fragmentCount: 10), [3])
        XCTAssertEqual(Fountain.indexes(sessionId: 7, sequence: 0, fragmentCount: 1), [0])
        XCTAssertEqual(Fountain.indexes(sessionId: 7, sequence: 99, fragmentCount: 1), [0], "one fragment: every frame is it")
        XCTAssertEqual(Fountain.indexes(sessionId: 7, sequence: 23, fragmentCount: 10), [3], "even blocks repeat the fragments")
        XCTAssertEqual(Fountain.indexes(sessionId: 7, sequence: 538, fragmentCount: 4), [2])
        XCTAssertGreaterThan(Fountain.indexes(sessionId: 7, sequence: 15, fragmentCount: 10).count, 1, "odd blocks mix")
        for sequence in UInt32(10)..<UInt32(2000) {
            let indexes = Fountain.indexes(sessionId: 0xDEAD_BEEF, sequence: sequence, fragmentCount: 10)
            XCTAssertEqual(Set(indexes).count, indexes.count, "distinct")
            XCTAssertTrue(indexes.allSatisfy { (0..<10).contains($0) })
            XCTAssertFalse(indexes.isEmpty)
        }
        // Ideal soliton: about half the mixed frames (odd blocks) have degree 2.
        let degrees = (300..<20100).filter { ($0 / 300) % 2 == 1 }
            .map { Fountain.indexes(sessionId: 1, sequence: UInt32($0), fragmentCount: 300).count }
        XCTAssertEqual(degrees.count, 9900)
        let twos = degrees.filter { $0 == 2 }.count
        XCTAssertTrue((4455...5445).contains(twos), "\(twos) of 9 900 mixed frames have degree 2")
        XCTAssertTrue(degrees.contains { $0 >= 10 })
    }

    func testFrameRoundTripAndLimits() throws {
        let frame = OpticalFrame(sessionId: 0x0102_0304, length: 5, fragmentSize: 4, crc: CRC32.checksum(Data("hello".utf8)),
                                 sequence: 0, data: Data("hell".utf8))
        XCTAssertTrue(frame.text.hasPrefix("NS1:"))
        XCTAssertTrue(frame.text.dropFirst(4).allSatisfy { "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:".contains($0) })
        XCTAssertEqual(OpticalFrame(text: frame.text), frame)
        XCTAssertEqual(frame.fragmentCount, 2)
        XCTAssertNil(OpticalFrame(text: "https://example.com"), "any other QR code")
        XCTAssertNil(OpticalFrame(text: String(frame.text.dropLast())), "a damaged frame")
        XCTAssertNil(OpticalFrame(text: "NS1:" + Base45.encode(Data([2]) + Data(repeating: 0, count: 22))), "unknown type")
        var bad = frame
        bad.fragmentSize = 5
        XCTAssertNil(OpticalFrame(text: bad.text), "data shorter than the fragment size")
        bad = frame
        bad.length = OpticalFrame.maxMessageLength + 1
        XCTAssertNil(OpticalFrame(text: bad.text), "too long a message")
        bad = frame
        bad.length = 65536 * 4
        XCTAssertNil(OpticalFrame(text: bad.text), "too many fragments")
        bad = frame
        bad.length = 0
        XCTAssertNil(OpticalFrame(text: bad.text), "an empty message")
        bad = frame
        bad.fragmentSize = 0
        bad.data = Data()
        XCTAssertNil(OpticalFrame(text: bad.text))

        XCTAssertThrowsError(try OpticalSender(message: Data(), sessionId: 1, fragmentSize: 10))
        XCTAssertThrowsError(try OpticalSender(message: Data(repeating: 1, count: 10), sessionId: 1, fragmentSize: 1201))
        XCTAssertThrowsError(try OpticalSender(message: Data(repeating: 1, count: 70000), sessionId: 1, fragmentSize: 1))
        XCTAssertThrowsError(try OpticalSender(message: Data(repeating: 1, count: OpticalFrame.maxMessageLength + 1),
                                               sessionId: 1, fragmentSize: 1200))
        let sender = try OpticalSender(message: Data("hello".utf8), sessionId: 0x0102_0304, fragmentSize: 4)
        XCTAssertEqual(sender.fragmentCount, 2)
        XCTAssertEqual(sender.frame(0), frame)
        XCTAssertEqual(sender.frame(1).data, Data([UInt8(ascii: "o"), 0, 0, 0]), "the last fragment is zero padded")
    }

    // MARK: Sender to receiver

    private func message(_ count: Int, seed: UInt8 = 1) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 251 &+ Int(seed)) })
    }

    /// Feeds frames `from...` through `receiver` until the message is complete, dropping frames
    /// `drop` says to drop. Returns the message and how many frames were shown.
    private func transfer(_ sender: OpticalSender, receiver: OpticalReceiver = OpticalReceiver(), from start: UInt32 = 0,
                          limit: Int = 100_000, drop: (UInt32) -> Bool = { _ in false }) -> (Data?, Int) {
        var sequence = start
        var shown = 0
        while shown < limit {
            defer { sequence += 1 }
            if drop(sequence) { continue }
            shown += 1
            if case let .complete(message) = receiver.receive(sender.frame(sequence).text) { return (message, shown) }
        }
        return (nil, shown)
    }

    func testFramesInOrder() throws {
        let original = message(1234)
        let sender = try OpticalSender(message: original, sessionId: 42, fragmentSize: 100)
        XCTAssertEqual(sender.fragmentCount, 13)
        let receiver = OpticalReceiver()
        XCTAssertNil(receiver.progress)
        XCTAssertEqual(receiver.receive(sender.frame(0).text), .progress(OpticalProgress(known: 1, total: 13, length: 1234, sessionId: 42)))
        XCTAssertEqual(receiver.receive(sender.frame(0).text), .duplicate)
        XCTAssertEqual(receiver.receive("WIFI:T:WPA;S:cafe;;"), .notAFrame)
        let (received, shown) = transfer(sender, receiver: receiver, from: 1)
        XCTAssertEqual(received, original)
        XCTAssertEqual(shown, 12, "every frame counted")
        XCTAssertEqual(receiver.progress?.known, 13, "progress stays readable after completion")
        XCTAssertEqual(receiver.sessionId, 42)
        XCTAssertEqual(receiver.receive(sender.frame(20).text), .duplicate, "more frames of a finished transfer")
        receiver.reset()
        XCTAssertNil(receiver.progress)
    }

    func testLossyStartingMidStream() throws {
        let original = message(5000, seed: 9)
        let sender = try OpticalSender(message: original, sessionId: 0xCAFE_F00D, fragmentSize: 120)
        var generator = XorShift32(seed: 2024)
        var dropped = Set<UInt32>()
        for sequence in 0..<5000 where generator.next() % 100 < 40 { dropped.insert(UInt32(sequence)) }
        let (received, shown) = transfer(sender, from: 17) { dropped.contains($0) }
        XCTAssertEqual(received, original)
        XCTAssertLessThan(shown, 3 * sender.fragmentCount, "a fountain code needs little more than K frames")
    }

    /// Seen on a phone: scanning began hundreds of frames in, when the sender was past its first
    /// pass over the fragments, and with no plain fragment nothing could ever be peeled.
    func testStartingLongAfterTheFirstPass() throws {
        let original = message(172, seed: 3)
        let sender = try OpticalSender(message: original, sessionId: 0xB10C_B10C, fragmentSize: 50)
        XCTAssertEqual(sender.fragmentCount, 4)
        let (received, shown) = transfer(sender, from: 538)
        XCTAssertEqual(received, original)
        XCTAssertLessThanOrEqual(shown, 2 * sender.fragmentCount)

        // The same with losses, from inside a mixed block.
        var generator = XorShift32(seed: 77)
        var dropped = Set<UInt32>()
        for sequence in 0..<100_000 where generator.next() % 100 < 40 { dropped.insert(UInt32(sequence)) }
        let big = try OpticalSender(message: message(9000, seed: 4), sessionId: 0xB10C_0002, fragmentSize: 100)
        let (lossy, lossyShown) = transfer(big, from: UInt32(big.fragmentCount * 3 + 7)) { dropped.contains($0) }
        XCTAssertEqual(lossy, message(9000, seed: 4))
        XCTAssertLessThan(lossyShown, 4 * big.fragmentCount)
    }

    func testSingleFragmentMessage() throws {
        let original = Data([0x80])
        let sender = try OpticalSender(message: original, sessionId: 5, fragmentSize: 500)
        XCTAssertEqual(sender.fragmentCount, 1)
        let receiver = OpticalReceiver()
        XCTAssertEqual(receiver.receive(sender.frame(12).text), .complete(original), "every frame is the whole message")
    }

    func testLargeMessageWithLosses() throws {
        let original = message(300_000, seed: 3)
        let sender = try OpticalSender(message: original, sessionId: 777, fragmentSize: 500)
        XCTAssertEqual(sender.fragmentCount, 600)
        var generator = XorShift32(seed: 99)
        var dropped = Set<UInt32>()
        for sequence in 0..<20000 where generator.next() % 100 < 30 { dropped.insert(UInt32(sequence)) }
        let started = Date()
        let (received, shown) = transfer(sender, from: 250) { dropped.contains($0) }
        XCTAssertEqual(received, original)
        XCTAssertLessThan(shown, 2 * sender.fragmentCount)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }

    func testChecksumMismatchAndDisagreeingFrames() throws {
        let original = message(300)
        let sender = try OpticalSender(message: original, sessionId: 1, fragmentSize: 100)
        var corrupt = sender.frame(1)
        corrupt.data[0] ^= 0xFF
        let receiver = OpticalReceiver()
        _ = receiver.receive(sender.frame(0).text)
        _ = receiver.receive(corrupt.text)
        guard case .invalid = receiver.receive(sender.frame(2).text) else { return XCTFail("a wrong checksum must be reported") }
        XCTAssertNil(receiver.progress, "starts over")
        // It recovers: the right frames complete it.
        XCTAssertEqual(transfer(sender, receiver: receiver).0, original)

        let other = OpticalReceiver()
        _ = other.receive(sender.frame(0).text)
        var disagreeing = sender.frame(1)
        disagreeing.length = 299
        guard case .invalid = other.receive(disagreeing.text) else { return XCTFail("a different header must be reported") }
    }

    func testAnotherSessionTakesOverAfterThreeFrames() throws {
        let first = try OpticalSender(message: message(300), sessionId: 1, fragmentSize: 100)
        let second = try OpticalSender(message: message(250, seed: 2), sessionId: 2, fragmentSize: 100)
        let receiver = OpticalReceiver()
        _ = receiver.receive(first.frame(0).text)
        XCTAssertEqual(receiver.receive(second.frame(0).text), .otherSession)
        XCTAssertEqual(receiver.receive(second.frame(1).text), .otherSession)
        XCTAssertEqual(receiver.receive(first.frame(1).text), .progress(OpticalProgress(known: 2, total: 3, length: 300, sessionId: 1)),
                       "the first transfer is still in progress")
        XCTAssertEqual(receiver.receive(second.frame(0).text), .otherSession, "the count starts again")
        XCTAssertEqual(receiver.receive(second.frame(1).text), .otherSession)
        XCTAssertEqual(receiver.receive(second.frame(2).text), .progress(OpticalProgress(known: 1, total: 3, length: 250, sessionId: 2)),
                       "three in a row: the new transfer replaces the old one")
        XCTAssertEqual(receiver.sessionId, 2)
        XCTAssertEqual(transfer(second, receiver: receiver).0, message(250, seed: 2))
    }

    func testMixedFramesAreBounded() throws {
        // Fragments 0 and 1 never arrive directly; only mixed frames do, many more than are kept.
        let original = message(4000)
        let sender = try OpticalSender(message: original, sessionId: 31, fragmentSize: 1000)
        let receiver = OpticalReceiver()
        _ = receiver.receive(sender.frame(2).text)
        _ = receiver.receive(sender.frame(3).text)
        var sequence: UInt32 = 4
        var complete = false
        while sequence < 5000, !complete {
            if case .complete = receiver.receive(sender.frame(sequence).text) { complete = true }
            sequence += 1
        }
        XCTAssertTrue(complete)
    }

    // MARK: Request and response

    func testRequestMessage() throws {
        let payload = Data(base64Encoded: Fixtures.transactions[0].borsh)!
        let request = OpticalRequest(kind: .transaction, path: .ledgerDefault, payload: payload)
        XCTAssertEqual(request.message.prefix(1), Data([0x02]))
        XCTAssertEqual(request.message.count, 21 + payload.count)
        XCTAssertEqual(OpticalRequest(message: request.message), request)
        XCTAssertEqual(request.signKind, .transaction)

        let publicKey = OpticalRequest(kind: .publicKey, path: BIP32Path(hardened: [44, 397, 0, 0, 7]), payload: Data())
        XCTAssertEqual(OpticalRequest(message: publicKey.message), publicKey)
        XCTAssertNil(publicKey.signKind)
        XCTAssertNil(OpticalRequest(message: publicKey.message + Data([1])), "a public key request carries no payload")
        XCTAssertNil(OpticalRequest(message: Data([0x02]) + BIP32Path(hardened: [44, 397, 0]).serialized + payload), "3-level path")
        XCTAssertNil(OpticalRequest(message: Data([0x02]) + BIP32Path(hardened: [44, 60, 0, 0, 1]).serialized + payload), "not NEAR")
        XCTAssertNil(OpticalRequest(message: Data([0x02]) + BIP32Path(components: [44, 397, 0, 0, 1]).serialized + payload), "not hardened")
        XCTAssertNil(OpticalRequest(message: Data([0x06]) + BIP32Path.ledgerDefault.serialized), "get version is not a request")
        XCTAssertNil(OpticalRequest(message: Data([0x02, 0, 0])), "too short")
        XCTAssertEqual(OpticalRequest(message: Data([0x07]) + BIP32Path.ledgerDefault.serialized + Data([1]))?.signKind, .nep413)
        XCTAssertEqual(OpticalRequest(message: Data([0x08]) + BIP32Path.ledgerDefault.serialized + Data([1]))?.signKind, .nep366)
    }

    func testResponseText() throws {
        let response = OpticalResponse(sessionId: 0x0102_0304, status: .ok, result: Data(repeating: 7, count: 64))
        let text = response.text
        XCTAssertTrue(text.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) })
        XCTAssertEqual(text.count, (75 * 8 + 4) / 5)
        XCTAssertEqual(OpticalResponse(text: text), response)
        XCTAssertEqual(OpticalResponse(text: response.groupedText), response)
        XCTAssertEqual(OpticalResponse(text: response.groupedText.lowercased()), response)
        let groups = response.groupedText.split(separator: " ")
        XCTAssertTrue(groups.dropLast().allSatisfy { $0.count == 5 })
        XCTAssertEqual(groups.joined(), text)
        var typo = Array(text)
        typo[10] = typo[10] == "A" ? "B" : "A"
        XCTAssertNil(OpticalResponse(text: String(typo)), "the checksum catches a typo")
        XCTAssertNil(OpticalResponse(text: "NS1:" + text))
        XCTAssertNil(OpticalResponse(text: ""))

        let refused = OpticalResponse(sessionId: 9, status: .publicKeyMismatch, result: Data())
        XCTAssertEqual(OpticalResponse(text: refused.text), refused)
        XCTAssertEqual(OpticalResponse(text: refused.text)?.status, .publicKeyMismatch)
        // An unknown status word is refused.
        var bytes = Data([0x02]) + Data([0, 0, 0, 9, 0x12, 0x34])
        bytes.append(bigEndian: CRC32.checksum(bytes))
        XCTAssertNil(OpticalResponse(text: Base32Crockford.encode(bytes)))
    }

    // MARK: End to end

    func testSignsATransactionThroughFramesAndAnswers() async throws {
        let fixture = try XCTUnwrap(Fixtures.transactions.first { $0.name == "functionCall" })
        let payload = Data(base64Encoded: fixture.borsh)!
        let request = OpticalRequest(kind: .transaction, path: .ledgerDefault, payload: payload)
        let sender = try OpticalSender(message: request.message, sessionId: 0xA5A5_0001, fragmentSize: 50)
        XCTAssertGreaterThan(sender.fragmentCount, 3)

        // The computer shows frames; the phone catches every other one.
        let receiver = OpticalReceiver()
        let (message, _) = transfer(sender, receiver: receiver) { $0 % 2 == 1 }
        let decoded = try XCTUnwrap(OpticalRequest(message: try XCTUnwrap(message)))
        XCTAssertEqual(decoded, request)

        let presenter = ScriptedPresenter(answers: [true])
        let history = HistoryStore(fileURL: nil)
        let service = SignerService(vault: InMemoryKeyVault(material: key), presenter: presenter, history: history)
        let result = await service.sign(kind: try XCTUnwrap(decoded.signKind), path: decoded.path, payload: decoded.payload,
                                        transport: "Camera")
        let signature = try result.get()
        let response = OpticalResponse(sessionId: try XCTUnwrap(receiver.sessionId), status: .ok, result: signature)
        XCTAssertEqual(presenter.shown.first?.display.title, "Send usdc.testnet tokens to bob.testnet")
        XCTAssertEqual(presenter.shown.first?.transport, "Camera")

        // The computer reads the answer back and checks it.
        let read = try XCTUnwrap(OpticalResponse(text: response.text))
        XCTAssertEqual(read.sessionId, 0xA5A5_0001)
        XCTAssertEqual(read.status, .ok)
        let publicKey = try key.privateKey(for: .ledgerDefault).publicKey
        XCTAssertTrue(publicKey.isValidSignature(read.result, for: SigningDigest.transaction(payload)))
        #if !canImport(CryptoKit)
        // BoringSSL signs deterministically (RFC 8032), like tweetnacl. CryptoKit randomizes.
        XCTAssertEqual(read.result.base64EncodedString(), fixture.signature, "deterministic ed25519 matches near-api-js")
        #endif
        let records = await history.all()
        XCTAssertEqual(records.first?.transport, "Camera")

        // A public key request through the same path.
        let keyRequest = OpticalRequest(kind: .publicKey, path: .ledgerDefault, payload: Data())
        let keySender = try OpticalSender(message: keyRequest.message, sessionId: 2, fragmentSize: 500)
        let keyReceiver = OpticalReceiver()
        guard case let .complete(keyMessage) = keyReceiver.receive(keySender.frame(0).text) else { return XCTFail("one frame") }
        let keyDecoded = try XCTUnwrap(OpticalRequest(message: keyMessage))
        let keyPresenter = ScriptedPresenter(answers: [true])
        let keyService = SignerService(vault: InMemoryKeyVault(material: key), presenter: keyPresenter, history: HistoryStore(fileURL: nil))
        let exported = try await keyService.publicKey(path: keyDecoded.path, display: true, transport: "Camera").get()
        XCTAssertEqual(PublicKey.ed25519(exported).description, Fixtures.ledgerPublicKey)
        let keyResponse = OpticalResponse(sessionId: 2, status: .ok, result: exported)
        XCTAssertEqual(OpticalResponse(text: keyResponse.groupedText)?.result, exported)
    }
}
