import AppKit
import Foundation
import XCTest
@testable import TokenboardApp
import TokenboardCore

@MainActor
final class NativePresentationTests: XCTestCase {
    func testMenuBuilderPublishesTheCompleteFinalizedStateInRequiredOrder() {
        let updated = Date(timeIntervalSince1970: 1_775_000_000)
        let summary = UsageSummary(
            period: .thisMonth,
            tokenTotal: 842_198,
            knownAPIEquivalentUSD: Decimal(string: "7.42")!,
            unpricedTokens: 84_000
        )
        var state = AppPublishedState.initial(period: .thisMonth, displayMetric: .apiValue)
        state.lifecycle = .ready
        state.presentation = MenuPresentation(
            summary: summary,
            displayMetric: .apiValue,
            hasHealthWarning: true
        )
        state.sourceHealth = [
            .claudeCode: .healthy(fileCount: 3, lastUpdated: updated),
            .codex: .warning(message: "Some logs need attention")
        ]
        state.sourceFileCounts = [.claudeCode: 3, .codex: 2]
        state.grantedProviders = Set(Provider.allCases)
        state.lastUpdated = updated

        let built = NativeMenuBuilder.makeMenu(state: state, startupError: nil, target: nil)

        XCTAssertEqual(topLevelTitles(built.menu), [
            "842,198 tokens",
            "≈ $7.42 API equivalent",
            "84K unpriced",
            "—",
            "Period",
            "Menu Bar Shows",
            "—",
            "Claude Code: 3 logs",
            "Codex: ⚠ Some logs need attention",
            "Updated never · Local only",
            "—",
            "Refresh Now",
            "Pricing ⚠ 84K unpriced",
            "Settings",
            "—",
            "Quit Tokenboard"
        ])
        XCTAssertEqual(built.statusTitle, "⚠ $7.42+")
        XCTAssertEqual(built.updatedItem.title, "Updated never · Local only")

        let period = built.menu.items[4].submenu!.items
        XCTAssertEqual(period.map(\.title), ["Today", "This Week", "This Month", "This Year", "All Time"])
        XCTAssertEqual(period.map(\.state), [.off, .off, .on, .off, .off])
        let metrics = built.menu.items[5].submenu!.items
        XCTAssertEqual(metrics.map(\.title), ["Tokens", "API Value"])
        XCTAssertEqual(metrics.map(\.state), [.off, .on])
        XCTAssertEqual(built.menu.items[11].keyEquivalent, "r")
        XCTAssertEqual(built.menu.items[13].keyEquivalent, ",")
        XCTAssertEqual(built.menu.items[15].keyEquivalent, "q")
    }

    func testOnboardingCopyAndVisibilityRemainExplicitAndConsentNeutral() throws {
        XCTAssertEqual(
            OnboardingCopy.privacy,
            "Only token counts, model IDs, and timestamps are read. Conversation content is never retained."
        )
        XCTAssertEqual(
            OnboardingCopy.coverageWarning,
            "Tokenboard cannot recover conversations deleted before this first import."
        )

        let setup = try makeModel()
        defer { setup.cleanup() }
        let controller = OnboardingWindowController(model: setup.model)
        controller.update(isRequired: true)
        XCTAssertTrue(controller.window?.isVisible == true)
        controller.update(isRequired: false)
        XCTAssertFalse(controller.window?.isVisible == true)
        XCTAssertFalse(setup.preferences.historicalImportApproved)
    }

    private func topLevelTitles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    private func makeModel() throws -> (model: AppModel, preferences: AppPreferences, cleanup: () -> Void) {
        let suite = "NativePresentationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = AppPreferences(defaults: defaults)
        let model = AppModel(
            ledger: PresentationLedger(),
            queryService: PresentationQuery(),
            coordinator: PresentationCoordinator(),
            pricingInbox: PresentationInbox(),
            grantStore: SourceGrantStore(defaults: defaults, bookmarkAccess: PresentationBookmarkAccess()),
            preferences: preferences,
            bundledCatalogData: Data()
        )
        return (model, preferences, { defaults.removePersistentDomain(forName: suite) })
    }
}

private actor PresentationLedger: AppLedgerRuntime {
    func migrate() {}
    func integrityCheck() {}
    func latestAppliedPricingCatalogJSON() -> Data? { Data() }
    func applyPricingCatalog(
        _ catalog: ValidatedPricingCatalog,
        canonicalJSON: Data,
        origin: String,
        validationSummary: String
    ) {}
}

private actor PresentationQuery: AppUsageQuerying {
    func summary(period: CalendarPeriod, now: Date, calendar: Calendar) -> UsageSummary {
        UsageSummary(period: period, tokenTotal: 0, knownAPIEquivalentUSD: 0, unpricedTokens: 0)
    }
}

private actor PresentationCoordinator: AppIngestionCoordinating {
    func setEventBatchHandler(_ handler: (@Sendable (IngestionBatchResult) -> Void)?) {}
    func start(roots: [Provider: URL]) throws -> IngestionBatchResult {
        IngestionBatchResult(runID: 1, providers: [:])
    }
    func refreshAll() -> IngestionBatchResult { IngestionBatchResult(runID: 1, providers: [:]) }
    func stop() {}
}

private actor PresentationInbox: AppPricingInboxWatching {
    func start() {}
    func stop() {}
}

private final class PresentationBookmarkAccess: SecurityScopedBookmarkAccessing, @unchecked Sendable {
    func makeBookmark(for url: URL, options: URL.BookmarkCreationOptions) -> Data { Data() }
    func resolveBookmark(
        _ data: Data,
        options: URL.BookmarkResolutionOptions
    ) -> ResolvedSourceBookmark {
        ResolvedSourceBookmark(url: URL(fileURLWithPath: "/tmp"), isStale: false)
    }
    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}
