import Foundation

public enum DisplayMetric: String, Codable, CaseIterable, Sendable {
    case tokens
    case apiValue = "api_value"
}

public enum SourceHealth: Equatable, Sendable {
    case notGranted
    case indexing(fileCount: Int)
    case healthy(fileCount: Int, lastUpdated: Date)
    case warning(issue: TokenboardHealthIssue, message: String)
}

public struct MenuPresentation: Equatable, Sendable {
    public let tokenTotal: Int64
    public let statusTitle: String
    public let tokenTitle: String
    public let apiValueTitle: String
    public let unpricedTitle: String?

    public init(
        summary: UsageSummary,
        displayMetric: DisplayMetric,
        displayCurrency: DisplayCurrency = .usd
    ) {
        tokenTotal = summary.tokenTotal
        let compactTokens = ValueFormatter.compactTokens(summary.tokenTotal)
        tokenTitle = "\(ValueFormatter.exactTokens(summary.tokenTotal)) tokens"
        let converted = CurrencyConverter.convert(
            usd: summary.knownAPIEquivalentUSD,
            to: displayCurrency,
            rates: summary.exchangeRates?.rates
        )
        if let converted {
            let formatted = ValueFormatter.currency(converted, currency: displayCurrency)
            statusTitle = displayMetric == .tokens
                ? compactTokens
                : "\(formatted)\(summary.unpricedTokens > 0 ? "+" : "")"
            apiValueTitle = "≈ \(formatted) API equivalent"
        } else {
            statusTitle = displayMetric == .tokens
                ? compactTokens
                : "—"
            apiValueTitle = "\(displayCurrency.rawValue) API equivalent unavailable"
        }
        unpricedTitle = summary.unpricedTokens > 0
            ? "\(ValueFormatter.compactTokens(summary.unpricedTokens)) unpriced"
            : nil
    }
}
