import Foundation

public enum OpticalError: Error, Equatable, CustomStringConvertible {
    case emptyMessage
    case messageTooLong(Int)
    case badFragmentSize(Int)
    case tooManyFragments(Int)

    public var description: String {
        switch self {
        case .emptyMessage: return "the message is empty"
        case let .messageTooLong(count): return "the message is \(count) bytes; at most \(OpticalFrame.maxMessageLength) can be sent"
        case let .badFragmentSize(size): return "the fragment size is \(size); it must be 1...\(OpticalFrame.maxFragmentSize)"
        case let .tooManyFragments(count): return "the message would take \(count) fragments; at most \(OpticalFrame.maxFragmentCount) are possible"
        }
    }
}

/// One QR code of a request: `NS1:` and the base45 of a 19-byte header and a fragment.
public struct OpticalFrame: Equatable, Sendable {
    public static let prefix = "NS1:"
    public static let maxFragmentSize = 1200
    public static let maxFragmentCount = 65535
    /// The Bluetooth payload limit plus the instruction and path in front of it.
    public static let maxMessageLength = NearAPDU.maxPayload + 21
    static let headerLength = 19
    static let type: UInt8 = 0x01

    public var sessionId: UInt32
    public var length: Int
    public var fragmentSize: Int
    public var crc: UInt32
    public var sequence: UInt32
    public var data: Data

    public init(sessionId: UInt32, length: Int, fragmentSize: Int, crc: UInt32, sequence: UInt32, data: Data) {
        self.sessionId = sessionId
        self.length = length
        self.fragmentSize = fragmentSize
        self.crc = crc
        self.sequence = sequence
        self.data = data
    }

    /// Nil unless `text` is a well-formed frame within the limits. Other QR codes in view give nil.
    public init?(text: String) {
        guard text.hasPrefix(OpticalFrame.prefix),
              let bytes = Base45.decode(String(text.dropFirst(OpticalFrame.prefix.count))),
              bytes.count >= OpticalFrame.headerLength, bytes[bytes.startIndex] == OpticalFrame.type else { return nil }
        let header = [UInt8](bytes.prefix(OpticalFrame.headerLength))
        func u32(_ offset: Int) -> UInt32 { header[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) } }
        sessionId = u32(1)
        length = Int(u32(5))
        fragmentSize = Int(header[9]) << 8 | Int(header[10])
        crc = u32(11)
        sequence = u32(15)
        data = Data(bytes.dropFirst(OpticalFrame.headerLength))
        guard length >= 1, length <= OpticalFrame.maxMessageLength,
              fragmentSize >= 1, fragmentSize <= OpticalFrame.maxFragmentSize,
              data.count == fragmentSize,
              fragmentCount <= OpticalFrame.maxFragmentCount else { return nil }
    }

    public var text: String {
        var bytes = Data(capacity: OpticalFrame.headerLength + data.count)
        bytes.append(OpticalFrame.type)
        bytes.append(bigEndian: sessionId)
        bytes.append(bigEndian: UInt32(length))
        bytes.append(UInt8(fragmentSize >> 8))
        bytes.append(UInt8(fragmentSize & 0xFF))
        bytes.append(bigEndian: crc)
        bytes.append(bigEndian: sequence)
        bytes.append(data)
        return OpticalFrame.prefix + Base45.encode(bytes)
    }

    /// K: how many fragments the message takes.
    public var fragmentCount: Int { (length + fragmentSize - 1) / fragmentSize }
}

/// The computer's side: splits a message into fragments and produces frame after frame, for as
/// long as the phone needs. The simulator and the tests use it; `host/optical/` is the same in
/// JavaScript.
public struct OpticalSender: Sendable {
    public let sessionId: UInt32
    public let fragmentSize: Int
    public let length: Int
    public let crc: UInt32
    private let fragments: [Data]

    public init(message: Data, sessionId: UInt32, fragmentSize: Int) throws {
        guard !message.isEmpty else { throw OpticalError.emptyMessage }
        guard message.count <= OpticalFrame.maxMessageLength else { throw OpticalError.messageTooLong(message.count) }
        guard fragmentSize >= 1, fragmentSize <= OpticalFrame.maxFragmentSize else { throw OpticalError.badFragmentSize(fragmentSize) }
        let count = (message.count + fragmentSize - 1) / fragmentSize
        guard count <= OpticalFrame.maxFragmentCount else { throw OpticalError.tooManyFragments(count) }
        self.sessionId = sessionId
        self.fragmentSize = fragmentSize
        length = message.count
        crc = CRC32.checksum(message)
        var padded = message
        padded.append(Data(repeating: 0, count: count * fragmentSize - message.count))
        fragments = (0..<count).map { index in
            padded.subdata(in: (index * fragmentSize)..<((index + 1) * fragmentSize))
        }
    }

    public var fragmentCount: Int { fragments.count }

    public func frame(_ sequence: UInt32) -> OpticalFrame {
        let indexes = Fountain.indexes(sessionId: sessionId, sequence: sequence, fragmentCount: fragments.count)
        var data = fragments[indexes[0]]
        for index in indexes.dropFirst() {
            data.xor(fragments[index])
        }
        return OpticalFrame(sessionId: sessionId, length: length, fragmentSize: fragmentSize, crc: crc,
                            sequence: sequence, data: data)
    }
}

extension Data {
    mutating func append(bigEndian value: UInt32) {
        append(UInt8(value >> 24))
        append(UInt8(value >> 16 & 0xFF))
        append(UInt8(value >> 8 & 0xFF))
        append(UInt8(value & 0xFF))
    }

    /// XORs `other` into this data; both must have the same count.
    mutating func xor(_ other: Data) {
        precondition(count == other.count)
        withUnsafeMutableBytes { (mine: UnsafeMutableRawBufferPointer) in
            other.withUnsafeBytes { (theirs: UnsafeRawBufferPointer) in
                for index in 0..<mine.count {
                    mine[index] ^= theirs[index]
                }
            }
        }
    }
}
