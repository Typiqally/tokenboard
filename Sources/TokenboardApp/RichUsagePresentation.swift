import AppKit
import Foundation
import TokenboardCore

enum TokenboardSurfaceMetrics {
    static let popoverSize = NSSize(width: 400, height: 590)
    static let historySize = NSSize(width: 760, height: 580)
    static let historyMinimumSize = NSSize(width: 680, height: 520)
}

enum RichPopoverContentState: Equatable, Sendable {
    case loading
    case ready
    case failed(message: String)
}

struct ProviderSharePresentation: Equatable, Identifiable, Sendable {
    let provider: Provider
    let tokenTotal: Int64
    let percentage: Int

    var id: Provider { provider }
}

struct RichPopoverPresentation: Equatable, Sendable {
    let contentState: RichPopoverContentState
    let statusTitle: String
    let statusSystemImageName: String?
    let statusAccessibilityLabel: String
    let periodTitle: String
    let recencyTitle: String
    let recencyAccessibilityTitle: String
    let headline: String
    let apiValueTitle: String
    let trendRangeTitle: String
    let snapshot: UsageHistorySnapshot?
    let comparisonTitle: String?
    let providerRows: [ProviderSharePresentation]
    let emptyMessage: String?

    static func make(
        state: AppPublishedState,
        startupError: String?,
        relativeTo date: Date
    ) -> RichPopoverPresentation {
        let recency = MenuRecencyPresentation(
            lastUpdated: state.lastUpdated,
            relativeTo: date
        )
        let snapshot = state.historyState.snapshots?[state.selectedHistoryRange]
        let awaitingFirstUsage = state.isImporting
            && state.lastUpdated == nil
            && (state.presentation?.tokenTotal ?? 0) == 0
        let contentState: RichPopoverContentState
        if let startupError {
            contentState = .failed(message: startupError)
        } else if case let .failed(message) = state.lifecycle {
            contentState = .failed(message: message)
        } else if awaitingFirstUsage || state.presentation == nil {
            contentState = .loading
        } else {
            contentState = .ready
        }

        let statusTitle: String
        let statusSystemImageName: String?
        let statusAccessibilityLabel: String
        let headline: String
        let apiValueTitle: String
        switch contentState {
        case .loading:
            statusTitle = ""
            statusSystemImageName = "hourglass"
            statusAccessibilityLabel = "Tokenboard is importing usage"
            headline = "Importing usage…"
            apiValueTitle = "Reading local usage records"
        case .ready:
            statusTitle = state.presentation?.statusTitle ?? "0"
            statusSystemImageName = nil
            statusAccessibilityLabel = "Tokenboard, \(statusTitle)"
            headline = state.presentation?.tokenTitle ?? "0 tokens"
            apiValueTitle = state.presentation?.apiValueTitle ?? "API equivalent unavailable"
        case .failed:
            statusTitle = "Unavailable"
            statusSystemImageName = "exclamationmark.triangle"
            statusAccessibilityLabel = "Tokenboard is unavailable"
            headline = "Usage unavailable"
            apiValueTitle = "Open Settings for diagnostics"
        }

        return RichPopoverPresentation(
            contentState: contentState,
            statusTitle: statusTitle,
            statusSystemImageName: statusSystemImageName,
            statusAccessibilityLabel: statusAccessibilityLabel,
            periodTitle: UsageSelectionPresentation.periodTitle(state.selectedPeriod),
            recencyTitle: recency.visualTitle,
            recencyAccessibilityTitle: recency.accessibilityTitle,
            headline: headline,
            apiValueTitle: apiValueTitle,
            trendRangeTitle: UsageHistoryPresentation.rangeTitle(state.selectedHistoryRange),
            snapshot: snapshot,
            comparisonTitle: snapshot.map { UsageHistoryPresentation.comparisonTitle($0.comparison, range: $0.range) },
            providerRows: providerRows(in: snapshot),
            emptyMessage: snapshot?.breakdown.tokenTotal == 0
                ? "No usage recorded in this range"
                : nil
        )
    }

    private static func providerRows(
        in snapshot: UsageHistorySnapshot?
    ) -> [ProviderSharePresentation] {
        guard let snapshot, snapshot.breakdown.tokenTotal > 0 else { return [] }
        let total = Double(snapshot.breakdown.tokenTotal)
        return snapshot.breakdown.providers.map {
            ProviderSharePresentation(
                provider: $0.provider,
                tokenTotal: $0.tokenTotal,
                percentage: Int((Double($0.tokenTotal) / total * 100).rounded())
            )
        }
    }
}

enum UsageHistoryPresentation {
    static func rangeTitle(_ range: UsageHistoryRange) -> String {
        switch range {
        case .sevenDays: "7D"
        case .thirtyDays: "30D"
        case .ninetyDays: "90D"
        }
    }

    static func rangeDescription(_ range: UsageHistoryRange) -> String {
        switch range {
        case .sevenDays: "Last 7 days"
        case .thirtyDays: "Last 30 days"
        case .ninetyDays: "Last 90 days"
        }
    }

    static func comparisonTitle(
        _ comparison: UsageComparison,
        range: UsageHistoryRange
    ) -> String {
        let suffix = "vs previous \(range.dayCount) days"
        guard let percent = comparison.percentChange else {
            return comparison.currentTokenTotal == 0
                ? "No change \(suffix)"
                : "New activity \(suffix)"
        }
        let rounded = Int(NSDecimalNumber(decimal: percent).doubleValue.rounded())
        if rounded > 0 { return "↑ +\(rounded)% \(suffix)" }
        if rounded < 0 { return "↓ −\(abs(rounded))% \(suffix)" }
        return "→ 0% \(suffix)"
    }

    static func modelTitle(for observedModelID: String) -> String {
        ModelIdentifierPolicy.isOpaqueUnknown(observedModelID)
            ? "Unknown model"
            : observedModelID
    }

    static func tokenCategoryTitle(_ category: UsageTokenCategory) -> String {
        switch category {
        case .input: "Input"
        case .cache: "Cache"
        case .output: "Output"
        }
    }
}
