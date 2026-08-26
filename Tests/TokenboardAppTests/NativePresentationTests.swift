import AppKit
import Foundation
import XCTest
@testable import TokenboardApp
import TokenboardCore

@MainActor
final class NativePresentationTests: XCTestCase {
    func testRichPopoverOpensInstantlyAtTheApprovedCompactSize() throws {
        let setup = try makeModel()
        defer { setup.cleanup() }

        let controller = RichPopoverController(model: setup.model)

        XCTAssertFalse(controller.renderedPopoverAnimates)
        XCTAssertEqual(controller.renderedPopoverSize, NSSize(width: 350, height: 500))
        XCTAssertEqual(controller.renderedPopoverBehavior, .transient)
    }

    func testCompanionAmbientMotionRunsOnlyWhilePopoverIsVisible() throws {
        let setup = try makeModel()
        defer { setup.cleanup() }
        let controller = RichPopoverController(model: setup.model)

        XCTAssertFalse(controller.renderedAmbientMotionActive)

        controller.popoverDidShow(Notification(name: NSPopover.didShowNotification))
        XCTAssertTrue(controller.renderedAmbientMotionActive)

        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertFalse(controller.renderedAmbientMotionActive)
    }

    func testRichPopoverExpandsOnlyForACompanionAndMenuIconIsOptIn() async throws {
        let setup = try makeModel()
        defer { setup.cleanup() }
        var state = setup.model.state
        state.lifecycle = .ready
        state.presentation = MenuPresentation(
            summary: UsageSummary(
                period: .today,
                tokenTotal: 42,
                knownAPIEquivalentUSD: 0,
                unpricedTokens: 0
            ),
            displayMetric: .tokens
        )
        setup.model.commitState(state)
        await setup.model.select(companionTheme: .forest)
        let controller = RichPopoverController(model: setup.model)

        XCTAssertEqual(controller.renderedPopoverSize, TokenboardSurfaceMetrics.companionPopoverSize)
        XCTAssertNil(controller.renderedStatusImage)

        setup.model.setShowCompanionInMenuBar(true)
        XCTAssertEqual(controller.renderedStatusImage?.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(controller.renderedStatusImage?.isTemplate == true)

        await setup.model.select(companionTheme: .none)
        XCTAssertEqual(controller.renderedPopoverSize, TokenboardSurfaceMetrics.popoverSize)
        XCTAssertNil(controller.renderedStatusImage)
    }

    func testPopoverLetsTheHostedViewDriveItsSizeSoContentNeverOffsets() async throws {
        let setup = try makeModel()
        defer { setup.cleanup() }
        let controller = RichPopoverController(model: setup.model)

        // AppKit owns the content view's geometry; the hosting controller
        // publishes the SwiftUI frame as preferredContentSize and NSPopover
        // tracks it. Managing frames by hand shifted the content.
        XCTAssertEqual(controller.renderedSizingOptions, .preferredContentSize)

        await setup.model.select(companionTheme: .forest)
        XCTAssertEqual(
            controller.renderedPopoverSize,
            TokenboardSurfaceMetrics.companionPopoverSize
        )

        await setup.model.select(companionTheme: .none)
        XCTAssertEqual(
            controller.renderedPopoverSize,
            TokenboardSurfaceMetrics.popoverSize
        )
    }

    func testRichPopoverTogglesOnMouseDownSoASecondStatusItemClickOnlyClosesIt() throws {
        let setup = try makeModel()
        defer { setup.cleanup() }
        let controller = RichPopoverController(model: setup.model)

        XCTAssertEqual(
            controller.renderedStatusButtonActionMask,
            NSEvent.EventTypeMask.leftMouseDown
        )
    }

    func testRichPopoverActivatesTheAccessoryAppBeforeShowingForClickAwayDismissal() throws {
        let setup = try makeModel()
        defer { setup.cleanup() }
        var activationCount = 0
        let controller = RichPopoverController(
            model: setup.model,
            activateApplication: { activationCount += 1 }
        )

        _ = controller.perform(NSSelectorFromString("togglePopover"))

        XCTAssertEqual(activationCount, 1)
    }

    func testPopoverClickAwayDismissalClosesForGlobalMouseDownAndStopsAfterClose() {
        let monitorToken = NSObject()
        var registeredMask: NSEvent.EventTypeMask = []
        var registeredClick: (() -> Void)?
        var removedToken: Any?
        let monitor = GlobalMouseDownMonitor(
            install: { mask, click in
                registeredMask = mask
                registeredClick = click
                return monitorToken
            },
            remove: { removedToken = $0 }
        )
        var dismissalCount = 0
        let dismissal = PopoverClickAwayDismissal(
            monitor: monitor,
            dismiss: { dismissalCount += 1 }
        )

        dismissal.popoverDidShow()

        XCTAssertEqual(registeredMask, [.leftMouseDown, .rightMouseDown])
        XCTAssertNotNil(registeredClick)

        registeredClick?()

        XCTAssertEqual(dismissalCount, 1)

        dismissal.popoverDidClose()

        XCTAssertIdentical(removedToken as AnyObject, monitorToken)
    }

    func testStartupFailurePopoverUsesTheSameStableDismissalConfiguration() {
        let controller = RichPopoverController(startupError: SyntheticStartupError())

        XCTAssertEqual(controller.renderedPopoverBehavior, .transient)
        XCTAssertEqual(
            controller.renderedStatusButtonActionMask,
            NSEvent.EventTypeMask.leftMouseDown
        )
    }

    func testOpenUnfilteredHistoryTracksRefreshedModelSnapshots() throws {
        let setup = try makeModel()
        defer { setup.cleanup() }
        var state = setup.model.state
        state.historyState = .loaded([.today: historySnapshot(tokenTotal: 10)])
        setup.model.commitState(state)
        let viewModel = HistoryViewModel(
            model: setup.model,
            request: HistoryOpenRequest(provider: nil, range: .today)
        )
        XCTAssertEqual(viewModel.snapshot?.breakdown.tokenTotal, 10)

        state.historyState = .loaded([.today: historySnapshot(tokenTotal: 20)])
        setup.model.commitState(state)

        XCTAssertEqual(viewModel.snapshot?.breakdown.tokenTotal, 20)
    }

    func testOnboardingCopyAndVisibilityRemainExplicitAndConsentNeutral() throws {
        XCTAssertEqual(
            OnboardingCopy.privacy,
            "Only token counts, model IDs, and timestamps are read. Conversation content is never retained."
        )
        XCTAssertEqual(
            OnboardingCopy.coverageNote,
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

    func testRecencyPresentationUsesAbbreviatedVisualAndFullAccessibilityStyles() {
        let relativeTo = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let lastUpdated = relativeTo.addingTimeInterval(-2 * 60 * 60)

        let abbreviatedFormatter = RelativeDateTimeFormatter()
        abbreviatedFormatter.unitsStyle = .abbreviated
        let expectedVisualRelative = abbreviatedFormatter.localizedString(
            for: lastUpdated,
            relativeTo: relativeTo
        )
        let expectedVisualTitle = "Updated \(expectedVisualRelative)"

        let fullFormatter = RelativeDateTimeFormatter()
        fullFormatter.unitsStyle = .full
        let expectedAccessibilityRelative = fullFormatter.localizedString(
            for: lastUpdated,
            relativeTo: relativeTo
        )
        let expectedAccessibilityTitle = "Updated \(expectedAccessibilityRelative)"

        XCTAssertNotEqual(expectedVisualTitle, expectedAccessibilityTitle)

        let presentation = RecencyPresentation(
            lastUpdated: lastUpdated,
            relativeTo: relativeTo
        )
        XCTAssertEqual(presentation.visualTitle, expectedVisualTitle)
        XCTAssertEqual(presentation.accessibilityTitle, expectedAccessibilityTitle)
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

    private func historySnapshot(tokenTotal: Int64) -> UsageHistorySnapshot {
        let interval = DateInterval(start: .distantPast, duration: 1)
        return UsageHistorySnapshot(
            range: .today,
            provider: nil,
            currentInterval: interval,
            previousInterval: interval,
            points: [],
            comparison: UsageComparison(
                currentTokenTotal: tokenTotal,
                previousTokenTotal: 0,
                tokenDelta: tokenTotal,
                percentChange: nil
            ),
            breakdown: UsageBreakdown(
                tokenTotal: tokenTotal,
                knownAPIEquivalentUSD: 0,
                unpricedTokens: 0,
                exchangeRates: nil,
                providers: [],
                models: [],
                tokenTypes: []
            )
        )
    }
}

private struct SyntheticStartupError: Error {}

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
