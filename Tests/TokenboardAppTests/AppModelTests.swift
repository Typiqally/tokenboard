import Foundation
import XCTest
@testable import TokenboardApp
import TokenboardCore

@MainActor
final class AppModelTests: XCTestCase {
    func testStartupRunsIntegrityAndBundledCatalogBeforeInboxGrantsScanAndQuery() async throws {
        let setup = try makeSetup(approved: true, grantedProviders: Set(Provider.allCases))
        defer { setup.cleanup() }

        await setup.model.start()
        await setup.model.start()

        XCTAssertEqual(setup.recorder.snapshot, [
            "ledger.migrate", "ledger.integrity", "ledger.latestCatalog",
            "ledger.applyCatalog", "inbox.start",
            "grant.resolve.claude_code", "grant.start.claude_code",
            "grant.resolve.codex", "grant.start.codex",
            "coordinator.start", "query.today"
        ])
        XCTAssertFalse(setup.model.onboardingRequired)
        XCTAssertEqual(setup.model.presentation?.tokenTitle, "321 tokens")
    }

    func testStartupScansTheOneActiveGrantWhenPreviouslyApproved() async throws {
        let setup = try makeSetup(approved: true, grantedProviders: [.claudeCode])
        defer { setup.cleanup() }

        await setup.model.start()

        XCTAssertTrue(setup.model.onboardingRequired)
        let counts = await setup.coordinator.counts()
        XCTAssertEqual(counts, [1, 0])
        XCTAssertEqual(setup.model.presentation?.tokenTitle, "321 tokens")
        XCTAssertEqual(setup.model.presentation?.statusTitle, "321")
        XCTAssertEqual(setup.access.startCount, 1)
        XCTAssertEqual(setup.access.stopCount, 0)

        await setup.model.shutdown()
        XCTAssertEqual(setup.access.stopCount, 1)
    }

    func testStartupUpgradesAnOlderBundledRepositoryCatalog() async throws {
        let bundledData = try bundledCatalogData()
        let olderBundledData = try catalogData(
            basedOn: bundledData,
            catalogID: "older-bundled-catalog",
            generatedAt: "2026-08-07T00:00:00Z",
            originKind: "tokenboard_repository"
        )
        let setup = try makeSetup(
            approved: false,
            grantedProviders: [],
            existingCatalogData: olderBundledData
        )
        defer { setup.cleanup() }

        await setup.model.start()

        let currentData = await setup.ledger.currentCatalogData()
        let appliedData = try XCTUnwrap(currentData)
        let applied = try PricingCatalogValidator().validate(PricingCatalogLoader().load(appliedData))
        let bundled = try PricingCatalogValidator().validate(PricingCatalogLoader().load(bundledData))
        XCTAssertEqual(applied.catalogID, bundled.catalogID)
        XCTAssertTrue(setup.recorder.snapshot.contains("ledger.applyCatalog"))
    }

    func testStartupPreservesAnAgentManagedCatalogWhenBundledCatalogIsNewer() async throws {
        let agentData = try catalogData(
            basedOn: bundledCatalogData(),
            catalogID: "agent-managed-catalog",
            generatedAt: "2026-08-07T00:00:00Z",
            originKind: "web_research"
        )
        let setup = try makeSetup(
            approved: false,
            grantedProviders: [],
            existingCatalogData: agentData
        )
        defer { setup.cleanup() }

        await setup.model.start()

        let currentData = await setup.ledger.currentCatalogData()
        let appliedData = try XCTUnwrap(currentData)
        let applied = try PricingCatalogValidator().validate(PricingCatalogLoader().load(appliedData))
        XCTAssertEqual(applied.catalogID, "agent-managed-catalog")
        XCTAssertFalse(setup.recorder.snapshot.contains("ledger.applyCatalog"))
    }

    func testExplicitImportHoldsBothScopesAndSelectionsNeverRescan() async throws {
        let setup = try makeSetup(approved: false, grantedProviders: Set(Provider.allCases))
        defer { setup.cleanup() }

        await setup.model.start()
        var counts = await setup.coordinator.counts()
        XCTAssertEqual(counts, [0, 0])
        XCTAssertFalse(setup.preferences.historicalImportApproved)
        XCTAssertEqual(setup.access.startCount, 2)
        XCTAssertEqual(setup.access.stopCount, 0)

        await setup.model.startHistoricalImport()
        XCTAssertTrue(setup.preferences.historicalImportApproved)
        counts = await setup.coordinator.counts()
        XCTAssertEqual(counts, [1, 0])
        XCTAssertEqual(setup.access.stopCount, 0)

        await setup.model.select(period: .thisMonth)
        await setup.model.select(displayMetric: .apiValue)
        XCTAssertEqual(setup.preferences.selectedPeriod, .thisMonth)
        XCTAssertEqual(setup.preferences.selectedDisplayMetric, .apiValue)
        counts = await setup.coordinator.counts()
        XCTAssertEqual(counts, [1, 0])
        XCTAssertEqual(setup.model.presentation?.statusTitle, "$1.25")

        let queriesBeforeCurrencySelection = setup.recorder.snapshot.filter {
            $0.hasPrefix("query.")
        }.count
        setup.model.select(displayCurrency: .eur)
        XCTAssertEqual(setup.preferences.selectedDisplayCurrency, .eur)
        XCTAssertEqual(setup.model.state.selectedDisplayCurrency, .eur)
        XCTAssertEqual(setup.model.presentation?.statusTitle, "€1.00")
        XCTAssertEqual(
            setup.recorder.snapshot.filter { $0.hasPrefix("query.") }.count,
            queriesBeforeCurrencySelection
        )

        await setup.model.refresh()
        counts = await setup.coordinator.counts()
        XCTAssertEqual(counts, [1, 1])

        await setup.model.shutdown()
        XCTAssertEqual(setup.access.startCount, 2)
        XCTAssertEqual(setup.access.stopCount, 2)
    }

    func testUnavailableDisplayCurrencyCannotBeSelectedOrPersisted() async throws {
        let setup = try makeSetup(approved: true, grantedProviders: [.codex])
        defer { setup.cleanup() }
        await setup.model.start()

        setup.model.select(displayCurrency: .jpy)

        XCTAssertEqual(setup.model.selectedDisplayCurrency, .usd)
        XCTAssertEqual(setup.preferences.selectedDisplayCurrency, .usd)

        setup.model.select(displayCurrency: .eur)

        XCTAssertEqual(setup.model.selectedDisplayCurrency, .eur)
        XCTAssertEqual(setup.preferences.selectedDisplayCurrency, .eur)
    }

    func testImportCachesEveryTrendRangeAndRangeSelectionDoesNotQuery() async throws {
        let setup = try makeSetup(approved: false, grantedProviders: Set(Provider.allCases))
        defer { setup.cleanup() }

        await setup.model.start()
        XCTAssertEqual(setup.model.selectedHistoryRange, .thirtyDays)
        XCTAssertEqual(setup.model.historyState, .idle)

        await setup.model.startHistoricalImport()

        let queriedRanges = await setup.query.queriedHistoryRanges()
        XCTAssertEqual(queriedRanges, UsageHistoryRange.allCases)
        guard case let .loaded(snapshots) = setup.model.historyState else {
            return XCTFail("expected cached history snapshots")
        }
        XCTAssertEqual(Set(snapshots.keys), Set(UsageHistoryRange.allCases))

        setup.model.select(historyRange: .sevenDays)

        XCTAssertEqual(setup.model.selectedHistoryRange, .sevenDays)
        let rangesAfterSelection = await setup.query.queriedHistoryRanges()
        XCTAssertEqual(rangesAfterSelection, queriedRanges)
    }

    func testCompanionUsesTodayHistoryWithoutPersistingASecondTokenTotal() async throws {
        let setup = try makeSetup(approved: true, grantedProviders: Set(Provider.allCases))
        defer { setup.cleanup() }
        await setup.query.setHistoryTokenTotal(94_711_097)
        await setup.model.start()

        await setup.model.select(companionTheme: .forest)
        let dailyTokenTotal = setup.model.companionDailyTokenTotal(at: setup.model.now())
        let presentation = try XCTUnwrap(CompanionPresentation.make(
            state: setup.model.companionState,
            dailyTokenTotal: dailyTokenTotal,
            date: setup.model.now(),
            calendar: setup.model.calendar
        ))

        XCTAssertEqual(setup.model.companionState.theme, .forest)
        XCTAssertEqual(dailyTokenTotal, 94_711_097)
        XCTAssertEqual(presentation.stage, 1)
        XCTAssertEqual(setup.preferences.selectedCompanionTheme, .forest)
        let persisted = setup.defaults.persistentDomain(forName: setup.suiteName) ?? [:]
        XCTAssertFalse(persisted.keys.contains { $0.hasPrefix("companionEarned") })
        XCTAssertFalse(persisted.keys.contains { $0.hasPrefix("companionLastObserved") })
        XCTAssertFalse(persisted.keys.contains { $0.hasPrefix("companionProgress") })
    }

    func testCompanionPresentationUsesThePublishedStateSnapshot() async throws {
        let setup = try makeSetup(approved: true, grantedProviders: Set(Provider.allCases))
        defer { setup.cleanup() }
        await setup.query.setHistoryTokenTotal(0)
        await setup.model.start()
        await setup.model.select(companionTheme: .forest)

        let date = setup.model.now()
        let interval = DateInterval(start: date, duration: 1)
        var publishedState = setup.model.state
        publishedState.historyState = .loaded([
            .today: UsageHistorySnapshot(
                range: .today,
                provider: nil,
                currentInterval: interval,
                previousInterval: interval,
                points: [],
                comparison: UsageComparison(
                    currentTokenTotal: 100_000_000,
                    previousTokenTotal: 0,
                    tokenDelta: 100_000_000,
                    percentChange: nil
                ),
                breakdown: UsageBreakdown(
                    tokenTotal: 100_000_000,
                    knownAPIEquivalentUSD: 0,
                    unpricedTokens: 0,
                    exchangeRates: nil,
                    providers: [],
                    models: [],
                    tokenTypes: []
                )
            ),
        ])

        let presentation = try XCTUnwrap(
            setup.model.companionPresentation(for: publishedState, at: date)
        )

        XCTAssertEqual(setup.model.companionDailyTokenTotal(at: date), 0)
        XCTAssertEqual(presentation.stage, 1)
    }

    func testCalendarChangeRequeriesTodayAndUpdatesCompanionProgress() async throws {
        let setup = try makeSetup(approved: true, grantedProviders: Set(Provider.allCases))
        defer { setup.cleanup() }
        await setup.query.setHistoryTokenTotal(0)
        await setup.model.start()
        await setup.model.select(companionTheme: .forest)
        XCTAssertEqual(setup.model.companionDailyTokenTotal(at: setup.model.now()), 0)

        await setup.query.setHistoryTokenTotal(100_000_000)
        var updatedCalendar = setup.model.calendar
        updatedCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        await setup.model.refreshForCalendarChange(updatedCalendar)

        XCTAssertEqual(setup.model.calendar.timeZone.identifier, "America/New_York")
        XCTAssertEqual(setup.model.companionDailyTokenTotal(at: setup.model.now()), 100_000_000)
    }

    func testCompanionMenuBarChoicePersists() async throws {
        let setup = try makeSetup(approved: false, grantedProviders: [])
        defer { setup.cleanup() }
        await setup.model.select(companionTheme: .village)

        setup.model.setShowCompanionInMenuBar(true)

        XCTAssertTrue(setup.model.companionState.showInMenuBar)
        XCTAssertTrue(setup.preferences.showCompanionInMenuBar)
    }

    func testDiscordPresenceIsOptInPublishesTodayAndClearsOnShutdown() async throws {
        let setup = try makeSetup(
            approved: true,
            grantedProviders: Set(Provider.allCases),
            discordEnabled: true,
            discordConsentVersion: DiscordPresencePresentation.consentVersion
        )
        defer { setup.cleanup() }

        await setup.model.start()

        XCTAssertTrue(setup.model.discordPresenceEnabled)
        XCTAssertFalse(setup.model.discordPresenceRequiresConsent)
        XCTAssertEqual(setup.discordPresence.status, .connected)
        let initialActivities = await setup.discordClient.activities()
        XCTAssertEqual(initialActivities, [
            DiscordPresencePresentation.activity(
                tokenTotal: 321,
                estimatedFocusMinutes: nil
            )
        ])

        await setup.query.setHistoryTokenTotal(84)
        await setup.model.retryUsageHistory()

        let updatedActivities = await setup.discordClient.activities()
        XCTAssertEqual(updatedActivities.last, DiscordPresencePresentation.activity(
            tokenTotal: 84,
            estimatedFocusMinutes: nil
        ))

        await setup.model.shutdown()

        let clearCount = await setup.discordClient.recordedClearCount()
        let disconnectCount = await setup.discordClient.recordedDisconnectCount()
        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(disconnectCount, 1)
    }

    func testDiscordFirstEnablePersistsVersionedConsentAndDisableClears() async throws {
        let setup = try makeSetup(approved: true, grantedProviders: Set(Provider.allCases))
        defer { setup.cleanup() }
        await setup.model.start()

        XCTAssertTrue(setup.model.discordPresenceRequiresConsent)
        await setup.model.confirmAndEnableDiscordPresence()

        XCTAssertTrue(setup.preferences.discordPresenceEnabled)
        XCTAssertEqual(
            setup.preferences.discordPresenceConsentVersion,
            DiscordPresencePresentation.consentVersion
        )
        XCTAssertEqual(setup.discordPresence.status, .connected)

        await setup.model.setDiscordPresenceEnabled(false)

        XCTAssertFalse(setup.model.discordPresenceEnabled)
        XCTAssertFalse(setup.preferences.discordPresenceEnabled)
        XCTAssertEqual(setup.discordPresence.status, .disabled)
        let clearCount = await setup.discordClient.recordedClearCount()
        XCTAssertEqual(clearCount, 1)
    }

    func testDiscordDoesNotPublishAfterTheSharedMetricChangesWithoutFreshConsent() async throws {
        let setup = try makeSetup(
            approved: true,
            grantedProviders: Set(Provider.allCases),
            discordEnabled: true,
            discordConsentVersion: DiscordPresencePresentation.consentVersion - 1
        )
        defer { setup.cleanup() }

        await setup.model.start()

        XCTAssertFalse(setup.model.discordPresenceEnabled)
        XCTAssertFalse(setup.preferences.discordPresenceEnabled)
        XCTAssertTrue(setup.model.discordPresenceRequiresConsent)
        let activities = await setup.discordClient.activities()
        XCTAssertEqual(activities, [])
    }

    func testCompanionPresentationFollowsTheInjectedCalendar() async throws {
        // 20:00 UTC: a UTC calendar is still on one local day while a
        // calendar fourteen hours ahead has already crossed midnight — so
        // the daily rotation must disagree between the two models if, and
        // only if, the presentation really uses the injected calendar.
        let date = Date(timeIntervalSinceReferenceDate: 809_985_600)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var ahead = Calendar(identifier: .gregorian)
        ahead.timeZone = TimeZone(secondsFromGMT: 14 * 3600)!
        let seed: UInt64 = 0x5EED_C0FF_EE12_3456

        let utcSetup = try makeSetup(
            approved: false, grantedProviders: [], calendar: utc, companionSeed: seed
        )
        defer { utcSetup.cleanup() }
        let aheadSetup = try makeSetup(
            approved: false, grantedProviders: [], calendar: ahead, companionSeed: seed
        )
        defer { aheadSetup.cleanup() }
        await utcSetup.model.select(companionTheme: .pokemon)
        await aheadSetup.model.select(companionTheme: .pokemon)

        let utcPresentation = try XCTUnwrap(utcSetup.model.companionPresentation(at: date))
        let aheadPresentation = try XCTUnwrap(aheadSetup.model.companionPresentation(at: date))
        XCTAssertEqual(
            utcPresentation,
            CompanionPresentation.make(
                state: utcSetup.model.companionState,
                dailyTokenTotal: 0,
                date: date,
                calendar: utc
            ),
            "the presentation is built on the model's own calendar"
        )
        XCTAssertNotEqual(
            utcPresentation.variant,
            aheadPresentation.variant,
            "different local days must rotate to different starter families"
        )

        let preview = try XCTUnwrap(
            utcSetup.model.companionPresentation(at: date, overridingTheme: .forest)
        )
        XCTAssertEqual(preview.theme, .forest, "the settings shelf previews unselected themes")
        XCTAssertEqual(utcSetup.model.companionState.theme, .pokemon, "previewing changes nothing")
    }

    private func makeSetup(
        approved: Bool,
        grantedProviders: Set<Provider>,
        existingCatalogData: Data? = nil,
        discordEnabled: Bool = false,
        discordConsentVersion: Int = 0,
        calendar: Calendar = Calendar(identifier: .gregorian),
        companionSeed: UInt64? = nil
    ) throws -> ModelSetup {
        let suiteName = "AppModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        if let companionSeed {
            defaults.set(String(companionSeed), forKey: "companionSeed")
        }
        let preferences = AppPreferences(defaults: defaults)
        preferences.historicalImportApproved = approved
        preferences.discordPresenceEnabled = discordEnabled
        preferences.discordPresenceConsentVersion = discordConsentVersion
        let recorder = OrderedRecorder()
        let access = RuntimeBookmarkAccess(recorder: recorder)
        for provider in grantedProviders {
            let marker = provider == .claudeCode ? Data([1]) : Data([2])
            defaults.set(marker, forKey: "sourceBookmark.\(provider.rawValue)")
            access.roots[marker] = URL(
                fileURLWithPath: "/tmp/tokenboard-\(suiteName)-\(provider.rawValue)",
                isDirectory: true
            )
        }
        let ledger = RuntimeLedger(recorder: recorder, appliedCatalog: existingCatalogData)
        let coordinator = RuntimeCoordinator(recorder: recorder)
        let query = RuntimeQuery(recorder: recorder)
        let discordClient = ModelDiscordPresenceClient()
        let discordPresence = DiscordPresenceCoordinator(
            configuration: DiscordApplicationConfiguration(
                applicationID: "123456789012345678"
            )!,
            client: discordClient
        )
        let model = AppModel(
            ledger: ledger,
            queryService: query,
            coordinator: coordinator,
            pricingInbox: RuntimePricingInbox(recorder: recorder),
            grantStore: SourceGrantStore(defaults: defaults, bookmarkAccess: access),
            preferences: preferences,
            bundledCatalogData: try bundledCatalogData(),
            applicationPaths: ApplicationPaths(
                root: URL(fileURLWithPath: "/tmp/\(suiteName)-support", isDirectory: true)
            ),
            discordPresence: discordPresence,
            now: { Date(timeIntervalSince1970: 1_775_000_000) },
            calendar: calendar
        )
        return ModelSetup(
            model: model,
            ledger: ledger,
            query: query,
            preferences: preferences,
            coordinator: coordinator,
            discordPresence: discordPresence,
            discordClient: discordClient,
            access: access,
            recorder: recorder,
            defaults: defaults,
            suiteName: suiteName,
            cleanup: { defaults.removePersistentDomain(forName: suiteName) }
        )
    }

    private func bundledCatalogData() throws -> Data {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: repository.appending(path: "Resources/tokenboard-pricing.json"))
    }

    private func catalogData(
        basedOn data: Data,
        catalogID: String,
        generatedAt: String,
        originKind: String
    ) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["catalogID"] = catalogID
        object["generatedAt"] = generatedAt
        var origin = try XCTUnwrap(object["origin"] as? [String: Any])
        origin["kind"] = originKind
        if originKind == "web_research" {
            origin["url"] = "https://developers.openai.com/api/docs/pricing"
        }
        object["origin"] = origin
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private struct ModelSetup {
    let model: AppModel
    let ledger: RuntimeLedger
    let query: RuntimeQuery
    let preferences: AppPreferences
    let coordinator: RuntimeCoordinator
    let discordPresence: DiscordPresenceCoordinator
    let discordClient: ModelDiscordPresenceClient
    let access: RuntimeBookmarkAccess
    let recorder: OrderedRecorder
    let defaults: UserDefaults
    let suiteName: String
    let cleanup: () -> Void
}

private actor ModelDiscordPresenceClient: DiscordPresenceClient {
    private var recordedActivities: [DiscordPresenceActivity] = []
    private var clears = 0
    private var disconnects = 0

    func connect(applicationID: String) {}

    func setActivity(_ activity: DiscordPresenceActivity?) {
        if let activity {
            recordedActivities.append(activity)
        } else {
            clears += 1
        }
    }

    func disconnect() {
        disconnects += 1
    }

    func activities() -> [DiscordPresenceActivity] { recordedActivities }
    func recordedClearCount() -> Int { clears }
    func recordedDisconnectCount() -> Int { disconnects }
}

private final class OrderedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var snapshot: [String] { lock.withLock { events } }
    func append(_ event: String) { lock.withLock { events.append(event) } }
}

private actor RuntimeLedger: AppLedgerRuntime {
    let recorder: OrderedRecorder
    private var appliedCatalog: Data?

    init(recorder: OrderedRecorder, appliedCatalog: Data? = nil) {
        self.recorder = recorder
        self.appliedCatalog = appliedCatalog
    }

    func migrate() { recorder.append("ledger.migrate") }
    func integrityCheck() { recorder.append("ledger.integrity") }
    func latestAppliedPricingCatalogJSON() -> Data? {
        recorder.append("ledger.latestCatalog")
        return appliedCatalog
    }
    func currentCatalogData() -> Data? { appliedCatalog }
    func applyPricingCatalog(
        _ catalog: ValidatedPricingCatalog,
        canonicalJSON: Data,
        origin: String,
        validationSummary: String
    ) {
        recorder.append("ledger.applyCatalog")
        appliedCatalog = canonicalJSON
    }
    func pricingSnapshot() -> PricingSnapshot {
        PricingSnapshot(catalogIDs: [], rates: [], aliases: [])
    }
    func usageRows(in interval: DateInterval?, calendar: Calendar) -> [DailyUsageRow] { [] }
    func skippedRecordCount() -> Int { 0 }
    func skippedRecordCountsByProvider() -> [Provider: Int] { [:] }
    func shutdown() { recorder.append("ledger.shutdown") }
}

private actor RuntimeQuery: AppUsageQuerying {
    let recorder: OrderedRecorder
    private var historyRanges: [UsageHistoryRange] = []
    private var historyTokenTotal: Int64 = 321
    init(recorder: OrderedRecorder) { self.recorder = recorder }

    func summary(period: CalendarPeriod, now: Date, calendar: Calendar) -> UsageSummary {
        recorder.append("query.\(period.rawValue)")
        return UsageSummary(
            period: period,
            tokenTotal: 321,
            knownAPIEquivalentUSD: Decimal(string: "1.25")!,
            unpricedTokens: 0,
            exchangeRates: ExchangeRateSnapshot(
                catalogID: "test",
                effectiveDate: "2026-08-07",
                verifiedAt: "2026-08-07",
                provenanceURL: URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!,
                rates: [.usd: 1, .eur: Decimal(string: "0.8")!]
            )
        )
    }

    func history(
        range: UsageHistoryRange,
        now: Date,
        calendar: Calendar,
        provider: Provider?
    ) -> UsageHistorySnapshot {
        historyRanges.append(range)
        let interval = DateInterval(start: now, duration: 1)
        return UsageHistorySnapshot(
            range: range,
            provider: provider,
            currentInterval: interval,
            previousInterval: interval,
            points: [],
            comparison: UsageComparison(
                currentTokenTotal: historyTokenTotal,
                previousTokenTotal: 300,
                tokenDelta: historyTokenTotal - 300,
                percentChange: 7
            ),
            breakdown: UsageBreakdown(
                tokenTotal: historyTokenTotal,
                knownAPIEquivalentUSD: Decimal(string: "1.25")!,
                unpricedTokens: 0,
                exchangeRates: nil,
                providers: [],
                models: [],
                tokenTypes: []
            )
        )
    }

    func queriedHistoryRanges() -> [UsageHistoryRange] { historyRanges }
    func setHistoryTokenTotal(_ value: Int64) { historyTokenTotal = value }
}

private actor RuntimeCoordinator: AppIngestionCoordinating {
    let recorder: OrderedRecorder
    private(set) var startCount = 0
    private(set) var refreshCount = 0
    private var runID: UInt64 = 0
    private var sequence: UInt64 = 0
    private var activeProviders: Set<Provider> = []

    init(recorder: OrderedRecorder) { self.recorder = recorder }

    func results() -> AsyncStream<IngestionBatchResult> {
        AsyncStream { _ in }
    }

    func start(roots: [Provider: URL]) -> IngestionBatchResult {
        startCount += 1
        runID += 1
        sequence = 0
        recorder.append("coordinator.start")
        activeProviders = Set(roots.keys)
        return result()
    }
    func startMonitoring(roots: [Provider: URL]) -> IngestionBatchResult {
        start(roots: roots)
    }
    func refreshAll() -> IngestionBatchResult {
        refreshCount += 1
        recorder.append("coordinator.refresh")
        return result()
    }
    func replaceSource(
        _ provider: Provider,
        with root: URL,
        roots: [Provider: URL]
    ) -> IngestionBatchResult {
        start(roots: roots)
    }
    func revokeSource(_ provider: Provider, remainingRoots: [Provider: URL]) -> UInt64? {
        guard !remainingRoots.isEmpty else { return nil }
        runID += 1
        sequence = 0
        return runID
    }
    func stop() { recorder.append("coordinator.stop") }
    func counts() -> [Int] { [startCount, refreshCount] }

    private func result() -> IngestionBatchResult {
        sequence += 1
        return IngestionBatchResult(
            runID: runID,
            sequence: sequence,
            scope: .inventory,
            providers: Dictionary(uniqueKeysWithValues: activeProviders.map {
                ($0, .success(discoveredFiles: 0, scannedFiles: 0))
            })
        )
    }
}

private actor RuntimePricingInbox: AppPricingInboxWatching {
    let recorder: OrderedRecorder
    init(recorder: OrderedRecorder) { self.recorder = recorder }
    func start() { recorder.append("inbox.start") }
    func quiesce() {}
    func stop() { recorder.append("inbox.stop") }
    func status() -> PricingCatalogStatus? { nil }
    func updates() -> AsyncStream<PricingCatalogStatus> { AsyncStream { $0.finish() } }
    func exportCurrentSnapshot() {}
}

private final class RuntimeBookmarkAccess: SecurityScopedBookmarkAccessing, @unchecked Sendable {
    private let recorder: OrderedRecorder
    var roots: [Data: URL] = [:]
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(recorder: OrderedRecorder) { self.recorder = recorder }

    func makeBookmark(for url: URL, options: URL.BookmarkCreationOptions) -> Data { Data([9]) }
    func resolveBookmark(
        _ data: Data,
        options: URL.BookmarkResolutionOptions
    ) throws -> ResolvedSourceBookmark {
        let provider = data == Data([1]) ? Provider.claudeCode : .codex
        recorder.append("grant.resolve.\(provider.rawValue)")
        return ResolvedSourceBookmark(url: roots[data]!, isStale: false)
    }
    func startAccessing(_ url: URL) -> Bool {
        startCount += 1
        let provider = url.lastPathComponent.hasSuffix(Provider.claudeCode.rawValue)
            ? Provider.claudeCode : .codex
        recorder.append("grant.start.\(provider.rawValue)")
        return true
    }
    func stopAccessing(_ url: URL) { stopCount += 1 }
}
