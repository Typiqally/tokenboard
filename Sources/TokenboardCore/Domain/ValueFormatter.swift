import Foundation

public enum ValueFormatter {
    public static func compactTokens(_ value: Int64) -> String {
        let absolute = abs(value)
        if absolute < 1_000 { return String(value) }
        if absolute < 1_000_000 { return scaled(value, divisor: 1_000, suffix: "K") }
        if absolute < 1_000_000_000 { return scaled(value, divisor: 1_000_000, suffix: "M") }
        return scaled(value, divisor: 1_000_000_000, suffix: "B")
    }

    private static func scaled(_ value: Int64, divisor: Int64, suffix: String) -> String {
        let scaled = Double(value) / Double(divisor)
        let digits = abs(scaled) >= 100 ? 0 : (abs(scaled) >= 10 ? 1 : 2)
        return String(format: "%.*f", digits, scaled)
            .replacingOccurrences(of: #"\.0+$"#, with: "", options: .regularExpression)
            .appending(suffix)
    }

    public static func usd(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.currencySymbol = "$"
        formatter.positivePrefix = "$"
        formatter.negativePrefix = "-$"
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber)!
    }

    public static func exactTokens(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value))!
    }
}
