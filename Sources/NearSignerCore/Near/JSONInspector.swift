import Foundation

/// Checks JSON for duplicate object keys. JSON parsers disagree on which value wins
/// (Foundation, serde, browsers), so a summary built from one parser could show a different
/// value than the contract reads. Call it only on input that already parsed as JSON.
enum JSONInspector {
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
