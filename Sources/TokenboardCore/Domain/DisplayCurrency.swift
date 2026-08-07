public enum DisplayCurrency: String, Codable, CaseIterable, Hashable, Sendable {
    case usd = "USD"
    case eur = "EUR"
    case jpy = "JPY"
    case gbp = "GBP"
    case cny = "CNY"

    public var fractionDigits: Int { self == .jpy ? 0 : 2 }
}
