/// Unsigned 128-bit integer used for NEAR balances (yoctoNEAR).
/// Swift's built-in `UInt128` requires iOS 18, so this keeps the deployment target at iOS 17.
public struct U128: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var high: UInt64
    public var low: UInt64

    public init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    public init(_ value: UInt64) {
        self.init(high: 0, low: value)
    }

    /// Parses a base-10 string. Returns nil on invalid characters or overflow.
    public init?(decimal: String) {
        guard !decimal.isEmpty else { return nil }
        var result = U128(0)
        for character in decimal {
            guard let digit = character.wholeNumberValue, character.isASCII else { return nil }
            guard let next = result.multipliedAndAdded(multiplier: 10, addend: UInt64(digit)) else { return nil }
            result = next
        }
        self = result
    }

    public static let zero = U128(0)

    public var isZero: Bool { high == 0 && low == 0 }

    public static func < (lhs: U128, rhs: U128) -> Bool {
        lhs.high != rhs.high ? lhs.high < rhs.high : lhs.low < rhs.low
    }

    /// Returns `self * multiplier + addend`, or nil on overflow.
    func multipliedAndAdded(multiplier: UInt64, addend: UInt64) -> U128? {
        let lowProduct = low.multipliedFullWidth(by: multiplier)
        let highProduct = high.multipliedFullWidth(by: multiplier)
        guard highProduct.high == 0 else { return nil }
        let (newHigh, overflowHigh) = highProduct.low.addingReportingOverflow(lowProduct.high)
        guard !overflowHigh else { return nil }
        let (newLow, carry) = lowProduct.low.addingReportingOverflow(addend)
        if carry {
            let (carriedHigh, overflowCarry) = newHigh.addingReportingOverflow(1)
            guard !overflowCarry else { return nil }
            return U128(high: carriedHigh, low: newLow)
        }
        return U128(high: newHigh, low: newLow)
    }

    /// Returns quotient and remainder of division by a 64-bit divisor.
    func quotientAndRemainder(dividingBy divisor: UInt64) -> (quotient: U128, remainder: UInt64) {
        let highQuotient = high / divisor
        let highRemainder = high % divisor
        let (lowQuotient, remainder) = divisor.dividingFullWidth((high: highRemainder, low: low))
        return (U128(high: highQuotient, low: lowQuotient), remainder)
    }

    public var description: String {
        if isZero { return "0" }
        var digits: [Character] = []
        var value = self
        while !value.isZero {
            let (quotient, remainder) = value.quotientAndRemainder(dividingBy: 10)
            digits.append(Character(String(remainder)))
            value = quotient
        }
        return String(digits.reversed())
    }

    // Codable as a decimal string, which keeps JSON readable and lossless.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let value = U128(decimal: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid u128 \(string)")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
