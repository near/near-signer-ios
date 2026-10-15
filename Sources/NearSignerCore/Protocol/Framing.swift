import Foundation

public enum FramingError: Error, Equatable, CustomStringConvertible {
    case unexpectedTag(UInt8)
    case unexpectedSequence(expected: UInt16, got: UInt16)
    case malformedPacket
    case tooLarge(Int)

    public var description: String {
        switch self {
        case let .unexpectedTag(tag): return String(format: "unexpected frame tag 0x%02x", tag)
        case let .unexpectedSequence(expected, got): return "unexpected sequence \(got) (expected \(expected))"
        case .malformedPacket: return "malformed packet"
        case let .tooLarge(length): return "message of \(length) bytes is too large"
        }
    }
}

/// Ledger BLE framing (same as Nano X): every GATT write / notification carries
/// `0x05 | seq (u16 BE) | [total length (u16 BE), first packet only] | data`.
/// `0x08 0 0 0 0` asks the device for its packet size; the answer is `0x08 0 0 0 0 <size>`.
public enum BLEFraming {
    public static let apduTag: UInt8 = 0x05
    public static let mtuTag: UInt8 = 0x08
    public static let maxMessageLength = 0xFFFF

    public static func frames(for message: Data, packetSize: Int) -> [Data] {
        precondition(packetSize > 5, "packet size too small")
        let message = Data(message)
        var frames: [Data] = []
        var offset = 0
        var sequence: UInt16 = 0
        repeat {
            var frame = Data([apduTag, UInt8(sequence >> 8), UInt8(sequence & 0xFF)])
            if sequence == 0 {
                frame.append(UInt8(message.count >> 8))
                frame.append(UInt8(message.count & 0xFF))
            }
            let chunk = min(packetSize - frame.count, message.count - offset)
            frame.append(message[offset..<(offset + chunk)])
            offset += chunk
            frames.append(frame)
            sequence &+= 1
        } while offset < message.count
        return frames
    }

    public static func mtuResponse(packetSize: Int) -> Data {
        Data([mtuTag, 0, 0, 0, 0, UInt8(clamping: packetSize)])
    }
}

/// Reassembles host-to-device BLE packets into complete APDUs.
public struct BLEFrameAssembler {
    public enum Event: Equatable {
        case none
        case apdu(Data)
        case mtuRequest
    }

    private var buffer = Data()
    private var expectedLength = 0
    private var nextSequence: UInt16 = 0
    /// After a lost packet the rest of that message is dropped quietly until the next one starts,
    /// so the host gets a single error reply.
    private var discarding = false
    /// The last sequence number dropped while discarding. One that goes back means the next
    /// message has begun and lost its first packet: that message gets its own error reply.
    private var discardedSequence: UInt16 = 0

    public init() {}

    public mutating func reset() {
        buffer = Data()
        expectedLength = 0
        nextSequence = 0
    }

    public mutating func receive(_ packet: Data) throws -> Event {
        let bytes = [UInt8](packet)
        guard let tag = bytes.first else { try fail(.malformedPacket) }
        if tag == BLEFraming.mtuTag {
            reset()
            return .mtuRequest
        }
        // While a message is being dropped, more garbage gets no further replies.
        guard tag == BLEFraming.apduTag else {
            if discarding { return .none }
            try fail(.unexpectedTag(tag))
        }
        guard bytes.count >= 3 else {
            if discarding { return .none }
            try fail(.malformedPacket)
        }
        let sequence = UInt16(bytes[1]) << 8 | UInt16(bytes[2])
        var dataStart = 3
        if sequence == 0 {
            // A new message always restarts reassembly, so a dropped packet cannot wedge the link.
            guard bytes.count >= 5 else { try fail(.malformedPacket) }
            buffer = Data()
            expectedLength = Int(bytes[3]) << 8 | Int(bytes[4])
            nextSequence = 0
            dataStart = 5
            discarding = false
        } else if discarding {
            guard sequence > discardedSequence else {
                try fail(.unexpectedSequence(expected: 0, got: sequence), at: sequence)
            }
            discardedSequence = sequence
            return .none
        } else if sequence != nextSequence {
            try fail(.unexpectedSequence(expected: nextSequence, got: sequence), at: sequence)
        }
        buffer.append(contentsOf: bytes[dataStart...])
        nextSequence &+= 1
        if buffer.count >= expectedLength {
            let message = buffer.prefix(expectedLength)
            reset()
            return .apdu(Data(message))
        }
        return .none
    }

    /// Drops the message in progress; its remaining packets are ignored until the next one starts.
    private mutating func fail(_ error: FramingError, at sequence: UInt16 = 0) throws -> Never {
        reset()
        discarding = true
        discardedSequence = sequence
        throw error
    }
}

/// Speculos-compatible TCP framing, used for the USB (usbmux) and simulator transports.
/// Request: `length (u32 BE) | APDU`. Response: `length of data (u32 BE) | data | SW1 SW2`,
/// where the length excludes the 2-byte status word.
public struct TCPFrameDecoder {
    public static let maxMessageLength = 64 * 1024
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) { buffer.append(data) }

    /// Returns the next complete APDU, if one is buffered.
    public mutating func nextMessage() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let header = [UInt8](buffer.prefix(4))
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length <= TCPFrameDecoder.maxMessageLength else { throw FramingError.tooLarge(length) }
        guard buffer.count >= 4 + length else { return nil }
        let message = Data(buffer.dropFirst(4).prefix(length))
        buffer = Data(buffer.dropFirst(4 + length))
        return message
    }

    /// `response` is APDU response data followed by the status word.
    public static func encodeResponse(_ response: Data) -> Data {
        let dataLength = UInt32(max(response.count - 2, 0))
        var frame = Data()
        withUnsafeBytes(of: dataLength.bigEndian) { frame.append(contentsOf: $0) }
        frame.append(response)
        return frame
    }

    public static func encodeRequest(_ apdu: Data) -> Data {
        var frame = Data()
        withUnsafeBytes(of: UInt32(apdu.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(apdu)
        return frame
    }
}
