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
        XCTAssertEqual(TokenboardSurfaceMetrics.popoverSize, NSSize(width: 370, height: 560))
        XCTAssertEqual(TokenboardSurfaceMetrics.historySize, NSSize(width: 760, height: 580))
        XCTAssertEqual(TokenboardSurfaceMetrics.historyMinimumSize, NSSize(width: 680, height: 520))
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
}
