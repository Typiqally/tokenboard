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
        XCTAssertEqual(controller.renderedPopoverSize, NSSize(width: 350, height: 560))
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

    func testMenuBuilderPublishesTheCompleteFinalizedStateInRequiredOrder() {
        let updated = Date(timeIntervalSince1970: 1_775_000_000)
        let summary = UsageSummary(
            period: .thisMonth,
            tokenTotal: 842_198,
            knownAPIEquivalentUSD: Decimal(string: "7.42")!,
            unpricedTokens: 84_000
        )
        var state = AppPublishedState.initial(
            period: .thisMonth,
            displayMetric: .apiValue,
            displayCurrency: .eur
        )
        state.lifecycle = .ready
        state.presentation = MenuPresentation(
            summary: summary,
            displayMetric: .apiValue
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
            target: nil,
            availableDisplayCurrencies: [.usd, .eur, .gbp]
        )

        XCTAssertEqual(topLevelTitles(built.menu), [
            "Usage Summary",
            "—",
            "Period: This Month",
            "Currency: EUR",
            "Menu Bar: API Value",
            "—",
            "Refresh Now",
            "Pricing (84K unpriced)",
            "Settings",
            "—",
            "Quit Tokenboard"
        ])
        XCTAssertEqual(built.statusTitle, "$7.42+")
        XCTAssertIdentical(built.menu.items.first?.view, built.summaryView)
        XCTAssertEqual(built.summaryView.content, MenuSummaryContent(
            contextTitle: "This Month",
            visualRecencyTitle: "Updated never",
            accessibilityRecencyTitle: "Updated never",
            tokenTitle: "842,198 tokens",
            apiValueTitle: "≈ $7.42 API equivalent"
        ))

        let period = built.menu.items[2].submenu!.items
        XCTAssertEqual(period.map(\.title), ["Today", "This Week", "This Month", "This Year", "All Time"])
        XCTAssertEqual(period.map(\.state), [.off, .off, .on, .off, .off])
        let currencies = built.menu.items[3].submenu!.items
        XCTAssertEqual(currencies.map(\.title), ["USD", "EUR", "JPY", "GBP", "CNY"])
        XCTAssertEqual(currencies.map(\.state), [.off, .on, .off, .off, .off])
        XCTAssertEqual(currencies.map(\.isEnabled), [true, true, false, true, false])
        let metrics = built.menu.items[4].submenu!.items
        XCTAssertEqual(metrics.map(\.title), ["Tokens", "API Value"])
        XCTAssertEqual(metrics.map(\.state), [.off, .on])
        XCTAssertEqual(built.menu.items[6].keyEquivalent, "r")
        XCTAssertEqual(built.menu.items[8].keyEquivalent, ",")
        XCTAssertEqual(built.menu.items[10].keyEquivalent, "q")
        assertSystemSymbol("arrow.clockwise", on: built.menu.item(withTitle: "Refresh Now"))
        assertSystemSymbol("banknote", on: built.menu.item(withTitle: "Pricing (84K unpriced)"))
        assertSystemSymbol("gearshape", on: built.menu.item(withTitle: "Settings"))
        XCTAssertNil(built.menu.item(withTitle: "Period: This Month")?.image)
        XCTAssertNil(built.menu.item(withTitle: "Currency: EUR")?.image)
        XCTAssertNil(built.menu.item(withTitle: "Menu Bar: API Value")?.image)
        XCTAssertNil(built.menu.item(withTitle: "Quit Tokenboard")?.image)
    }

    func testMenuBuilderPublishesExplicitStartingAndFailureSummaries() {
        let starting = NativeMenuBuilder.makeMenu(
            state: nil,
            startupError: nil,
            target: nil
        )

        XCTAssertEqual(starting.statusTitle, "…")
        XCTAssertEqual(starting.summaryView.content, MenuSummaryContent(
            contextTitle: "Starting",
            visualRecencyTitle: "Updated never",
            accessibilityRecencyTitle: "Updated never",
            tokenTitle: "Token total unavailable",
            apiValueTitle: "API equivalent unavailable"
        ))
        XCTAssertNotNil(starting.menu.item(withTitle: "Sources unavailable"))

        let failed = NativeMenuBuilder.makeMenu(
            state: nil,
            startupError: "Startup paused: Synthetic failure",
            target: nil
        )

        XCTAssertEqual(failed.statusTitle, "Unavailable")
        XCTAssertEqual(failed.summaryView.content.contextTitle, "Unavailable")
        XCTAssertEqual(failed.summaryView.content.tokenTitle, "Token total unavailable")
        XCTAssertEqual(failed.summaryView.content.apiValueTitle, "API equivalent unavailable")
        XCTAssertNotNil(failed.menu.item(withTitle: "Startup paused: Synthetic failure"))
    }

    func testInitialZeroImportUsesLoadingStatusUntilTheFirstSuccessfulScan() {
        var state = AppPublishedState.initial(period: .today, displayMetric: .tokens)
        state.lifecycle = .ready
        state.isImporting = true
        state.presentation = MenuPresentation(
            summary: UsageSummary(
                period: .today,
                tokenTotal: 0,
                knownAPIEquivalentUSD: 0,
                unpricedTokens: 0
            ),
            displayMetric: .tokens
        )

        let loading = NativeMenuBuilder.makeMenu(
            state: state,
            startupError: nil,
            target: nil
        )

        XCTAssertEqual(loading.statusTitle, "")
        XCTAssertEqual(loading.statusSystemImageName, "hourglass")
        XCTAssertEqual(loading.statusAccessibilityLabel, "Tokenboard is importing usage")
        XCTAssertEqual(loading.summaryView.content.tokenTitle, "Importing usage…")
        XCTAssertEqual(
            loading.summaryView.content.apiValueTitle,
            "Waiting for usage records"
        )

        state.lastUpdated = Date(timeIntervalSinceReferenceDate: 1)
        let completedZero = NativeMenuBuilder.makeMenu(
            state: state,
            startupError: nil,
            target: nil
        )

        XCTAssertEqual(completedZero.statusTitle, "0")
        XCTAssertNil(completedZero.statusSystemImageName)
        XCTAssertEqual(completedZero.summaryView.content.tokenTitle, "0 tokens")
    }

    func testRefreshKeepsAnEstablishedNonzeroTotalVisible() {
        var state = AppPublishedState.initial(period: .today, displayMetric: .tokens)
        state.lifecycle = .ready
        state.isImporting = true
        state.presentation = MenuPresentation(
            summary: UsageSummary(
                period: .today,
                tokenTotal: 456,
                knownAPIEquivalentUSD: 0,
                unpricedTokens: 0
            ),
            displayMetric: .tokens
        )

        let built = NativeMenuBuilder.makeMenu(
            state: state,
            startupError: nil,
            target: nil
        )

        XCTAssertEqual(built.statusTitle, "456")
        XCTAssertNil(built.statusSystemImageName)
        XCTAssertEqual(built.summaryView.content.tokenTitle, "456 tokens")
    }

    func testDiagnosticIssuesDoNotChangeTheMenuStatus() throws {
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
        let controller = MenuController(model: setup.model, statusItem: TestStatusItemHost())

        XCTAssertEqual(controller.renderedStatusTitle, "$3.00+")
        XCTAssertFalse(controller.renderedMenu?.items.contains {
            $0.title.hasPrefix("Warnings (")
        } == true)
        XCTAssertNotNil(controller.renderedMenu?.item(withTitle: "Pricing (84K unpriced)"))
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

    func testMenuControllerRendersEmittedSnapshotAndWiresRealSelectorsAndValues() async throws {
        let setup = try makeModel()
        defer { setup.cleanup() }
        var settings = setup.model.settingsState
        settings.pricing.exchangeRates = ExchangeRateSnapshot(
            catalogID: "test-catalog",
            effectiveDate: "2026-08-07",
            verifiedAt: "2026-08-07",
            provenanceURL: URL(string: "https://rates.example")!,
            rates: [.usd: 1, .eur: Decimal(string: "0.86")!]
        )
        setup.model.commitSettingsState(settings)
        let controller = MenuController(model: setup.model, statusItem: TestStatusItemHost())
        var emitted = AppPublishedState.initial(period: .thisWeek, displayMetric: .tokens)
        emitted.lifecycle = .ready
        emitted.presentation = MenuPresentation(
            summary: UsageSummary(
                period: .thisWeek,
                tokenTotal: 456,
                knownAPIEquivalentUSD: 0,
                unpricedTokens: 0
            ),
            displayMetric: .tokens
        )

        setup.model.commitState(emitted)

        let summaryView = controller.renderedMenu?.items.first?.view as? MenuSummaryView
        XCTAssertEqual(summaryView?.content.tokenTitle, "456 tokens")
        XCTAssertEqual(summaryView?.content.apiValueTitle, "≈ $0.00 API equivalent")
        XCTAssertEqual(controller.renderedStatusTitle, "456")
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

        let currencyParent = controller.renderedMenu?.items.first {
            $0.title == "Currency: USD"
        }
        let euro = currencyParent?.submenu?.items.first { $0.title == "EUR" }
        XCTAssertEqual(euro?.representedObject as? String, "EUR")
        XCTAssertEqual(euro?.target as? MenuController, controller)
        XCTAssertEqual(euro?.action, NSSelectorFromString("selectDisplayCurrency:"))
        XCTAssertTrue(euro?.isEnabled == true)
        XCTAssertTrue(controller.responds(to: NSSelectorFromString("selectDisplayCurrency:")))
        guard let euro else { return XCTFail("missing EUR menu action") }
        _ = controller.perform(NSSelectorFromString("selectDisplayCurrency:"), with: euro)
        XCTAssertEqual(setup.preferences.selectedDisplayCurrency, .eur)
        XCTAssertEqual(setup.model.state.selectedDisplayCurrency, .eur)

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

    func testMenuOpenUpdatesVisualAndAccessibilityRecencyWithoutChangingSummaryValues() throws {
        let setup = try makeModel()
        defer { setup.cleanup() }
        var state = AppPublishedState.initial(period: .today, displayMetric: .tokens)
        state.lifecycle = .ready
        state.lastUpdated = Date().addingTimeInterval(-90)
        state.presentation = MenuPresentation(
            summary: UsageSummary(
                period: .today,
                tokenTotal: 456,
                knownAPIEquivalentUSD: Decimal(string: "1.25")!,
                unpricedTokens: 0
            ),
            displayMetric: .tokens
        )
        setup.model.commitState(state)
        let controller = MenuController(model: setup.model, statusItem: TestStatusItemHost())
        guard let menu = controller.renderedMenu,
              let summaryView = menu.items.first?.view as? MenuSummaryView else {
            return XCTFail("missing menu summary view")
        }

        XCTAssertEqual(summaryView.content.visualRecencyTitle, "Updated never")
        controller.menuWillOpen(menu)

        XCTAssertTrue(summaryView.content.visualRecencyTitle.hasPrefix("Updated "))
        XCTAssertNotEqual(summaryView.content.visualRecencyTitle, "Updated never")
        XCTAssertTrue(summaryView.content.accessibilityRecencyTitle.hasPrefix("Updated "))
        XCTAssertEqual(summaryView.content.tokenTitle, "456 tokens")
        XCTAssertEqual(summaryView.content.apiValueTitle, "≈ $1.25 API equivalent")
        XCTAssertEqual(summaryView.accessibilityLabel(), summaryView.content.accessibilitySummary)
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

        let presentation = MenuRecencyPresentation(
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

    private func topLevelTitles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    private func assertSystemSymbol(
        _ symbolName: String,
        on item: NSMenuItem?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )
        XCTAssertNotNil(item?.image, file: file, line: line)
        XCTAssertEqual(
            item?.image?.tiffRepresentation,
            expected?.tiffRepresentation,
            file: file,
            line: line
        )
        XCTAssertTrue(item?.image?.isTemplate == true, file: file, line: line)
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
