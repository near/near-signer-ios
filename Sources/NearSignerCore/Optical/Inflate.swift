import Foundation

/// Raw DEFLATE (RFC 1951, no zlib or gzip header) decoding, for request payloads the computer
/// compressed (README "Camera transfer": contract code shrinks about three times). Bounded by
/// the length the sender declared: the output never grows past it, and anything malformed in the
/// input (a bad block, code, distance or table, or input that ends early) is an error, never a
/// crash. Tables are canonical Huffman codes decoded by lookup, not bit by bit.
public enum Inflate {
    public enum Error: Swift.Error, Equatable {
        /// The input ends before the last block does.
        case truncated
        /// A block type, code, distance or table the format doesn't allow.
        case invalidData
        /// The stream yields a different length than expected: it would overrun it, or ends short,
        /// or has data after its last block.
        case lengthMismatch
    }

    /// Inflates `data`, which must yield exactly `expectedLength` bytes.
    public static func inflate(_ data: Data, expectedLength: Int) throws -> Data {
        guard expectedLength >= 0 else { throw Error.lengthMismatch }
        var decoder = Decoder(input: [UInt8](data), expectedLength: expectedLength)
        try decoder.run()
        return Data(decoder.output)
    }

    // MARK: Tables

    /// A canonical Huffman code as a lookup table over `bits` input bits (LSB first, as they come
    /// from the stream): entry = symbol << 4 | code length; 0 marks a bit pattern no code starts
    /// with. Codes shorter than `bits` fill every entry that begins with them.
    struct Table {
        let entries: [UInt32]
        let bits: Int

        init(lengths: [UInt8]) throws {
            var counts = [Int](repeating: 0, count: 16)
            for length in lengths { counts[Int(length)] += 1 }
            counts[0] = 0
            var maxBits = 0
            var left = 1
            for length in 1...15 {
                left <<= 1
                left -= counts[length]
                if left < 0 { throw Error.invalidData } // over-subscribed
                if counts[length] > 0 { maxBits = length }
            }
            bits = maxBits
            guard maxBits > 0 else {
                entries = []
                return
            }
            var nextCode = [Int](repeating: 0, count: 16)
            var code = 0
            for length in 1...15 {
                code = (code + counts[length - 1]) << 1
                nextCode[length] = code
            }
            var table = [UInt32](repeating: 0, count: 1 << maxBits)
            for (symbol, length) in lengths.enumerated() where length > 0 {
                let length = Int(length)
                let canonical = nextCode[length]
                nextCode[length] += 1
                // The stream delivers a code most significant bit first, but bits are read least
                // significant first: index by the reversed code.
                var reversed = 0
                for bit in 0..<length { reversed |= ((canonical >> bit) & 1) << (length - 1 - bit) }
                var index = reversed
                let entry = UInt32(symbol) << 4 | UInt32(length)
                while index < table.count {
                    table[index] = entry
                    index += 1 << length
                }
            }
            entries = table
        }
    }

    static let fixedLiterals: Table = {
        var lengths = [UInt8](repeating: 8, count: 288)
        for symbol in 144...255 { lengths[symbol] = 9 }
        for symbol in 256...279 { lengths[symbol] = 7 }
        // swiftlint:disable:next force_try
        return try! Table(lengths: lengths)
    }()

    // 30 codes of 5 bits; the two spare bit patterns are no distance code.
    // swiftlint:disable:next force_try
    static let fixedDistances = try! Table(lengths: [UInt8](repeating: 5, count: 30))

    static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115,
                                    131, 163, 195, 227, 258]
    static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distanceBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
                                      2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distanceExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13,
                                       13]
    /// The order code-length code lengths are stored in a dynamic block header.
    static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    // MARK: Decoder

    struct Decoder {
        let input: [UInt8]
        let expectedLength: Int
        var output: [UInt8] = []
        private var position = 0
        /// Unread bits, least significant first.
        private var buffer: UInt64 = 0
        private var bufferedBits = 0

        init(input: [UInt8], expectedLength: Int) {
            self.input = input
            self.expectedLength = expectedLength
            output.reserveCapacity(expectedLength)
        }

        mutating func run() throws {
            var final = false
            repeat {
                final = try bits(1) == 1
                switch try bits(2) {
                case 0: try storedBlock()
                case 1: try compressedBlock(literals: Inflate.fixedLiterals, distances: Inflate.fixedDistances)
                case 2:
                    let (literals, distances) = try dynamicTables()
                    try compressedBlock(literals: literals, distances: distances)
                default: throw Error.invalidData
                }
            } while !final
            guard output.count == expectedLength else { throw Error.lengthMismatch }
            // Whole bytes after the last block are not padding.
            guard bufferedBits / 8 + (input.count - position) == 0 else { throw Error.lengthMismatch }
        }

        // MARK: Bits

        private mutating func refill() {
            while bufferedBits <= 56, position < input.count {
                buffer |= UInt64(input[position]) << UInt64(bufferedBits)
                position += 1
                bufferedBits += 8
            }
        }

        private mutating func bits(_ count: Int) throws -> Int {
            if bufferedBits < count {
                refill()
                guard bufferedBits >= count else { throw Error.truncated }
            }
            let value = Int(buffer & ((1 << UInt64(count)) - 1))
            buffer >>= UInt64(count)
            bufferedBits -= count
            return value
        }

        private mutating func decode(_ table: Table) throws -> Int {
            guard table.bits > 0 else { throw Error.invalidData }
            if bufferedBits < table.bits { refill() }
            let entry = table.entries[Int(buffer & ((1 << UInt64(table.bits)) - 1))]
            let length = Int(entry & 0xF)
            guard length > 0 else { throw Error.invalidData }
            guard length <= bufferedBits else { throw Error.truncated }
            buffer >>= UInt64(length)
            bufferedBits -= length
            return Int(entry >> 4)
        }

        // MARK: Blocks

        private mutating func storedBlock() throws {
            // Drop the rest of the current byte, then LEN and its complement.
            let padding = bufferedBits % 8
            buffer >>= UInt64(padding)
            bufferedBits -= padding
            let length = try bits(16)
            let complement = try bits(16)
            guard length == complement ^ 0xFFFF else { throw Error.invalidData }
            guard output.count + length <= expectedLength else { throw Error.lengthMismatch }
            for _ in 0..<length {
                output.append(UInt8(try bits(8)))
            }
        }

        private mutating func dynamicTables() throws -> (Table, Table) {
            let literalCount = try bits(5) + 257
            let distanceCount = try bits(5) + 1
            let codeLengthCount = try bits(4) + 4
            guard literalCount <= 286, distanceCount <= 30 else { throw Error.invalidData }
            var codeLengthLengths = [UInt8](repeating: 0, count: 19)
            for index in 0..<codeLengthCount {
                codeLengthLengths[Inflate.codeLengthOrder[index]] = UInt8(try bits(3))
            }
            let codeLengths = try Table(lengths: codeLengthLengths)
            var lengths: [UInt8] = []
            let total = literalCount + distanceCount
            lengths.reserveCapacity(total)
            while lengths.count < total {
                let symbol = try decode(codeLengths)
                switch symbol {
                case 0...15:
                    lengths.append(UInt8(symbol))
                case 16:
                    guard let previous = lengths.last else { throw Error.invalidData }
                    let repeats = 3 + (try bits(2))
                    guard lengths.count + repeats <= total else { throw Error.invalidData }
                    lengths.append(contentsOf: repeatElement(previous, count: repeats))
                case 17:
                    let repeats = 3 + (try bits(3))
                    guard lengths.count + repeats <= total else { throw Error.invalidData }
                    lengths.append(contentsOf: repeatElement(0, count: repeats))
                default: // 18
                    let repeats = 11 + (try bits(7))
                    guard lengths.count + repeats <= total else { throw Error.invalidData }
                    lengths.append(contentsOf: repeatElement(0, count: repeats))
                }
            }
            // Every block ends with the end-of-block code, so it must have one.
            guard lengths[256] != 0 else { throw Error.invalidData }
            let literals = try Table(lengths: Array(lengths[0..<literalCount]))
            let distances = try Table(lengths: Array(lengths[literalCount...]))
            return (literals, distances)
        }

        private mutating func compressedBlock(literals: Table, distances: Table) throws {
            while true {
                let symbol = try decode(literals)
                if symbol < 256 {
                    guard output.count < expectedLength else { throw Error.lengthMismatch }
                    output.append(UInt8(symbol))
                    continue
                }
                if symbol == 256 { return }
                guard symbol <= 285 else { throw Error.invalidData }
                let lengthIndex = symbol - 257
                let length = Inflate.lengthBase[lengthIndex] + (try bits(Inflate.lengthExtra[lengthIndex]))
                let distanceSymbol = try decode(distances)
                guard distanceSymbol < 30 else { throw Error.invalidData }
                let distance = Inflate.distanceBase[distanceSymbol] + (try bits(Inflate.distanceExtra[distanceSymbol]))
                guard distance <= output.count else { throw Error.invalidData }
                guard output.count + length <= expectedLength else { throw Error.lengthMismatch }
                // Byte by byte: the copy may overlap its own output (distance < length).
                var source = output.count - distance
                for _ in 0..<length {
                    output.append(output[source])
                    source += 1
                }
            }
        }
    }
}
