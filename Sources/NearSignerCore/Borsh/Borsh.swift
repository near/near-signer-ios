import Foundation

public enum BorshError: Error, Equatable, CustomStringConvertible {
    case unexpectedEnd(needed: Int, remaining: Int)
    case invalidUTF8
    case invalidOptionTag(UInt8)
    case invalidEnumTag(type: String, tag: UInt8)
    case trailingBytes(Int)
    case lengthTooLarge(UInt32)
    case tooManyElements(count: UInt32, limit: Int)
    /// The payload decodes, but re-encoding the result gives different bytes, so the signature
    /// would cover something other than what is displayed.
    case nonCanonical

    public var description: String {
        switch self {
        case let .unexpectedEnd(needed, remaining):
            return "unexpected end of data (needed \(needed) bytes, \(remaining) left)"
        case .invalidUTF8:
            return "string is not valid UTF-8"
        case let .invalidOptionTag(tag):
            return "invalid Option tag \(tag)"
        case let .invalidEnumTag(type, tag):
            return "unknown \(type) variant \(tag)"
        case let .trailingBytes(count):
            return "\(count) unexpected trailing bytes"
        case let .lengthTooLarge(length):
            return "length prefix \(length) exceeds remaining data"
        case let .tooManyElements(count, limit):
            return "\(count) elements, more than the \(limit) allowed"
        case .nonCanonical:
            return "payload is not in canonical form"
        }
    }
}

/// Sequential reader for Borsh-encoded data (little-endian integers, u32 length prefixes).
public struct BorshReader {
    public let data: Data
    public private(set) var offset: Int

    public init(_ data: Data) {
        // Re-base so that indices always start at zero, even for slices.
        self.data = Data(data)
        self.offset = 0
    }

    public var remaining: Int { data.count - offset }
    public var isAtEnd: Bool { offset == data.count }

    public mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else {
            throw BorshError.unexpectedEnd(needed: count, remaining: remaining)
        }
        let slice = data[offset..<(offset + count)]
        offset += count
        return Data(slice)
    }

    public mutating func readU8() throws -> UInt8 {
        try readBytes(1)[0]
    }

    public mutating func readBool() throws -> Bool {
        try readU8() != 0
    }

    public mutating func readU32() throws -> UInt32 {
        UInt32(try readLittleEndian(4))
    }

    public mutating func readU64() throws -> UInt64 {
        try readLittleEndian(8)
    }

    public mutating func readU128() throws -> U128 {
        let low = try readU64()
        let high = try readU64()
        return U128(high: high, low: low)
    }

    public mutating func readFixed(_ count: Int) throws -> Data {
        try readBytes(count)
    }

    /// `Vec<u8>`: u32 length followed by bytes.
    public mutating func readByteVector() throws -> Data {
        let length = try readU32()
        guard Int(length) <= remaining else { throw BorshError.lengthTooLarge(length) }
        return try readBytes(Int(length))
    }

    /// Strict UTF-8: the decoded string must encode back to exactly the same bytes. Foundation
    /// silently drops a leading byte-order mark, which would make the displayed text differ from
    /// the signed bytes.
    public mutating func readString() throws -> String {
        let bytes = try readByteVector()
        guard let string = String(data: bytes, encoding: .utf8), Data(string.utf8) == bytes else {
            throw BorshError.invalidUTF8
        }
        return string
    }

    public mutating func readOption<T>(_ readValue: (inout BorshReader) throws -> T) throws -> T? {
        let tag = try readU8()
        switch tag {
        case 0: return nil
        case 1: return try readValue(&self)
        default: throw BorshError.invalidOptionTag(tag)
        }
    }

    public mutating func readVector<T>(maxCount: Int = .max, _ readElement: (inout BorshReader) throws -> T) throws -> [T] {
        let count = try readU32()
        // Every element takes at least one byte, which bounds hostile length prefixes.
        guard Int(count) <= remaining else { throw BorshError.lengthTooLarge(count) }
        guard Int(count) <= maxCount else { throw BorshError.tooManyElements(count: count, limit: maxCount) }
        var result: [T] = []
        result.reserveCapacity(Int(count))
        for _ in 0..<count {
            result.append(try readElement(&self))
        }
        return result
    }

    public func ensureAtEnd() throws {
        if !isAtEnd { throw BorshError.trailingBytes(remaining) }
    }

    private mutating func readLittleEndian(_ width: Int) throws -> UInt64 {
        let bytes = try readBytes(width)
        var value: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
            value |= UInt64(byte) << (8 * UInt64(index))
        }
        return value
    }
}

/// Borsh encoder, used to build signed transactions and test fixtures.
public struct BorshWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func writeU8(_ value: UInt8) { data.append(value) }

    public mutating func writeBool(_ value: Bool) { data.append(value ? 1 : 0) }

    public mutating func writeU32(_ value: UInt32) { writeLittleEndian(UInt64(value), width: 4) }

    public mutating func writeU64(_ value: UInt64) { writeLittleEndian(value, width: 8) }

    public mutating func writeU128(_ value: U128) {
        writeU64(value.low)
        writeU64(value.high)
    }

    public mutating func writeFixed(_ bytes: Data) { data.append(bytes) }

    public mutating func writeByteVector(_ bytes: Data) {
        writeU32(UInt32(bytes.count))
        data.append(bytes)
    }

    public mutating func writeString(_ string: String) { writeByteVector(Data(string.utf8)) }

    public mutating func writeOption<T>(_ value: T?, _ writeValue: (inout BorshWriter, T) -> Void) {
        if let value {
            writeU8(1)
            writeValue(&self, value)
        } else {
            writeU8(0)
        }
    }

    public mutating func writeVector<T>(_ values: [T], _ writeElement: (inout BorshWriter, T) -> Void) {
        writeU32(UInt32(values.count))
        for value in values { writeElement(&self, value) }
    }

    private mutating func writeLittleEndian(_ value: UInt64, width: Int) {
        for index in 0..<width {
            data.append(UInt8(truncatingIfNeeded: value >> (8 * UInt64(index))))
        }
    }
}
