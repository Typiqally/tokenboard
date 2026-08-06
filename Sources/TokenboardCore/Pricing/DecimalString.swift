import Foundation

public struct DecimalString: Codable, Equatable, Sendable {
    public let rawValue: String
    public let decimal: Decimal

    public init(decimal: Decimal) {
        precondition(!decimal.isNaN && decimal >= 0 && decimal <= Decimal(100_000))
        self.decimal = decimal
        rawValue = NSDecimalNumber(decimal: decimal).stringValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let pattern = try NSRegularExpression(pattern: #"^(0|[1-9][0-9]*)(\.[0-9]{1,9})?$"#)
        guard pattern.firstMatch(in: value, range: range)?.range == range,
              let parsed = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              !parsed.isNaN,
              parsed <= Decimal(100_000) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "price must be a canonical decimal string from 0 through 100000"
            )
        }
        rawValue = value
        decimal = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
