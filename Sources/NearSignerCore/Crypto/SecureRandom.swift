import Foundation
#if canImport(Security)
import Security
#endif

public enum SecureRandomError: Error, Equatable, CustomStringConvertible {
    /// The operating system's generator reported an error (its status code).
    case unavailable(Int32)
    /// The output looks broken (all one value, or a repeat of the previous output).
    case failedHealthCheck

    public var description: String {
        switch self {
        case let .unavailable(status): return "the system random number generator failed (\(status))"
        case .failedHealthCheck: return "the system random number generator returned unusable output"
        }
    }
}

/// Random bytes for recovery phrases, from the operating system's cryptographically secure
/// generator: `SecRandomCopyBytes` on Apple platforms (it reports failure instead of returning
/// weak output), `SystemRandomNumberGenerator` (`getrandom`) elsewhere, which only the tests and
/// the simulator use. Never a seeded or user-space PRNG, never time-based.
public enum SecureRandom {
    public static func bytes(_ count: Int) throws -> Data {
        try bytes(count, source: systemBytes)
    }

    /// Fails closed on output that only a broken generator produces: all bytes equal, or two
    /// draws in a row identical. For 16 bytes or more, a working generator does either with
    /// probability below 2^-120.
    static func bytes(_ count: Int, source: (Int) throws -> Data) throws -> Data {
        let output = try source(count)
        guard output.count == count else { throw SecureRandomError.failedHealthCheck }
        guard count >= 16 else { return output }
        var check = try source(count)
        defer { check.resetBytes(in: 0..<check.count) }
        guard output != check, Set(output).count > 1 else { throw SecureRandomError.failedHealthCheck }
        return output
    }

    private static func systemBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        guard count > 0 else { return data }
        #if canImport(Security)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw SecureRandomError.unavailable(status) }
        #else
        var generator = SystemRandomNumberGenerator()
        data.withUnsafeMutableBytes { buffer in
            for index in buffer.indices { buffer[index] = generator.next() }
        }
        #endif
        return data
    }
}
