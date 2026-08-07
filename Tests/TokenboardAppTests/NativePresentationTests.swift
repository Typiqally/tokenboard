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
            .codex: .warning(issue: .importFailure, message: "Some logs need attention")
        ]
        state.sourceFileCounts = [.claudeCode: 3, .codex: 2]
        state.grantedProviders = Set(Provider.allCases)
        state.lastUpdated = updated

        let built = NativeMenuBuilder.makeMenu(
            state: state,
            startupError: nil,
            target: nil
        )

        XCTAssertEqual(topLevelTitles(built.menu), [
            "842,198 tokens",
            "≈ $7.42 API equivalent",
            "—",
            "Period: This Month",
            "Menu Bar: API Value",
            "—",
            "Updated never",
            "—",
            "Refresh Now",
            "Pricing (84K unpriced)",
            "Settings",
            "—",
            "Quit Tokenboard"
        ])
        XCTAssertEqual(built.statusTitle, "⚠ $7.42+")
        XCTAssertEqual(built.updatedItem.title, "Updated never")

        let period = built.menu.items[3].submenu!.items
        XCTAssertEqual(period.map(\.title), ["Today", "This Week", "This Month", "This Year", "All Time"])
        XCTAssertEqual(period.map(\.state), [.off, .off, .on, .off, .off])
        let metrics = built.menu.items[4].submenu!.items
        XCTAssertEqual(metrics.map(\.title), ["Tokens", "API Value"])
        XCTAssertEqual(metrics.map(\.state), [.off, .on])
        XCTAssertEqual(built.menu.items[8].keyEquivalent, "r")
        XCTAssertEqual(built.menu.items[10].keyEquivalent, ",")
        XCTAssertEqual(built.menu.items[12].keyEquivalent, "q")
    }

    func testMenuOmitsWarningDetailsAndDismissAction() throws {
        let setup = try makeModel()
        defer { setup.cleanup() }
        let summary = UsageSummary(
            period: .thisMonth,
            tokenTotal: 1_000_000,
            knownAPIEquivalentUSD: Decimal(string: "3.00")!,
            unpricedTokens: 84_000
        )
        setup.model.lastSummary = summary
        var state = AppPublishedState.initial(period: .thisMonth, displayMetric: .apiValue)
        state.lifecycle = .ready
        state.sourceHealth = [
            .claudeCode: .warning(
                issue: .truncatedLog,
                message: TokenboardHealth.Issue.truncatedLog.message
            ),
            .codex: .healthy(fileCount: 2, lastUpdated: .distantPast)
        ]
        state.presentation = setup.model.makePresentation(summary: summary, state: state)
        setup.model.commitState(state)
        let controller = MenuController(model: setup.model)

        XCTAssertEqual(controller.renderedStatusTitle, "⚠ $3.00+")
        XCTAssertFalse(controller.renderedMenu?.items.contains {
            $0.title.hasPrefix("Warnings (")
        } == true)
        XCTAssertFalse(controller.responds(to: NSSelectorFromString("dismissCurrentWarnings")))
        XCTAssertNotNil(controller.renderedMenu?.item(withTitle: "Pricing (84K unpriced)"))
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

    func testMenuControllerRendersEmittedSnapshotAndWiresRealSelectorsAndValues() async throws {
        let setup = try makeModel()
        defer { setup.cleanup() }
        let controller = MenuController(model: setup.model)
        var emitted = AppPublishedState.initial(period: .thisWeek, displayMetric: .tokens)
        emitted.lifecycle = .ready
        emitted.presentation = MenuPresentation(
            summary: UsageSummary(
                period: .thisWeek,
                tokenTotal: 456,
                knownAPIEquivalentUSD: 0,
                unpricedTokens: 0
            ),
            displayMetric: .tokens,
            hasHealthWarning: false
        )

        setup.model.commitState(emitted)

        XCTAssertEqual(controller.renderedMenu?.items.first?.title, "456 tokens")
        XCTAssertEqual(controller.renderedStatusTitle, "◉ 456")
        let periodParent = controller.renderedMenu?.items.first(where: { $0.title == "Period: This Week" })
        let year = periodParent?.submenu?.items.first(where: { $0.title == "This Year" })
        XCTAssertEqual(year?.representedObject as? String, "this_year")
        XCTAssertEqual(year?.target as? MenuController, controller)
        XCTAssertEqual(year?.action, NSSelectorFromString("selectPeriod:"))
        XCTAssertTrue(controller.responds(to: NSSelectorFromString("selectPeriod:")))

        guard let year else { return XCTFail("missing This Year menu action") }
        _ = controller.perform(NSSelectorFromString("selectPeriod:"), with: year)
        await waitUntil { setup.preferences.selectedPeriod == .thisYear }
        XCTAssertEqual(setup.model.state.selectedPeriod, .thisYear)

        let metricParent = controller.renderedMenu?.items.first {
            $0.title == "Menu Bar: Tokens"
        }
        let apiValue = metricParent?.submenu?.items.first { $0.title == "API Value" }
        XCTAssertEqual(apiValue?.representedObject as? String, "api_value")
        XCTAssertEqual(apiValue?.target as? MenuController, controller)
        XCTAssertEqual(apiValue?.action, NSSelectorFromString("selectDisplayMetric:"))
        XCTAssertTrue(controller.responds(to: NSSelectorFromString("selectDisplayMetric:")))
        guard let apiValue else { return XCTFail("missing API Value menu action") }
        _ = controller.perform(NSSelectorFromString("selectDisplayMetric:"), with: apiValue)
        await waitUntil { setup.preferences.selectedDisplayMetric == .apiValue }
        XCTAssertEqual(setup.model.state.selectedDisplayMetric, .apiValue)

        let refresh = controller.renderedMenu?.items.first { $0.title == "Refresh Now" }
        XCTAssertEqual(refresh?.target as? MenuController, controller)
        XCTAssertEqual(refresh?.action, NSSelectorFromString("refresh"))
        XCTAssertTrue(controller.responds(to: NSSelectorFromString("refresh")))
        let quit = controller.renderedMenu?.items.first { $0.title == "Quit Tokenboard" }
        XCTAssertEqual(quit?.target as? MenuController, controller)
        XCTAssertEqual(quit?.action, NSSelectorFromString("quit"))
        XCTAssertTrue(controller.responds(to: NSSelectorFromString("quit")))

        var openedPricing = false
        var openedSettings = false
        setup.model.onOpenPricing = { openedPricing = true }
        setup.model.onOpenSettings = { openedSettings = true }
        _ = controller.perform(NSSelectorFromString("openPricing"))
        _ = controller.perform(NSSelectorFromString("openSettings"))
        XCTAssertTrue(openedPricing)
        XCTAssertTrue(openedSettings)
    }

    func testOnboardingRenderedActionsRespectApprovalReadinessAndImportState() throws {
        let setup = try makeModel()
        defer { setup.cleanup() }
        var state = AppPublishedState.initial(period: .today, displayMetric: .tokens)
        state.lifecycle = .ready
        state.grantedProviders = Set(Provider.allCases)
        state.historicalImportApproved = false
        setup.model.commitState(state)

        var rendered = OnboardingView(model: setup.model).actionState
        XCTAssertTrue(rendered.canStartHistoricalImport)
        XCTAssertTrue(rendered.canSelectSources)

        state.historicalImportApproved = true
        setup.model.commitState(state)
        rendered = OnboardingView(model: setup.model).actionState
        XCTAssertFalse(rendered.canStartHistoricalImport)
        XCTAssertTrue(rendered.canSelectSources)

        state.isImporting = true
        setup.model.commitState(state)
        rendered = OnboardingView(model: setup.model).actionState
        XCTAssertFalse(rendered.canStartHistoricalImport)
        XCTAssertFalse(rendered.canSelectSources)
    }

    private func topLevelTitles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if condition() { return }
            try? await clock.sleep(for: .milliseconds(1))
        }
        XCTFail("condition was not met")
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
            bundledCatalogData: Data(),
            applicationPaths: ApplicationPaths(
                root: URL(fileURLWithPath: "/tmp/\(suite)-support", isDirectory: true)
            )
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
    func pricingSnapshot() -> PricingSnapshot {
        PricingSnapshot(catalogIDs: [], rates: [], aliases: [])
    }
    func usageRows(in interval: DateInterval?, calendar: Calendar) -> [DailyUsageRow] { [] }
    func skippedRecordCount() -> Int { 0 }
}

private actor PresentationQuery: AppUsageQuerying {
    func summary(period: CalendarPeriod, now: Date, calendar: Calendar) -> UsageSummary {
        UsageSummary(period: period, tokenTotal: 0, knownAPIEquivalentUSD: 0, unpricedTokens: 0)
    }
}

private actor PresentationCoordinator: AppIngestionCoordinating {
    func results() -> AsyncStream<IngestionBatchResult> {
        AsyncStream { _ in }
    }
    func start(roots: [Provider: URL]) throws -> IngestionBatchResult {
        IngestionBatchResult(runID: 1, sequence: 1, scope: .inventory, providers: [:])
    }
    func startMonitoring(roots: [Provider: URL]) throws -> IngestionBatchResult {
        try start(roots: roots)
    }
    func refreshAll() -> IngestionBatchResult {
        IngestionBatchResult(runID: 1, sequence: 2, scope: .inventory, providers: [:])
    }
    func replaceSource(
        _ provider: Provider,
        with root: URL,
        roots: [Provider: URL]
    ) -> IngestionBatchResult {
        IngestionBatchResult(runID: 2, sequence: 1, scope: .inventory, providers: [:])
    }
    func revokeSource(_ provider: Provider, remainingRoots: [Provider: URL]) -> UInt64? {
        remainingRoots.isEmpty ? nil : 2
    }
    func stop() {}
}

private actor PresentationInbox: AppPricingInboxWatching {
    func start() {}
    func stop() {}
    func status() -> PricingCatalogStatus? { nil }
    func updates() -> AsyncStream<PricingCatalogStatus> { AsyncStream { $0.finish() } }
    func exportCurrentSnapshot() {}
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
