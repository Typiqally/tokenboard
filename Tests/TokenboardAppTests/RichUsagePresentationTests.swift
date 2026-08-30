import AppKit
import Foundation
import XCTest
@testable import TokenboardApp
import TokenboardCore

@MainActor
final class RichUsagePresentationTests: XCTestCase {
    func testFirstImportUsesActivityInsteadOfAZeroHeadline() {
        var state = AppPublishedState.initial(period: .thisMonth, displayMetric: .tokens)
        state.lifecycle = .ready
        state.isImporting = true

        let presentation = RichPopoverPresentation.make(
            state: state,
            startupError: nil,
            relativeTo: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(presentation.contentState, .loading)
        XCTAssertEqual(presentation.statusTitle, "")
        XCTAssertEqual(presentation.statusSystemImageName, "hourglass")
        XCTAssertEqual(presentation.headline, "Importing usage…")
        XCTAssertFalse(presentation.headline.contains("0"))
    }

    func testRefreshControlDisablesImmediatelyForPendingAndActiveRefreshes() {
        let idle = RichPopoverRefreshPresentation.make(
            recencyTitle: "Updated 2s ago",
            recencyAccessibilityTitle: "Updated 2 seconds ago",
            isRefreshPending: false,
            isImporting: false
        )
        let pending = RichPopoverRefreshPresentation.make(
            recencyTitle: "Updated 2s ago",
            recencyAccessibilityTitle: "Updated 2 seconds ago",
            isRefreshPending: true,
            isImporting: false
        )
        let importing = RichPopoverRefreshPresentation.make(
            recencyTitle: "Updated 2s ago",
            recencyAccessibilityTitle: "Updated 2 seconds ago",
            isRefreshPending: false,
            isImporting: true
        )

        XCTAssertEqual(idle, RichPopoverRefreshPresentation(
            isInProgress: false,
            title: "UPDATED 2S AGO",
            accessibilityTitle: "Updated 2 seconds ago. Refresh local usage.",
            helpTitle: "Refresh local usage"
        ))
        for active in [pending, importing] {
            XCTAssertEqual(active, RichPopoverRefreshPresentation(
                isInProgress: true,
                title: "REFRESHING…",
                accessibilityTitle: "Refreshing local usage",
                helpTitle: "Refreshing local usage…"
            ))
        }
    }

    func testCompletedEmptyImportShowsAnExplicitZero() {
        var state = AppPublishedState.initial(period: .today, displayMetric: .tokens)
        state.lifecycle = .ready
        state.presentation = MenuPresentation(
            summary: UsageSummary(
                period: .today,
                tokenTotal: 0,
                knownAPIEquivalentUSD: 0,
                unpricedTokens: 0
            ),
            displayMetric: .tokens
        )
        state.historyState = .loaded([.thirtyDays: snapshot(tokenTotal: 0)])

        let presentation = RichPopoverPresentation.make(
            state: state,
            startupError: nil,
            relativeTo: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(presentation.contentState, .ready)
        XCTAssertEqual(presentation.statusTitle, "0")
        XCTAssertEqual(presentation.headline, "0 tokens")
        XCTAssertEqual(presentation.emptyMessage, "No usage recorded in this range")
    }

    func testComparisonFormatsExtremePercentWithoutIntegerConversion() {
        let percent = Decimal(Int64.max) * 100
        let presentation = UsageHistoryPresentation.comparison(
            UsageComparison(
                currentTokenTotal: Int64.max,
                previousTokenTotal: 1,
                tokenDelta: Int64.max - 1,
                percentChange: percent
            ),
            range: .today
        )

        XCTAssertEqual(
            presentation.title,
            "+922337203685477580700% vs yesterday"
        )
    }

    func testStartupFailureIsNeverPresentedAsLoading() {
        var state = AppPublishedState.initial(period: .today, displayMetric: .tokens)
        state.lifecycle = .failed(message: "Ledger could not be opened")

        let presentation = RichPopoverPresentation.make(
            state: state,
            startupError: nil,
            relativeTo: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(
            presentation.contentState,
            .failed(message: "Ledger could not be opened")
        )
        XCTAssertEqual(presentation.statusTitle, "Unavailable")
    }

    func testProviderRowsUseTheSelectedTrendSnapshot() throws {
        var state = AppPublishedState.initial(period: .thisMonth, displayMetric: .tokens)
        state.lifecycle = .ready
        state.selectedHistoryRange = .sevenDays
        state.presentation = MenuPresentation(
            summary: UsageSummary(
                period: .thisMonth,
                tokenTotal: 1_000,
                knownAPIEquivalentUSD: 4,
                unpricedTokens: 0
            ),
            displayMetric: .tokens
        )
        state.historyState = .loaded([.sevenDays: snapshot(tokenTotal: 1_000)])

        let presentation = RichPopoverPresentation.make(
            state: state,
            startupError: nil,
            relativeTo: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(presentation.periodTitle, "This Month")
        XCTAssertEqual(presentation.trendRangeTitle, "7D")
        XCTAssertEqual(presentation.comparison, UsageComparisonPresentation(
            title: "+25% vs previous 7 days",
            systemImageName: "arrow.up.right",
            accessibilityTitle: "Usage increased 25 percent from the previous 7 days"
        ))
        XCTAssertEqual(presentation.providerRows, [
            ProviderSharePresentation(provider: .claudeCode, tokenTotal: 680, percentage: 68),
            ProviderSharePresentation(provider: .codex, tokenTotal: 320, percentage: 32)
        ])
    }

    func testComparisonPresentationUsesNativeSymbolsAndPlainLanguage() {
        XCTAssertEqual(
            UsageHistoryPresentation.comparison(
                UsageComparison(
                    currentTokenTotal: 900,
                    previousTokenTotal: 600,
                    tokenDelta: 300,
                    percentChange: 50
                ),
                range: .today
            ),
            UsageComparisonPresentation(
                title: "+50% vs yesterday",
                systemImageName: "arrow.up.right",
                accessibilityTitle: "Usage increased 50 percent from yesterday"
            )
        )
        XCTAssertEqual(
            UsageHistoryPresentation.comparison(
                UsageComparison(
                    currentTokenTotal: 600,
                    previousTokenTotal: 800,
                    tokenDelta: -200,
                    percentChange: -25
                ),
                range: .sevenDays
            ),
            UsageComparisonPresentation(
                title: "−25% vs previous 7 days",
                systemImageName: "arrow.down.right",
                accessibilityTitle: "Usage decreased 25 percent from the previous 7 days"
            )
        )
        XCTAssertEqual(
            UsageHistoryPresentation.comparison(
                UsageComparison(
                    currentTokenTotal: 0,
                    previousTokenTotal: 0,
                    tokenDelta: 0,
                    percentChange: nil
                ),
                range: .thirtyDays
            ),
            UsageComparisonPresentation(
                title: "No change vs previous 30 days",
                systemImageName: "minus",
                accessibilityTitle: "No usage change from the previous 30 days"
            )
        )
    }

    func testChartAccessibilityLabelNamesTheSelectedRange() {
        XCTAssertEqual(
            UsageHistoryPresentation.chartAccessibilityLabel(for: .today),
            "Hourly token usage for today"
        )
        XCTAssertEqual(
            UsageHistoryPresentation.chartAccessibilityLabel(for: .ninetyDays),
            "Daily token usage for the last 90 days"
        )
    }

    func testHistoryDisclosureMasksOpaqueModelIdentifiers() {
        let opaque = "unknown-" + String(repeating: "a", count: 64)

        XCTAssertEqual(UsageHistoryPresentation.modelTitle(for: opaque), "Unknown model")
        XCTAssertEqual(UsageHistoryPresentation.modelTitle(for: "gpt-5"), "gpt-5")
        XCTAssertEqual(UsageHistoryPresentation.tokenCategoryTitle(.input), "Input")
        XCTAssertEqual(UsageHistoryPresentation.tokenCategoryTitle(.cache), "Cache")
        XCTAssertEqual(UsageHistoryPresentation.tokenCategoryTitle(.output), "Output")
    }

    func testApprovedSurfaceDimensionsStayCompactAndRelated() {
        XCTAssertEqual(TokenboardSurfaceMetrics.popoverSize, NSSize(width: 350, height: 560))
        XCTAssertEqual(TokenboardSurfaceMetrics.companionPopoverSize, NSSize(width: 350, height: 656))
        XCTAssertEqual(TokenboardSurfaceMetrics.popoverSize(companionEnabled: false), NSSize(width: 350, height: 560))
        XCTAssertEqual(TokenboardSurfaceMetrics.popoverSize(companionEnabled: true), NSSize(width: 350, height: 656))
        XCTAssertEqual(TokenboardSurfaceMetrics.companionSceneHeight, 84)
        XCTAssertEqual(TokenboardSurfaceMetrics.companionPanoramaHeight, 236)
        XCTAssertEqual(TokenboardSurfaceMetrics.companionHUDTopPadding, 24)
        XCTAssertEqual(TokenboardSurfaceMetrics.companionHUDSpacing, 11)
        XCTAssertEqual(TokenboardSurfaceMetrics.companionHeadlineFontSize, 27)
        XCTAssertEqual(TokenboardSurfaceMetrics.companionSubtitleFontSize, 13)
        XCTAssertEqual(TokenboardSurfaceMetrics.companionBottomFadeHeight, 44)
        XCTAssertEqual(TokenboardSurfaceMetrics.companionFooterSeparatorOpacity, 0.36)
        XCTAssertEqual(TokenboardSurfaceMetrics.companionFooterContentOffset, -1)
        XCTAssertEqual(TokenboardSurfaceMetrics.popoverContentWidth, 310)
        XCTAssertEqual(TokenboardSurfaceMetrics.providerPercentageWidth, 44)
        XCTAssertEqual(TokenboardSurfaceMetrics.popoverFooterHeight, 52)
        XCTAssertEqual(TokenboardSurfaceMetrics.popoverTopPadding, 16)
        XCTAssertEqual(TokenboardSurfaceMetrics.popoverHeaderSpacing, 16)
        XCTAssertEqual(TokenboardSurfaceMetrics.popoverContentSpacing, 12)
        XCTAssertEqual(TokenboardSurfaceMetrics.historySize, NSSize(width: 760, height: 580))
        XCTAssertEqual(TokenboardSurfaceMetrics.historyMinimumSize, NSSize(width: 680, height: 520))
    }

    func testRangeControlFillsItsAssignedWidthWithEqualNativeSegments() {
        let control = UsageRangePicker.makeNativeControl()

        XCTAssertEqual(control.segmentCount, 4)
        XCTAssertEqual(control.trackingMode, .selectOne)
        XCTAssertEqual(control.segmentDistribution, .fillEqually)
        XCTAssertEqual(control.controlSize, .large)
        XCTAssertEqual(
            (0..<control.segmentCount).map(control.label(forSegment:)),
            ["TODAY", "7D", "30D", "90D"]
        )
        XCTAssertEqual(UsageHistoryPresentation.rangeDescription(.today), "Today")
    }

    func testPopoverKeepsNavigationInTheFooterAndQuitInTheHeader() {
        XCTAssertEqual(
            RichPopoverFooterAction.allCases,
            [.history, .settings]
        )
        XCTAssertEqual(
            RichPopoverFooterAction.allCases.map(\.title),
            ["History", "Settings"]
        )
        XCTAssertEqual(
            RichPopoverHeaderAction.allCases,
            [.quit]
        )
        XCTAssertEqual(
            RichPopoverHeaderAction.quit.systemImageName,
            "power"
        )
    }

    func testPopoverChartSelectionHoversPinsAndClearsWithoutChangingRangeState() {
        var selection = PopoverChartSelection()

        selection.hover("day:2026-08-10")
        XCTAssertEqual(selection.selectedPointID, "day:2026-08-10")
        XCTAssertFalse(selection.isPinned)

        selection.togglePin("day:2026-08-10")
        selection.hover("day:2026-08-11")
        XCTAssertEqual(selection.selectedPointID, "day:2026-08-10")
        XCTAssertTrue(selection.isPinned)

        selection.togglePin("day:2026-08-10")
        XCTAssertEqual(selection.selectedPointID, "day:2026-08-11")
        selection.clearHover()
        XCTAssertNil(selection.selectedPointID)

        selection.hover("day:2026-08-09")
        selection.clearAll()
        XCTAssertNil(selection.selectedPointID)
        XCTAssertFalse(selection.isPinned)
    }

    func testWorkPatternPreviewUsesRangeSpecificMetricsAndHonestLabels() throws {
        let workPatterns = try makeWorkPatterns()

        XCTAssertEqual(
            WorkPatternPreviewPresentation.make(workPatterns, range: .thirtyDays),
            WorkPatternPreviewPresentation(
                title: "WORK PATTERNS · 30D",
                metrics: [
                    WorkPatternPreviewMetric(title: "AVG HOURS", value: "1.3h"),
                    WorkPatternPreviewMetric(title: "PEAK HOUR", value: "15:00"),
                    WorkPatternPreviewMetric(title: "PEAK DAY", value: "Tue"),
                ],
                accessibilityTitle: "Work patterns for the last 30 days. Average 1.3 active hours per active day. Peak hour 15:00. Peak day Tuesday. Open Work Patterns."
            )
        )

        XCTAssertEqual(
            WorkPatternPreviewPresentation.make(workPatterns, range: .today)?.metrics,
            [
                WorkPatternPreviewMetric(title: "ACTIVE HOURS", value: "5"),
                WorkPatternPreviewMetric(title: "PEAK HOUR", value: "15:00"),
                WorkPatternPreviewMetric(title: "LONGEST RUN", value: "2h"),
            ]
        )
    }

    func testUsagePointCalloutPresentsExactPointWithoutChangingTheSnapshot() {
        let day = LocalDay(date: Date(timeIntervalSince1970: 0), calendar: .current)
        let point = UsageHistoryPoint(localDay: day, tokenTotal: 12_345)

        let callout = UsagePointCalloutPresentation.make(
            point: point,
            range: .sevenDays,
            currency: .usd
        )

        XCTAssertEqual(callout.tokenTitle, "12,345 tokens")
        XCTAssertEqual(callout.apiValueTitle, "API equivalent unavailable")
        XCTAssertTrue(callout.accessibilityTitle.contains("12,345 tokens"))
    }

    func testHistoryRequestCanOpenDirectlyIntoWorkPatterns() {
        XCTAssertEqual(
            HistoryOpenRequest(provider: nil, range: .thirtyDays, section: .workPatterns).section,
            .workPatterns
        )
        XCTAssertEqual(
            HistoryOpenRequest(provider: .codex, range: .sevenDays).section,
            .usage
        )
    }

    func testPopoverPeriodMenuUsesPlainOptionsInStableOrder() {
        XCTAssertEqual(
            RichPopoverPeriodOption.all.map(\.title),
            ["Today", "This Week", "This Month", "This Year", "All Time"]
        )
    }

    func testHistoryDisclosuresStartCollapsedWithCompactSummaries() {
        XCTAssertEqual(
            HistoryDisclosureExpansion.initial,
            HistoryDisclosureExpansion(
                providers: false,
                models: false,
                tokenTypes: false
            )
        )
        XCTAssertEqual(UsageHistoryPresentation.providerCountTitle(1), "1 source")
        XCTAssertEqual(UsageHistoryPresentation.providerCountTitle(2), "2 sources")
        XCTAssertEqual(UsageHistoryPresentation.modelCountTitle(4), "4 models")
        XCTAssertEqual(
            UsageHistoryPresentation.tokenTypeSummary,
            "Input · Cache · Output"
        )
    }

    func testHistoryAxisLabelsUseReadableCompactTokenTitles() {
        XCTAssertEqual(UsageHistoryPresentation.axisTitle(0), "0")
        XCTAssertEqual(UsageHistoryPresentation.axisTitle(6_000_000_000), "6B")
    }

    func testProviderRowsUseOfficialLocalBrandMarks() throws {
        XCTAssertEqual(Provider.codex.brandMark, .openAI)
        XCTAssertEqual(Provider.claudeCode.brandMark, .claude)

        for provider in Provider.allCases {
            let image = try XCTUnwrap(ProviderBrandAssets.image(for: provider.brandMark))
            XCTAssertTrue(image.isTemplate)
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertGreaterThan(image.size.height, 0)
        }
    }

    private func snapshot(tokenTotal: Int64) -> UsageHistorySnapshot {
        let interval = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 1)
        return UsageHistorySnapshot(
            range: .sevenDays,
            provider: nil,
            currentInterval: interval,
            previousInterval: interval,
            points: [],
            comparison: UsageComparison(
                currentTokenTotal: tokenTotal,
                previousTokenTotal: 800,
                tokenDelta: 200,
                percentChange: 25
            ),
            breakdown: UsageBreakdown(
                tokenTotal: tokenTotal,
                knownAPIEquivalentUSD: 4,
                unpricedTokens: 0,
                exchangeRates: nil,
                providers: tokenTotal == 0 ? [] : [
                    ProviderUsageBreakdown(provider: .claudeCode, tokenTotal: 680),
                    ProviderUsageBreakdown(provider: .codex, tokenTotal: 320)
                ],
                models: [],
                tokenTypes: []
            )
        )
    }

    private func makeWorkPatterns() throws -> WorkPatternSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let date: (String) -> Date = { ISO8601DateFormatter().date(from: $0)! }
        let current = DateInterval(
            start: date("2026-08-03T00:00:00Z"),
            end: date("2026-08-17T00:00:00Z")
        )
        return try WorkPatternCalculator().make(
            currentRows: [
                HourlyUsageRow(
                    hourStart: date("2026-08-03T07:00:00Z"),
                    localDay: LocalDay(date: date("2026-08-03T07:00:00Z"), calendar: calendar),
                    provider: .codex,
                    observedModelID: "synthetic-model",
                    metric: .inputUncached,
                    aggregation: .additive,
                    quantity: 100
                ),
                HourlyUsageRow(
                    hourStart: date("2026-08-04T13:00:00Z"),
                    localDay: LocalDay(date: date("2026-08-04T13:00:00Z"), calendar: calendar),
                    provider: .codex,
                    observedModelID: "synthetic-model",
                    metric: .output,
                    aggregation: .additive,
                    quantity: 500
                ),
                HourlyUsageRow(
                    hourStart: date("2026-08-10T07:00:00Z"),
                    localDay: LocalDay(date: date("2026-08-10T07:00:00Z"), calendar: calendar),
                    provider: .codex,
                    observedModelID: "synthetic-model",
                    metric: .output,
                    aggregation: .additive,
                    quantity: 50
                ),
                HourlyUsageRow(
                    hourStart: date("2026-08-10T08:00:00Z"),
                    localDay: LocalDay(date: date("2026-08-10T08:00:00Z"), calendar: calendar),
                    provider: .codex,
                    observedModelID: "synthetic-model",
                    metric: .output,
                    aggregation: .additive,
                    quantity: 20
                ),
                HourlyUsageRow(
                    hourStart: date("2026-08-11T07:00:00Z"),
                    localDay: LocalDay(date: date("2026-08-11T07:00:00Z"), calendar: calendar),
                    provider: .codex,
                    observedModelID: "synthetic-model",
                    metric: .output,
                    aggregation: .additive,
                    quantity: 10
                ),
            ],
            previousRows: [],
            currentInterval: current,
            previousInterval: DateInterval(
                start: date("2026-07-20T00:00:00Z"),
                end: date("2026-08-03T00:00:00Z")
            ),
            coverageStart: date("2026-07-01T00:00:00Z"),
            now: current.end.addingTimeInterval(-1),
            calendar: calendar
        )
    }
}
