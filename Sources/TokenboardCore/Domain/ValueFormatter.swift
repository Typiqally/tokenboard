import Foundation

public enum ValueFormatter {
    public static func compactTokens(_ value: Int64) -> String {
        let absolute = value.magnitude
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
        currency(value, currency: .usd)
    }

    public static func currency(_ value: Decimal, currency: DisplayCurrency) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.rawValue
        let symbol = switch currency {
        case .usd: "$"
        case .eur: "€"
        case .jpy: "¥"
        case .gbp: "£"
        case .cny: "CN¥"
        }
        formatter.currencySymbol = symbol
        formatter.positivePrefix = symbol
        formatter.negativePrefix = "-\(symbol)"
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        formatter.minimumFractionDigits = currency.fractionDigits
        formatter.maximumFractionDigits = currency.fractionDigits
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

    public static func duration(minutes: Int) -> String {
        let clampedMinutes = max(minutes, 0)
        let hours = clampedMinutes / 60
        let remainingMinutes = clampedMinutes % 60
        if hours == 0 { return "\(remainingMinutes)m" }
        if remainingMinutes == 0 { return "\(hours)h" }
        return "\(hours)h \(remainingMinutes)m"
    }
}
