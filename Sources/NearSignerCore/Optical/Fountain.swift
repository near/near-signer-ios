import Foundation

/// The fountain code of the camera transfer: which fragments a frame carries. Frames come in
/// blocks of K: even blocks are the fragments in order, so every fragment passes by within 2K
/// frames whenever the phone starts watching; odd blocks are XORs of pseudo-random sets, chosen
/// the same way by the computer that shows the frames and the phone that reads them, which fill
/// in what the camera missed. (A receiver that has seen no plain fragment can't use a mixed one.)
public enum Fountain {
    /// Fragments mixed into frame `sequence` of a transfer with `fragmentCount` fragments.
    public static func indexes(sessionId: UInt32, sequence: UInt32, fragmentCount: Int) -> [Int] {
        precondition(fragmentCount > 0)
        let count = UInt32(fragmentCount)
        if (sequence / count) % 2 == 0 { return [Int(sequence % count)] }
        var generator = XorShift32(seed: sessionId ^ (sequence &* 0x9E37_79B9))
        let degree = mixedDegree(&generator, fragmentCount: fragmentCount)
        // A partial Fisher-Yates shuffle of 0..<fragmentCount, stored sparsely: only the swapped
        // positions are kept, so a large transfer doesn't allocate the whole array per frame.
        var swapped: [Int: Int] = [:]
        var chosen: [Int] = []
        chosen.reserveCapacity(degree)
        for i in 0..<degree {
            let j = i + Int(generator.next() % UInt32(fragmentCount - i))
            let valueAtJ = swapped[j] ?? j
            let valueAtI = swapped[i] ?? i
            swapped[j] = valueAtI
            swapped[i] = valueAtJ
            chosen.append(valueAtJ)
        }
        return chosen
    }

    /// How many fragments frame `sequence` mixes, from the generator's first draw only: cheap
    /// even when the frame mixes thousands.
    public static func degree(sessionId: UInt32, sequence: UInt32, fragmentCount: Int) -> Int {
        precondition(fragmentCount > 0)
        if (sequence / UInt32(fragmentCount)) % 2 == 0 { return 1 }
        var generator = XorShift32(seed: sessionId ^ (sequence &* 0x9E37_79B9))
        return mixedDegree(&generator, fragmentCount: fragmentCount)
    }

    /// Ideal soliton distribution: half the frames mix 2 fragments, a sixth 3, a twelfth 4...
    private static func mixedDegree(_ generator: inout XorShift32, fragmentCount: Int) -> Int {
        let u = UInt64(generator.next())
        return min(Int(UInt64(UInt32.max) / ((UInt64(1) << 32) - u)) + 1, fragmentCount)
    }
}

/// xorshift32, seeded so that both sides derive the same sequence.
struct XorShift32 {
    private var state: UInt32

    init(seed: UInt32) {
        state = seed == 0 ? 0x9E37_79B9 : seed
    }

    mutating func next() -> UInt32 {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return state
    }
}
