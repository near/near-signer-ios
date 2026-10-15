import Foundation

/// Checks JSON the way contracts read it. JSON parsers disagree on which value of a repeated key
/// wins (Foundation, serde, browsers), so a summary built from one parser could show a different
/// value than the contract reads. Foundation also accepts input serde_json refuses (a trailing
/// comma, a byte-order mark), so strictness is checked here rather than left to it.
enum JSONInspector {
    /// Whether `data` is JSON as serde_json reads it (RFC 8259).
    static func isStrict(_ data: Data) -> Bool {
        var reader = StrictJSON(bytes: [UInt8](data), writes: false)
        return String(data: data, encoding: .utf8) != nil && reader.document()
    }

    /// `data` laid out for display (see `NearFormat.json`), or nil unless `isStrict(data)`.
    static func layout(_ data: Data) -> String? {
        var writer = StrictJSON(bytes: [UInt8](data), writes: true)
        guard String(data: data, encoding: .utf8) != nil, writer.document() else { return nil }
        return String(decoding: writer.out, as: UTF8.self)
    }

    /// Call it only on input that already parsed as JSON.
    static func hasDuplicateKeys(_ data: Data) -> Bool {
        struct Frame {
            let isObject: Bool
            var keys: Set<String> = []
            var expectingKey: Bool
        }
        let bytes = [UInt8](data)
        var stack: [Frame] = []
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "{"):
                stack.append(Frame(isObject: true, expectingKey: true))
            case UInt8(ascii: "["):
                stack.append(Frame(isObject: false, expectingKey: false))
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if !stack.isEmpty { stack.removeLast() }
            case UInt8(ascii: ","):
                if let last = stack.indices.last, stack[last].isObject { stack[last].expectingKey = true }
            case UInt8(ascii: "\""):
                guard let (string, end) = readString(bytes, from: index) else { return true }
                if let last = stack.indices.last, stack[last].isObject, stack[last].expectingKey {
                    if !stack[last].keys.insert(string).inserted { return true }
                    stack[last].expectingKey = false
                }
                index = end
            default:
                break
            }
            index += 1
        }
        return false
    }

    /// Decodes the JSON string starting at `start` (the opening quote), resolving escapes so that
    /// `"a"` and `"a"` compare equal. Returns the index of the closing quote.
    private static func readString(_ bytes: [UInt8], from start: Int) -> (String, Int)? {
        var units: [UInt16] = []
        var raw: [UInt8] = []
        var index = start + 1
        func flushRaw() {
            units.append(contentsOf: String(decoding: raw, as: UTF8.self).utf16)
            raw.removeAll()
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                flushRaw()
                return (String(decoding: units, as: UTF16.self), index)
            }
            if byte == UInt8(ascii: "\\") {
                flushRaw()
                guard index + 1 < bytes.count else { return nil }
                let escaped = bytes[index + 1]
                switch escaped {
                case UInt8(ascii: "u"):
                    guard index + 5 < bytes.count,
                          let value = UInt16(String(decoding: bytes[(index + 2)...(index + 5)], as: UTF8.self), radix: 16) else { return nil }
                    units.append(value)
                    index += 6
                    continue
                case UInt8(ascii: "n"): units.append(0x0A)
                case UInt8(ascii: "t"): units.append(0x09)
                case UInt8(ascii: "r"): units.append(0x0D)
                case UInt8(ascii: "b"): units.append(0x08)
                case UInt8(ascii: "f"): units.append(0x0C)
                default: units.append(UInt16(escaped))
                }
                index += 2
                continue
            }
            raw.append(byte)
            index += 1
        }
        return nil
    }
}

/// A strict RFC 8259 reader that can copy its input out with one entry per line: no trailing
/// commas, comments, byte-order mark, leading zeros, raw control characters or lone surrogates,
/// and at most 128 levels deep (serde_json's limit). Tokens are copied byte for byte, so only the
/// whitespace between them changes.
private struct StrictJSON {
    let bytes: [UInt8]
    let writes: Bool
    var index = 0
    var depth = 0
    var out: [UInt8] = []

    init(bytes: [UInt8], writes: Bool) {
        self.bytes = bytes
        self.writes = writes
        if writes { out.reserveCapacity(bytes.count + bytes.count / 2) }
    }

    mutating func document() -> Bool {
        skipSpace()
        guard value() else { return false }
        skipSpace()
        return index == bytes.count
    }

    private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func write(_ part: some Sequence<UInt8>) {
        if writes { out.append(contentsOf: part) }
    }

    private mutating func newline() {
        write(CollectionOfOne(UInt8(ascii: "\n")))
        write(repeatElement(UInt8(ascii: " "), count: 2 * depth))
    }

    private mutating func skipSpace() {
        while let byte = peek, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1 }
    }

    private mutating func value() -> Bool {
        switch peek {
        case UInt8(ascii: "{"): return container(close: UInt8(ascii: "}"), isObject: true)
        case UInt8(ascii: "["): return container(close: UInt8(ascii: "]"), isObject: false)
        case UInt8(ascii: "\""): return string()
        case UInt8(ascii: "t"): return literal("true")
        case UInt8(ascii: "f"): return literal("false")
        case UInt8(ascii: "n"): return literal("null")
        default: return number()
        }
    }

    private mutating func container(close: UInt8, isObject: Bool) -> Bool {
        guard depth < 128 else { return false }
        write(CollectionOfOne(bytes[index]))
        index += 1
        skipSpace()
        if peek == close {
            write(CollectionOfOne(close))
            index += 1
            return true
        }
        depth += 1
        while true {
            newline()
            if isObject {
                guard peek == UInt8(ascii: "\""), string() else { return false }
                skipSpace()
                guard peek == UInt8(ascii: ":") else { return false }
                index += 1
                write([UInt8(ascii: ":"), UInt8(ascii: " ")])
                skipSpace()
            }
            guard value() else { return false }
            skipSpace()
            guard peek != UInt8(ascii: ",") else {
                write(CollectionOfOne(UInt8(ascii: ",")))
                index += 1
                skipSpace()
                continue
            }
            guard peek == close else { return false }
            index += 1
            depth -= 1
            newline()
            write(CollectionOfOne(close))
            return true
        }
    }

    private mutating func string() -> Bool {
        let start = index
        index += 1
        while let byte = peek {
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                write(bytes[start..<index])
                return true
            case UInt8(ascii: "\\"):
                index += 1
                guard let escaped = peek else { return false }
                index += 1
                if escaped == UInt8(ascii: "u") {
                    guard let unit = hex4() else { return false }
                    if (0xDC00...0xDFFF).contains(unit) { return false }
                    if (0xD800...0xDBFF).contains(unit) {
                        // A high surrogate must be followed by an escaped low one.
                        guard peek == UInt8(ascii: "\\"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "u") else { return false }
                        index += 2
                        guard let low = hex4(), (0xDC00...0xDFFF).contains(low) else { return false }
                    }
                } else if !"\"\\/bfnrt".utf8.contains(escaped) {
                    return false
                }
            case 0..<0x20:
                return false
            default:
                index += 1
            }
        }
        return false
    }

    private mutating func hex4() -> UInt16? {
        guard index + 4 <= bytes.count,
              let unit = UInt16(String(decoding: bytes[index..<(index + 4)], as: UTF8.self), radix: 16),
              bytes[index..<(index + 4)].allSatisfy({ $0 != UInt8(ascii: "+") && $0 != UInt8(ascii: "-") }) else { return nil }
        index += 4
        return unit
    }

    private mutating func number() -> Bool {
        let start = index
        if peek == UInt8(ascii: "-") { index += 1 }
        guard let first = peek, isDigit(first) else { return false }
        index += 1
        if first != UInt8(ascii: "0") { skipDigits() }
        if peek == UInt8(ascii: ".") {
            index += 1
            guard digits() else { return false }
        }
        if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
            index += 1
            if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { index += 1 }
            guard digits() else { return false }
        }
        write(bytes[start..<index])
        return true
    }

    private mutating func literal(_ word: String) -> Bool {
        let end = index + word.utf8.count
        guard end <= bytes.count, bytes[index..<end].elementsEqual(word.utf8) else { return false }
        write(bytes[index..<end])
        index = end
        return true
    }

    private func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }

    private mutating func skipDigits() {
        while let byte = peek, isDigit(byte) { index += 1 }
    }

    /// One or more digits.
    private mutating func digits() -> Bool {
        let start = index
        skipDigits()
        return index > start
    }
}
