import TokenboardCore

enum UsageSelectionPresentation {
    static let displayMetrics = DisplayMetric.allCases
    static let periods = CalendarPeriod.allCases
    static let currencies = DisplayCurrency.allCases

    static func displayMetricTitle(_ metric: DisplayMetric) -> String {
        switch metric {
        case .tokens: "Tokens"
        case .apiValue: "API Value"
        }
    }

    static func periodTitle(_ period: CalendarPeriod) -> String {
        switch period {
        case .today: "Today"
        case .thisWeek: "This Week"
        case .thisMonth: "This Month"
        case .thisYear: "This Year"
        case .allTime: "All Time"
        }
    }

    static func currencyTitle(_ currency: DisplayCurrency) -> String {
        "\(currency.rawValue) · \(currencyDisplayName(currency))"
    }

    static func currencyDisplayName(_ currency: DisplayCurrency) -> String {
        switch currency {
        case .usd: "US Dollar"
        case .eur: "Euro"
        case .jpy: "Japanese Yen"
        case .gbp: "British Pound"
        case .cny: "Chinese Yuan"
        }
    }
}
