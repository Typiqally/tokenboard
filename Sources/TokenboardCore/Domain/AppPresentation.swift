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
    public let statusTitle: String
    public let tokenTitle: String
    public let apiValueTitle: String
    public let unpricedTitle: String?

    public init(
        summary: UsageSummary,
        displayMetric: DisplayMetric,
        hasHealthWarning: Bool
    ) {
        let symbol = hasHealthWarning ? "⚠" : "◉"
        let compactTokens = ValueFormatter.compactTokens(summary.tokenTotal)
        let usd = ValueFormatter.usd(summary.knownAPIEquivalentUSD)
        statusTitle = displayMetric == .tokens
            ? "\(symbol) \(compactTokens)"
            : "\(symbol) \(usd)\(summary.unpricedTokens > 0 ? "+" : "")"
        tokenTitle = "\(ValueFormatter.exactTokens(summary.tokenTotal)) tokens"
        apiValueTitle = "≈ \(usd) API equivalent"
        unpricedTitle = summary.unpricedTokens > 0
            ? "\(ValueFormatter.compactTokens(summary.unpricedTokens)) unpriced"
            : nil
    }
}
