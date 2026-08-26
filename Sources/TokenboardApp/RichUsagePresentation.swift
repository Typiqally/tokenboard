import AppKit
import Foundation
import TokenboardCore

struct RecencyPresentation: Equatable, Sendable {
    let visualTitle: String
    let accessibilityTitle: String

    init(lastUpdated: Date?, relativeTo: Date) {
        guard let lastUpdated else {
            visualTitle = "Updated never"
            accessibilityTitle = "Updated never"
            return
        }

        let visualFormatter = RelativeDateTimeFormatter()
        visualFormatter.unitsStyle = .abbreviated
        let visualRelative = visualFormatter.localizedString(
            for: lastUpdated,
            relativeTo: relativeTo
        )
        visualTitle = "Updated \(visualRelative)"

        let accessibilityFormatter = RelativeDateTimeFormatter()
        accessibilityFormatter.unitsStyle = .full
        let accessibilityRelative = accessibilityFormatter.localizedString(
            for: lastUpdated,
            relativeTo: relativeTo
        )
        accessibilityTitle = "Updated \(accessibilityRelative)"
    }
}

enum TokenboardSurfaceMetrics {
    static let popoverSize = NSSize(width: 350, height: 500)
    static let companionPopoverSize = NSSize(width: 350, height: 596)
    static let companionSceneHeight: CGFloat = 84
    static let popoverContentWidth: CGFloat = 310
    static let providerPercentageWidth: CGFloat = 44
    static let popoverFooterHeight: CGFloat = 52
    static let popoverTopPadding: CGFloat = 16
    static let popoverHeaderSpacing: CGFloat = 16
    static let popoverContentSpacing: CGFloat = 12
    static let historySize = NSSize(width: 760, height: 580)
    static let historyMinimumSize = NSSize(width: 680, height: 520)

    static func popoverSize(companionEnabled: Bool) -> NSSize {
        companionEnabled ? companionPopoverSize : popoverSize
    }
}

enum RichPopoverFooterAction: CaseIterable, Equatable {
    case history
    case settings

    var title: String {
        switch self {
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var systemImageName: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

enum RichPopoverHeaderAction: CaseIterable, Equatable {
    case quit

    var title: String { "Quit Tokenboard" }
    var systemImageName: String { "power" }
}

struct RichPopoverPeriodOption: Equatable, Identifiable {
    let period: CalendarPeriod
    let title: String

    var id: String { period.rawValue }

    static let all = UsageSelectionPresentation.periods.map {
        RichPopoverPeriodOption(
            period: $0,
            title: UsageSelectionPresentation.periodTitle($0)
        )
    }
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

struct UsageComparisonPresentation: Equatable, Sendable {
    let title: String
    let systemImageName: String
    let accessibilityTitle: String
}

struct RichPopoverRefreshPresentation: Equatable, Sendable {
    let isInProgress: Bool
    let title: String
    let accessibilityTitle: String
    let helpTitle: String

    static func make(
        recencyTitle: String,
        recencyAccessibilityTitle: String,
        isRefreshPending: Bool,
        isImporting: Bool
    ) -> RichPopoverRefreshPresentation {
        if isRefreshPending || isImporting {
            return RichPopoverRefreshPresentation(
                isInProgress: true,
                title: "REFRESHING…",
                accessibilityTitle: "Refreshing local usage",
                helpTitle: "Refreshing local usage…"
            )
        }
        return RichPopoverRefreshPresentation(
            isInProgress: false,
            title: recencyTitle.uppercased(),
            accessibilityTitle: "\(recencyAccessibilityTitle). Refresh local usage.",
            helpTitle: "Refresh local usage"
        )
    }
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
    let comparison: UsageComparisonPresentation?
    let providerRows: [ProviderSharePresentation]
    let emptyMessage: String?

    static func make(
        state: AppPublishedState,
        startupError: String?,
        relativeTo date: Date
    ) -> RichPopoverPresentation {
        let recency = RecencyPresentation(
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
            comparison: snapshot.map {
                UsageHistoryPresentation.comparison($0.comparison, range: $0.range)
            },
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
        case .today: "TODAY"
        case .sevenDays: "7D"
        case .thirtyDays: "30D"
        case .ninetyDays: "90D"
        }
    }

    static func rangeDescription(_ range: UsageHistoryRange) -> String {
        switch range {
        case .today: "Today"
        case .sevenDays: "Last 7 days"
        case .thirtyDays: "Last 30 days"
        case .ninetyDays: "Last 90 days"
        }
    }

    static func comparison(
        _ comparison: UsageComparison,
        range: UsageHistoryRange
    ) -> UsageComparisonPresentation {
        let visualSuffix = range == .today
            ? "vs yesterday"
            : "vs previous \(range.dayCount) days"
        let spokenSuffix = range == .today
            ? "from yesterday"
            : "from the previous \(range.dayCount) days"
        guard let percent = comparison.percentChange else {
            if comparison.currentTokenTotal == 0 {
                return UsageComparisonPresentation(
                    title: "No change \(visualSuffix)",
                    systemImageName: "minus",
                    accessibilityTitle: "No usage change \(spokenSuffix)"
                )
            }
            return UsageComparisonPresentation(
                title: "New activity \(visualSuffix)",
                systemImageName: "sparkles",
                accessibilityTitle: "New usage activity \(spokenSuffix)"
            )
        }
        let rounded = Int(NSDecimalNumber(decimal: percent).doubleValue.rounded())
        if rounded > 0 {
            return UsageComparisonPresentation(
                title: "+\(rounded)% \(visualSuffix)",
                systemImageName: "arrow.up.right",
                accessibilityTitle: "Usage increased \(rounded) percent \(spokenSuffix)"
            )
        }
        if rounded < 0 {
            return UsageComparisonPresentation(
                title: "−\(abs(rounded))% \(visualSuffix)",
                systemImageName: "arrow.down.right",
                accessibilityTitle: "Usage decreased \(abs(rounded)) percent \(spokenSuffix)"
            )
        }
        return UsageComparisonPresentation(
            title: "No change \(visualSuffix)",
            systemImageName: "minus",
            accessibilityTitle: "No usage change \(spokenSuffix)"
        )
    }

    static func chartAccessibilityLabel(for range: UsageHistoryRange) -> String {
        if range == .today { return "Hourly token usage for today" }
        return "Daily token usage for the \(rangeDescription(range).lowercased())"
    }

    static func axisTitle(_ tokenTotal: Int64) -> String {
        ValueFormatter.compactTokens(tokenTotal)
    }

    static func providerCountTitle(_ count: Int) -> String {
        "\(count) \(count == 1 ? "source" : "sources")"
    }

    static func modelCountTitle(_ count: Int) -> String {
        "\(count) \(count == 1 ? "model" : "models")"
    }

    static let tokenTypeSummary = "Input · Cache · Output"

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
