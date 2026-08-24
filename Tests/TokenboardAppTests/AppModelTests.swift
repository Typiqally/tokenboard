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

    func testCompanionStartsAtEnablementAndKeepsAdvancingWhileHidden() async throws {
        let setup = try makeSetup(approved: false, grantedProviders: [])
        defer { setup.cleanup() }
        await setup.ledger.setLifetimeTotal(500_000_000)

        await setup.model.select(companionTheme: .forest)

        XCTAssertEqual(setup.model.companionState.theme, .forest)
        XCTAssertEqual(setup.model.companionState.progress?.earnedTokens, 0)
        XCTAssertEqual(
            setup.model.companionState.progress?.lastObservedLifetimeTotal,
            500_000_000
        )
        XCTAssertEqual(setup.preferences.selectedCompanionTheme, .forest)

        await setup.ledger.setLifetimeTotal(504_000_000)
        await setup.model.refreshCompanionProgress()
        XCTAssertEqual(setup.model.companionState.progress?.earnedTokens, 4_000_000)

        await setup.model.select(companionTheme: .none)
        await setup.ledger.setLifetimeTotal(520_000_000)
        await setup.model.refreshCompanionProgress()
        XCTAssertEqual(setup.model.companionState.theme, .none)
        XCTAssertEqual(setup.model.companionState.progress?.earnedTokens, 20_000_000)

        await setup.model.select(companionTheme: .pokemon)
        XCTAssertEqual(setup.model.companionState.progress?.earnedTokens, 20_000_000)
    }

    func testCompanionMenuBarChoicePersistsAndMilestoneAcknowledgesOnce() async throws {
        let setup = try makeSetup(approved: false, grantedProviders: [])
        defer { setup.cleanup() }
        await setup.ledger.setLifetimeTotal(10)
        await setup.model.select(companionTheme: .village)

        setup.model.setShowCompanionInMenuBar(true)
        await setup.ledger.setLifetimeTotal(90_000_010)
        await setup.model.refreshCompanionProgress()

        XCTAssertTrue(setup.model.companionState.showInMenuBar)
        XCTAssertTrue(setup.model.companionState.progress?.hasUnacknowledgedMilestone == true)
        setup.model.acknowledgeCompanionMilestone()
        XCTAssertFalse(setup.model.companionState.progress?.hasUnacknowledgedMilestone == true)
        XCTAssertEqual(setup.preferences.companionProgress?.lastAcknowledgedStage, 1)
    }

    private func makeSetup(
        approved: Bool,
        grantedProviders: Set<Provider>,
        existingCatalogData: Data? = nil
    ) throws -> ModelSetup {
        let suiteName = "AppModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let preferences = AppPreferences(defaults: defaults)
        preferences.historicalImportApproved = approved
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
            now: { Date(timeIntervalSince1970: 1_775_000_000) },
            calendar: Calendar(identifier: .gregorian)
        )
        return ModelSetup(
            model: model,
            ledger: ledger,
            query: query,
            preferences: preferences,
            coordinator: coordinator,
            access: access,
            recorder: recorder,
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
            origin["url"] = "https://prices.example/catalog"
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
    let access: RuntimeBookmarkAccess
    let recorder: OrderedRecorder
    let cleanup: () -> Void
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
    private var lifetimeTotal: Int64 = 0

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
    func lifetimeAdditiveTokenTotal() -> Int64 { lifetimeTotal }
    func setLifetimeTotal(_ value: Int64) { lifetimeTotal = value }
    func skippedRecordCount() -> Int { 0 }
}

private actor RuntimeQuery: AppUsageQuerying {
    let recorder: OrderedRecorder
    private var historyRanges: [UsageHistoryRange] = []
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
                currentTokenTotal: 321,
                previousTokenTotal: 300,
                tokenDelta: 21,
                percentChange: 7
            ),
            breakdown: UsageBreakdown(
                tokenTotal: 321,
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
