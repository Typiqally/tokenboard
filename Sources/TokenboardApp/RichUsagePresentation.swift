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
    static let popoverSize = NSSize(width: 350, height: 560)
    static let companionPopoverSize = NSSize(width: 350, height: 656)
    /// The approved B2 panorama merges the header and headline into the
    /// companion world instead of adding another strip to the popover.
    static let companionPanoramaHeight: CGFloat = 236
    /// The live NSPopover needs more breathing room than the flat browser
    /// mockup around its arrow and rounded top edge.
    static let companionHUDTopPadding: CGFloat = 24
    static let companionHUDSpacing: CGFloat = 11
    static let companionHeadlineFontSize: CGFloat = 27
    static let companionSubtitleFontSize: CGFloat = 13
    static let companionBottomFadeHeight: CGFloat = 44
    static let companionFooterSeparatorOpacity = 0.36
    static let companionFooterContentOffset: CGFloat = -1
    /// The original scene height remains the reference scale for subjects,
    /// particles, and Settings thumbnails.
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

struct PopoverChartSelection: Equatable {
    private(set) var hoveredPointID: String?
    private(set) var pinnedPointID: String?

    var selectedPointID: String? { pinnedPointID ?? hoveredPointID }
    var isPinned: Bool { pinnedPointID != nil }

    mutating func hover(_ pointID: String?) {
        hoveredPointID = pointID
    }

    mutating func clearHover() {
        hoveredPointID = nil
    }

    mutating func togglePin(_ pointID: String) {
        pinnedPointID = pinnedPointID == pointID ? nil : pointID
    }

    mutating func clearAll() {
        hoveredPointID = nil
        pinnedPointID = nil
    }
}

struct WorkPatternPreviewMetric: Equatable, Sendable {
    let title: String
    let value: String
}

struct WorkPatternPreviewPresentation: Equatable, Sendable {
    let title: String
    let metrics: [WorkPatternPreviewMetric]
    let accessibilityTitle: String

    static func make(
        _ snapshot: WorkPatternSnapshot?,
        range: UsageHistoryRange
    ) -> WorkPatternPreviewPresentation? {
        guard let snapshot else { return nil }
        let peakHour = snapshot.volumePeakHour.map { UsageHistoryPresentation.hourTitle($0.hour) }
            ?? "—"
        let title = "WORK PATTERNS · \(UsageHistoryPresentation.rangeTitle(range))"
        if range == .today {
            let metrics = [
                WorkPatternPreviewMetric(
                    title: "ACTIVE HOURS",
                    value: "\(snapshot.totalActiveHours)"
                ),
                WorkPatternPreviewMetric(title: "PEAK HOUR", value: peakHour),
                WorkPatternPreviewMetric(
                    title: "LONGEST RUN",
                    value: "\(snapshot.longestActiveRunHours)h"
                ),
            ]
            return WorkPatternPreviewPresentation(
                title: title,
                metrics: metrics,
                accessibilityTitle: "Work patterns for today. \(snapshot.totalActiveHours) active hours. Peak hour \(peakHour). Longest active run \(snapshot.longestActiveRunHours) hours. Open Work Patterns."
            )
        }
        let average = snapshot.averageActiveHoursPerActiveDay.map(oneDecimal) ?? "—"
        let weekday = snapshot.volumePeakWeekday.map {
            UsageHistoryPresentation.shortWeekdayTitle($0.weekday)
        } ?? "—"
        let spokenWeekday = snapshot.volumePeakWeekday.map {
            UsageHistoryPresentation.weekdayTitle($0.weekday)
        } ?? "unavailable"
        let metrics = [
            WorkPatternPreviewMetric(title: "AVG HOURS", value: average == "—" ? average : "\(average)h"),
            WorkPatternPreviewMetric(title: "PEAK HOUR", value: peakHour),
            WorkPatternPreviewMetric(title: "PEAK DAY", value: weekday),
        ]
        return WorkPatternPreviewPresentation(
            title: title,
            metrics: metrics,
            accessibilityTitle: "Work patterns for the \(UsageHistoryPresentation.rangeDescription(range).lowercased()). Average \(average) active hours per active day. Peak hour \(peakHour). Peak day \(spokenWeekday). Open Work Patterns."
        )
    }

    private static func oneDecimal(_ value: Decimal) -> String {
        let behavior = NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: 1,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )
        return NSDecimalNumber(decimal: value)
            .rounding(accordingToBehavior: behavior)
            .stringValue
    }
}

struct UsagePointCalloutPresentation: Equatable, Sendable {
    let contextTitle: String
    let tokenTitle: String
    let apiValueTitle: String
    let accessibilityTitle: String

    static func make(
        point: UsageHistoryPoint,
        range: UsageHistoryRange,
        currency: DisplayCurrency
    ) -> UsagePointCalloutPresentation {
        let context = UsageHistoryPresentation.pointContextTitle(point, range: range)
        let tokens = "\(ValueFormatter.exactTokens(point.tokenTotal)) tokens"
        let apiValue = point.breakdown.map {
            UsageHistoryPresentation.apiEquivalentTitle(for: $0, currency: currency)
        } ?? "API equivalent unavailable"
        return UsagePointCalloutPresentation(
            contextTitle: context,
            tokenTitle: tokens,
            apiValueTitle: apiValue,
            accessibilityTitle: "\(context). \(tokens). \(apiValue)."
        )
    }
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
    let workPatternPreview: WorkPatternPreviewPresentation?
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
            workPatternPreview: WorkPatternPreviewPresentation.make(
                snapshot?.workPatterns,
                range: state.selectedHistoryRange
            ),
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
        var source = percent
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 0, .plain)
        let magnitude = rounded < 0 ? -rounded : rounded
        let formatted = NSDecimalNumber(decimal: magnitude).stringValue
        if rounded > 0 {
            return UsageComparisonPresentation(
                title: "+\(formatted)% \(visualSuffix)",
                systemImageName: "arrow.up.right",
                accessibilityTitle: "Usage increased \(formatted) percent \(spokenSuffix)"
            )
        }
        if rounded < 0 {
            return UsageComparisonPresentation(
                title: "−\(formatted)% \(visualSuffix)",
                systemImageName: "arrow.down.right",
                accessibilityTitle: "Usage decreased \(formatted) percent \(spokenSuffix)"
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

    static func hourTitle(_ hour: Int) -> String {
        String(format: "%02d:00", locale: Locale(identifier: "en_US_POSIX"), hour)
    }

    static func weekdayTitle(_ weekday: WorkWeekday) -> String {
        switch weekday {
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        case .sunday: "Sunday"
        }
    }

    static func shortWeekdayTitle(_ weekday: WorkWeekday) -> String {
        String(weekdayTitle(weekday).prefix(3))
    }

    static func pointContextTitle(
        _ point: UsageHistoryPoint,
        range: UsageHistoryRange
    ) -> String {
        guard range == .today, let hourStart = point.hourStart else {
            return shortDate(point.localDay)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: point.localDay.timeZoneIdentifier) ?? .current
        let start = calendar.component(.hour, from: hourStart)
        let end = (start + 1) % 24
        return "\(hourTitle(start))–\(hourTitle(end))"
    }
}
