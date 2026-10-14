import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Secret bytes held in memory that is overwritten when released. Best effort: Foundation and
/// CryptoKit make their own short-lived copies along the way, which this cannot reach.
public final class SecretBytes: ContiguousBytes, Equatable, @unchecked Sendable {
    // Written only in init and deinit.
    private let buffer: UnsafeMutableRawBufferPointer
    public let count: Int

    public init<Bytes: ContiguousBytes>(_ bytes: Bytes) {
        let count = bytes.withUnsafeBytes { $0.count }
        self.count = count
        buffer = .allocate(byteCount: max(count, 1), alignment: 16)
        bytes.withUnsafeBytes { source in
            if let base = source.baseAddress, count > 0 {
                buffer.baseAddress!.copyMemory(from: base, byteCount: count)
            }
        }
    }

    deinit {
        SecretBytes.wipe(buffer)
        buffer.deallocate()
    }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
    }

    /// Constant-time comparison.
    public static func == (lhs: SecretBytes, rhs: SecretBytes) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count { difference |= lhs.buffer[index] ^ rhs.buffer[index] }
        return difference == 0
    }

    /// A copy as `Data`, for storage. The caller should wipe it (`resetBytes`) when done.
    public var data: Data { withUnsafeBytes { Data($0) } }

    static func wipe(_ buffer: UnsafeMutableRawBufferPointer) {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
        #if canImport(Darwin)
        _ = memset_s(base, buffer.count, 0, buffer.count)
        #else
        // A volatile-style loop the optimizer cannot drop: the pointer escapes to an opaque call.
        for index in 0..<buffer.count { buffer.storeBytes(of: 0, toByteOffset: index, as: UInt8.self) }
        withExtendedLifetime(base) {}
        #endif
    }
}
