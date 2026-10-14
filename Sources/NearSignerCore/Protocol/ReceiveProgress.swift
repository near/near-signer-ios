import Foundation

/// A signing request that is still arriving. Large requests (contract deployments) take minutes
/// over Bluetooth, so the app shows this instead of a silent wait.
public struct ReceiveProgress: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var transport: String
    /// Payload bytes received so far.
    public var received: Int
    /// Total payload size, when the start of the request tells (see `TransactionSizeProbe`).
    public var expected: Int?
    public var startedAt: Date

    public init(id: UUID, transport: String, received: Int, expected: Int?, startedAt: Date) {
        self.id = id
        self.transport = transport
        self.received = received
        self.expected = expected
        self.startedAt = startedAt
    }

    /// 0...0.99 while receiving: the last bytes still count, and a lower-bound estimate must not
    /// show "done" early.
    public var fraction: Double? {
        guard let expected, expected > 0 else { return nil }
        return min(0.99, Double(received) / Double(expected))
    }

    public func bytesPerSecond(now: Date = Date()) -> Double? {
        let elapsed = now.timeIntervalSince(startedAt)
        return elapsed > 0.5 ? Double(received) / elapsed : nil
    }

    public func secondsRemaining(now: Date = Date()) -> Double? {
        guard let expected, let rate = bytesPerSecond(now: now), rate > 0 else { return nil }
        return max(0, Double(expected - received) / rate)
    }
}

/// Works out the length of a borsh `Transaction` from its first bytes. Large fields (contract
/// code, call arguments) carry their length before their content, so a deployment's total size
/// is known after the first few hundred bytes.
public enum TransactionSizeProbe {
    /// Enough for every header field and action prefix of a real transaction.
    public static let prefixLimit = 64 * 1024

    /// The total length, or a lower bound when what follows a large field cannot be read yet.
    /// Nil if the prefix is too short, or uses an action whose size cannot be told.
    public static func expectedSize(ofPrefix data: Data) -> Int? {
        var walker = Walker(data: data)
        return walk(&walker) ?? walker.lowerBound
    }

    private struct Walker {
        let data: Data
        var offset = 0
        /// A length-prefixed field (code, arguments) runs past the received bytes.
        var blobPastEnd = false

        /// Where the unreadable part starts, once a large field is known to run past the prefix.
        /// A header that is merely incomplete gives no bound.
        var lowerBound: Int? { blobPastEnd && offset > data.count ? offset : nil }

        mutating func u8() -> Int? {
            guard offset + 1 <= data.count else { return nil }
            defer { offset += 1 }
            return Int(data[data.startIndex + offset])
        }

        mutating func u32() -> Int? {
            guard offset + 4 <= data.count else { return nil }
            var value = 0
            for index in 0..<4 { value |= Int(data[data.startIndex + offset + index]) << (8 * index) }
            offset += 4
            return value
        }

        mutating func skip(_ count: Int) { offset += count }

        mutating func skipBytes() -> Bool {
            guard let length = u32() else { return false }
            skip(length)
            if offset > data.count { blobPastEnd = true }
            return true
        }

        mutating func skipPublicKey() -> Bool {
            switch u8() {
            case 0: skip(32)
            case 1: skip(64)
            case 2: skip(1952)
            default: return false
            }
            return true
        }
    }

    private static func walk(_ w: inout Walker) -> Int? {
        let isV1 = w.data.count >= 2 && w.data[w.data.startIndex] == 1 && w.data[w.data.startIndex + 1] != 0
        if isV1 { w.skip(1) }
        guard w.skipBytes(), w.skipPublicKey() else { return nil }
        if isV1 {
            switch w.u8() {
            case 0: w.skip(8)
            case 1: w.skip(10)
            default: return nil
            }
        } else {
            w.skip(8)
        }
        guard w.skipBytes() else { return nil }
        w.skip(32)
        guard let count = w.u32(), count <= Limits.actions else { return nil }
        for _ in 0..<count {
            switch w.u8() {
            case 0: break                                                   // CreateAccount
            case 1: guard w.skipBytes() else { return nil }                 // DeployContract
            case 2:                                                         // FunctionCall
                guard w.skipBytes(), w.skipBytes() else { return nil }
                w.skip(8 + 16)
            case 3: w.skip(16)                                              // Transfer
            case 4: w.skip(16); guard w.skipPublicKey() else { return nil } // Stake
            case 6: guard w.skipPublicKey() else { return nil }             // DeleteKey
            case 7: guard w.skipBytes() else { return nil }                 // DeleteAccount
            case 9: guard w.skipBytes() else { return nil }; w.skip(1)      // DeployGlobalContract
            default: return nil
            }
        }
        if isV1 { w.skip(1) }
        return w.offset
    }
}
