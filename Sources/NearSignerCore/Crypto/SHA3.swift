import Foundation

/// SHA3-256 (FIPS 202): Keccak-f[1600] with a 136-byte rate and the `0x06 … 0x80` padding.
/// Neither CryptoKit nor swift-crypto offers SHA-3, and NEAR needs it for the on-chain handle of
/// an ML-DSA-65 key and for universal account ids. This is the plain lane-wise permutation, with
/// no table lookups that depend on the input.
public enum SHA3 {
    public static func hash256<D: DataProtocol>(_ data: D) -> Data {
        let rate = 136
        var state = [UInt64](repeating: 0, count: 25)
        var block = [UInt8](repeating: 0, count: rate)
        var filled = 0
        for byte in data {
            block[filled] = byte
            filled += 1
            if filled == rate {
                absorb(block, into: &state)
                filled = 0
            }
        }
        // Padding: the domain byte 0x06 right after the message, 0x80 on the last byte of the
        // block. The two share a byte when exactly one byte of the block is left.
        for index in filled..<rate { block[index] = 0 }
        block[filled] ^= 0x06
        block[rate - 1] ^= 0x80
        absorb(block, into: &state)

        var digest = Data(capacity: 32)
        for lane in state.prefix(4) {
            for shift in stride(from: 0, to: 64, by: 8) {
                digest.append(UInt8(truncatingIfNeeded: lane >> UInt64(shift)))
            }
        }
        return digest
    }

    /// XORs one rate-sized block into the state (little-endian lanes) and applies the permutation.
    private static func absorb(_ block: [UInt8], into state: inout [UInt64]) {
        for lane in 0..<(block.count / 8) {
            var value: UInt64 = 0
            for index in 0..<8 {
                value |= UInt64(block[lane * 8 + index]) << UInt64(8 * index)
            }
            state[lane] ^= value
        }
        keccakF1600(&state)
    }

    private static let roundConstants: [UInt64] = [
        0x0000_0000_0000_0001, 0x0000_0000_0000_8082, 0x8000_0000_0000_808A, 0x8000_0000_8000_8000,
        0x0000_0000_0000_808B, 0x0000_0000_8000_0001, 0x8000_0000_8000_8081, 0x8000_0000_0000_8009,
        0x0000_0000_0000_008A, 0x0000_0000_0000_0088, 0x0000_0000_8000_8009, 0x0000_0000_8000_000A,
        0x0000_0000_8000_808B, 0x8000_0000_0000_008B, 0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
        0x8000_0000_0000_8002, 0x8000_0000_0000_0080, 0x0000_0000_0000_800A, 0x8000_0000_8000_000A,
        0x8000_0000_8000_8081, 0x8000_0000_0000_8080, 0x0000_0000_8000_0001, 0x8000_0000_8000_8008,
    ]

    /// Rotation offsets of the rho step, indexed by lane (x + 5 * y).
    private static let rotations: [UInt64] = [
        0, 1, 62, 28, 27,
        36, 44, 6, 55, 20,
        3, 10, 43, 25, 39,
        41, 45, 15, 21, 8,
        18, 2, 61, 56, 14,
    ]

    private static func rotateLeft(_ value: UInt64, _ count: UInt64) -> UInt64 {
        count == 0 ? value : (value << count) | (value >> (64 - count))
    }

    /// The 24 rounds of theta, rho, pi, chi and iota on a 5 × 5 lane state.
    private static func keccakF1600(_ a: inout [UInt64]) {
        var b = [UInt64](repeating: 0, count: 25)
        var c = [UInt64](repeating: 0, count: 5)
        var d = [UInt64](repeating: 0, count: 5)
        for round in 0..<24 {
            // Theta: each column's parity feeds the two neighbouring columns.
            for x in 0..<5 {
                c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20]
            }
            for x in 0..<5 {
                d[x] = c[(x + 4) % 5] ^ rotateLeft(c[(x + 1) % 5], 1)
            }
            for index in 0..<25 {
                a[index] ^= d[index % 5]
            }
            // Rho and pi: rotate every lane and move it to (y, 2x + 3y).
            for x in 0..<5 {
                for y in 0..<5 {
                    let from = x + 5 * y
                    let to = y + 5 * ((2 * x + 3 * y) % 5)
                    b[to] = rotateLeft(a[from], rotations[from])
                }
            }
            // Chi: the only non-linear step, row by row.
            for y in 0..<5 {
                for x in 0..<5 {
                    a[x + 5 * y] = b[x + 5 * y] ^ (~b[(x + 1) % 5 + 5 * y] & b[(x + 2) % 5 + 5 * y])
                }
            }
            // Iota.
            a[0] ^= roundConstants[round]
        }
    }
}
