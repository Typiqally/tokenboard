import AppKit
import Foundation
import XCTest
@testable import TokenboardApp
import TokenboardCore

@MainActor
final class SettingsTests: XCTestCase {
    func testRefreshingSettingsWaitsForStartupWhenOpenedOnDemand() async throws {
        let setup = try makeSetup(candidate: validatedCandidate())
        defer { setup.cleanup() }

        await setup.model.refreshSettings()

        XCTAssertEqual(setup.model.state.lifecycle, .ready)
        XCTAssertNotNil(setup.model.settingsState.pricing.preview)
    }

    func testRefreshingSettingsBuildsAReviewWithoutApplyingTheCandidate() async throws {
        let setup = try makeSetup(candidate: validatedCandidate())
        defer { setup.cleanup() }
        await setup.model.start()

        await setup.model.refreshSettings()

        XCTAssertEqual(setup.model.settingsState.pricing.preview?.currentKnownUSD, .zero)
        XCTAssertEqual(
            setup.model.settingsState.pricing.preview?.candidateKnownUSD,
            Decimal(string: "0.20")
        )
        XCTAssertEqual(setup.model.settingsState.pricing.preview?.newlyPricedTokens, 100_000)
        XCTAssertEqual(setup.model.settingsState.pricing.unpricedModels, ["codex/gpt-preview"])
        XCTAssertEqual(setup.model.settingsState.diagnostics.skippedRecordCount, 3)
        XCTAssertEqual(
            setup.model.settingsState.diagnostics.parserVersions,
            [.claudeCode: ClaudeCodeAdapter.parserVersion, .codex: CodexAdapter.parserVersion]
        )
        let inboxCounts = await setup.inbox.counts()
        XCTAssertEqual(inboxCounts.apply, 0)
        XCTAssertEqual(inboxCounts.reject, 0)
    }

    func testApplyRequiresConflictFreePreviewThenRefreshesTheSelectedSummary() async throws {
        let setup = try makeSetup(candidate: validatedCandidate())
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.refreshSettings()
        let queryCountBeforeApply = await setup.query.callCount()

        await setup.model.applyPendingPricing()

        let inboxCounts = await setup.inbox.counts()
        let queryCountAfterApply = await setup.query.callCount()
        XCTAssertEqual(inboxCounts.apply, 1)
        XCTAssertEqual(inboxCounts.reject, 0)
        XCTAssertEqual(queryCountAfterApply, queryCountBeforeApply + 1)
        XCTAssertEqual(setup.model.settingsState.pricing.pendingCandidate, nil)
        XCTAssertEqual(setup.model.settingsState.statusMessage, "Pricing applied · API-equivalent value refreshed")
    }

    func testConflictBlocksApplyAndLeavesCandidatePending() async throws {
        let current = PricingSnapshot(
            catalogIDs: ["current"],
            rates: [storedRate(usd: "1")],
            aliases: [storedAlias()]
        )
        let setup = try makeSetup(candidate: validatedCandidate(), pricing: current)
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.refreshSettings()

        await setup.model.applyPendingPricing()

        let inboxCounts = await setup.inbox.counts()
        XCTAssertFalse(setup.model.settingsState.pricing.canApply)
        XCTAssertEqual(inboxCounts.apply, 0)
        XCTAssertNotNil(setup.model.settingsState.pricing.pendingCandidate)
        XCTAssertEqual(setup.model.settingsState.statusMessage, "Pricing candidate has conflicts that block Apply")
    }

    func testRejectArchivesCandidateWithoutMutatingThePricingLedger() async throws {
        let setup = try makeSetup(candidate: validatedCandidate())
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.refreshSettings()
        let pricingBefore = await setup.ledger.currentPricing()

        await setup.model.rejectPendingPricing()

        let inboxCounts = await setup.inbox.counts()
        let pricingAfter = await setup.ledger.currentPricing()
        XCTAssertEqual(inboxCounts.reject, 1)
        XCTAssertEqual(inboxCounts.apply, 0)
        XCTAssertEqual(pricingAfter, pricingBefore)
        XCTAssertEqual(setup.model.settingsState.statusMessage, "Pricing candidate rejected · Active pricing unchanged")
    }

    func testCopyPromptExportsFirstAndWritesOnePlainTextStringWithExactPaths() async throws {
        let setup = try makeSetup(candidate: nil)
        defer { setup.cleanup() }
        await setup.model.start()
        setup.recorder.reset()

        await setup.model.copyAgentPrompt(source: .officialResearch)

        XCTAssertEqual(setup.recorder.snapshot, ["inbox.export", "pasteboard.replace"])
        XCTAssertEqual(setup.pasteboard.values.count, 1)
        let prompt = try XCTUnwrap(setup.pasteboard.values.first)
        XCTAssertTrue(prompt.contains(setup.paths.pricing.appending(path: "current-tokenboard-pricing.json").path))
        XCTAssertTrue(prompt.contains(setup.paths.pricing.appending(path: "Inbox/tokenboard-pricing.candidate.json.tmp").path))
        XCTAssertTrue(prompt.contains(setup.paths.pricing.appending(path: "Inbox/tokenboard-pricing.candidate.json").path))
        XCTAssertEqual(setup.model.settingsState.statusMessage, "Prompt copied · Tokenboard made no network request")
    }

    func testChangeReconfiguresOnlyTheSelectedProvider() async throws {
        let replacement = FileManager.default.temporaryDirectory
            .appending(path: "SettingsTests-replacement-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: replacement) }
        let setup = try makeSetup(
            candidate: nil,
            grantedProviders: Set(Provider.allCases),
            approved: true,
            pickerURL: replacement
        )
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.coordinator.resetEvidence()

        await setup.model.changeSource(.claudeCode)

        let evidence = await setup.coordinator.evidence()
        XCTAssertEqual(evidence.replacedProviders, [.claudeCode])
        XCTAssertEqual(evidence.stopped, 0)
        XCTAssertEqual(evidence.lastRoots?[.claudeCode], replacement.standardizedFileURL)
        XCTAssertTrue(setup.model.hasActiveGrant(for: .codex))
    }

    func testRevokeStopsOnlySelectedSourceAndRetainsLedgerRowsAndOtherGrant() async throws {
        let setup = try makeSetup(
            candidate: nil,
            grantedProviders: Set(Provider.allCases),
            approved: true
        )
        defer { setup.cleanup() }
        await setup.model.start()
        let rowsBefore = await setup.ledger.currentRows()
        await setup.coordinator.resetEvidence()

        await setup.model.revokeSource(.claudeCode)

        let evidence = await setup.coordinator.evidence()
        let rowsAfter = await setup.ledger.currentRows()
        XCTAssertEqual(evidence.revokedProviders, [.claudeCode])
        XCTAssertEqual(evidence.lastRoots?.keys.sorted(by: { $0.rawValue < $1.rawValue }), [.codex])
        XCTAssertFalse(setup.model.hasActiveGrant(for: .claudeCode))
        XCTAssertTrue(setup.model.hasActiveGrant(for: .codex))
        XCTAssertEqual(setup.model.sourceHealth[.claudeCode], .notGranted)
        XCTAssertEqual(rowsAfter, rowsBefore)
        XCTAssertNil(try setup.grantStore.grant(for: .claudeCode))
        XCTAssertEqual(setup.access.stopCount, 1)
    }

    func testChangingTheRemainingSourceAfterRevokeReconfiguresItsWatcher() async throws {
        let replacement = FileManager.default.temporaryDirectory
            .appending(path: "SettingsTests-single-replacement-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: replacement) }
        let setup = try makeSetup(
            candidate: nil,
            grantedProviders: Set(Provider.allCases),
            approved: true,
            pickerURL: replacement
        )
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.revokeSource(.claudeCode)
        await setup.coordinator.resetEvidence()

        await setup.model.changeSource(.codex)

        let evidence = await setup.coordinator.evidence()
        XCTAssertEqual(evidence.replacedProviders, [.codex])
        XCTAssertEqual(evidence.lastRoots, [.codex: replacement.standardizedFileURL])
        XCTAssertEqual(evidence.stopped, 0)
    }

    func testRevealLocalDataSelectsOnlyTheApplicationSupportRoot() throws {
        let setup = try makeSetup(candidate: nil)
        defer { setup.cleanup() }

        setup.model.revealLocalData()

        XCTAssertEqual(setup.revealer.selections, [[setup.paths.root]])
    }

    func testSettingsWindowCreatesAndReleasesSwiftUIViewStateOnDemand() throws {
        let setup = try makeSetup(candidate: nil)
        defer { setup.cleanup() }
        let controller = SettingsWindowController(
            model: setup.model,
            launchAtLogin: LaunchAtLoginController(service: SettingsLoginService())
        )

        XCTAssertFalse(controller.isSettingsViewLoaded)
        controller.showWindow(nil)
        XCTAssertTrue(controller.isSettingsViewLoaded)
        controller.close()
        XCTAssertFalse(controller.isSettingsViewLoaded)
    }

    func testLaunchAtLoginUsesMainAppServiceAndPublishesRegistrationErrors() throws {
        let service = SettingsLoginService()
        let controller = LaunchAtLoginController(service: service)
        XCTAssertFalse(controller.isEnabled)

        try controller.setEnabled(true)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(service.registerCount, 1)

        service.registrationError = SettingsError.injected
        do {
            try controller.setEnabled(true)
            XCTFail("expected registration failure")
        } catch SettingsError.injected {
        }
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(service.registerCount, 2)
    }

    private func makeSetup(
        candidate: ValidatedPricingCatalog?,
        pricing: PricingSnapshot = PricingSnapshot(catalogIDs: ["current"], rates: [], aliases: []),
        grantedProviders: Set<Provider> = [],
        approved: Bool = false,
        pickerURL: URL? = nil
    ) throws -> SettingsSetup {
        let suite = "SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let access = SettingsBookmarkAccess()
        for provider in grantedProviders {
            let marker = provider == .claudeCode ? Data([1]) : Data([2])
            defaults.set(marker, forKey: "sourceBookmark.\(provider.rawValue)")
            access.roots[marker] = URL(
                fileURLWithPath: "/private/tmp/\(suite)-\(provider.rawValue)",
                isDirectory: true
            )
        }
        let preferences = AppPreferences(defaults: defaults)
        preferences.historicalImportApproved = approved
        let paths = ApplicationPaths(
            root: URL(fileURLWithPath: "/private/tmp/\(suite)-Application Support", isDirectory: true)
        )
        let rows = [usageRow(quantity: 100_000)]
        let ledger = SettingsLedger(pricing: pricing, rows: rows)
        let recorder = SettingsRecorder()
        let inbox = SettingsInbox(
            candidate: candidate,
            ledger: ledger,
            recorder: recorder
        )
        let query = SettingsQuery()
        let coordinator = SettingsCoordinator()
        let pasteboard = SettingsPasteboard(recorder: recorder)
        let revealer = SettingsRevealer()
        let grantStore = SourceGrantStore(defaults: defaults, bookmarkAccess: access)
        let model = AppModel(
            ledger: ledger,
            queryService: query,
            coordinator: coordinator,
            pricingInbox: inbox,
            grantStore: grantStore,
            preferences: preferences,
            bundledCatalogData: Data([1]),
            applicationPaths: paths,
            sourcePicker: SettingsPicker(url: pickerURL),
            pasteboard: pasteboard,
            localDataRevealer: revealer
        )
        return SettingsSetup(
            model: model,
            ledger: ledger,
            query: query,
            coordinator: coordinator,
            inbox: inbox,
            grantStore: grantStore,
            access: access,
            paths: paths,
            pasteboard: pasteboard,
            revealer: revealer,
            recorder: recorder,
            cleanup: { defaults.removePersistentDomain(forName: suite) }
        )
    }

    private func usageRow(quantity: Int64) -> DailyUsageRow {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return DailyUsageRow(
            localDay: LocalDay(
                date: ISO8601DateFormatter().date(from: "2026-08-05T12:00:00Z")!,
                calendar: calendar
            ),
            provider: .codex,
            observedModelID: "gpt-preview",
            metric: .inputUncached,
            aggregation: .additive,
            quantity: quantity
        )
    }

    private func storedAlias() -> StoredModelAlias {
        StoredModelAlias(
            provider: .codex,
            observedModelID: "gpt-preview",
            canonicalModelID: "gpt-preview",
            effectiveFrom: "2026-01-01",
            effectiveTo: nil
        )
    }

    private func storedRate(usd: String) -> StoredPriceRate {
        StoredPriceRate(
            provider: .codex,
            canonicalModelID: "gpt-preview",
            metric: .inputUncached,
            usdPerMillion: Decimal(string: usd)!,
            effectiveFrom: "2026-01-01",
            effectiveTo: nil,
            provenanceURL: URL(string: "https://openai.com/api/pricing/")!,
            verifiedAt: "2026-08-05"
        )
    }

    private func validatedCandidate() throws -> ValidatedPricingCatalog {
        let json = #"""
        {
          "schemaVersion":1,
          "catalogID":"candidate-2026-08-05",
          "generatedAt":"2026-08-05T12:00:00Z",
          "origin":{"kind":"official_research","url":"https://openai.com/api/pricing/"},
          "models":[{
            "provider":"codex",
            "canonicalModelID":"gpt-preview",
            "aliases":[{"observedModelID":"gpt-preview","effectiveFrom":"2026-01-01","effectiveTo":null}],
            "rates":[{
              "effectiveFrom":"2026-01-01",
              "effectiveTo":null,
              "prices":{"input_uncached":"2","output":"30"},
              "provenanceURL":"https://openai.com/api/pricing/",
              "verifiedAt":"2026-08-05"
            }]
          }]
        }
        """#
        return try PricingCatalogValidator().validate(
            PricingCatalogLoader().load(Data(json.utf8))
        )
    }
}

private struct SettingsSetup {
    let model: AppModel
    let ledger: SettingsLedger
    let query: SettingsQuery
    let coordinator: SettingsCoordinator
    let inbox: SettingsInbox
    let grantStore: SourceGrantStore
    let access: SettingsBookmarkAccess
    let paths: ApplicationPaths
    let pasteboard: SettingsPasteboard
    let revealer: SettingsRevealer
    let recorder: SettingsRecorder
    let cleanup: () -> Void
}

private enum SettingsError: Error { case injected }

private final class SettingsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var snapshot: [String] { lock.withLock { values } }
    func append(_ value: String) { lock.withLock { values.append(value) } }
    func reset() { lock.withLock { values.removeAll() } }
}

private actor SettingsLedger: AppLedgerRuntime {
    private var pricing: PricingSnapshot
    private let rows: [DailyUsageRow]

    init(pricing: PricingSnapshot, rows: [DailyUsageRow]) {
        self.pricing = pricing
        self.rows = rows
    }

    func migrate() {}
    func integrityCheck() {}
    func latestAppliedPricingCatalogJSON() -> Data? { Data([1]) }
    func applyPricingCatalog(
        _ catalog: ValidatedPricingCatalog,
        canonicalJSON: Data,
        origin: String,
        validationSummary: String
    ) {}
    func pricingSnapshot() -> PricingSnapshot { pricing }
    func usageRows(in interval: DateInterval?, calendar: Calendar) -> [DailyUsageRow] { rows }
    func skippedRecordCount() -> Int { 3 }
    func currentPricing() -> PricingSnapshot { pricing }
    func currentRows() -> [DailyUsageRow] { rows }

    func install(_ catalog: ValidatedPricingCatalog) {
        let preview = try! PricingPreview.make(rows: [], currentPricing: pricing, candidate: catalog)
        guard preview.diff.conflicts.isEmpty else { return }
        var aliases = pricing.aliases
        var rates = pricing.rates
        for model in catalog.models {
            aliases.append(contentsOf: model.aliases.map {
                StoredModelAlias(
                    provider: model.provider,
                    observedModelID: $0.observedModelID,
                    canonicalModelID: model.canonicalModelID,
                    effectiveFrom: $0.effectiveFrom,
                    effectiveTo: $0.effectiveTo
                )
            })
            for rate in model.rates {
                rates.append(contentsOf: rate.prices.map { metric, price in
                    StoredPriceRate(
                        provider: model.provider,
                        canonicalModelID: model.canonicalModelID,
                        metric: metric,
                        usdPerMillion: price,
                        effectiveFrom: rate.effectiveFrom,
                        effectiveTo: rate.effectiveTo,
                        provenanceURL: rate.provenanceURL,
                        verifiedAt: rate.verifiedAt
                    )
                })
            }
        }
        pricing = PricingSnapshot(
            catalogIDs: pricing.catalogIDs + [catalog.catalogID],
            rates: rates,
            aliases: aliases
        )
    }
}

private actor SettingsQuery: AppUsageQuerying {
    private var calls = 0
    func summary(period: CalendarPeriod, now: Date, calendar: Calendar) -> UsageSummary {
        calls += 1
        return UsageSummary(
            period: period,
            tokenTotal: 100_000,
            knownAPIEquivalentUSD: Decimal(string: "0.20")!,
            unpricedTokens: 0
        )
    }
    func callCount() -> Int { calls }
}

private actor SettingsCoordinator: AppIngestionCoordinating {
    private var runID: UInt64 = 0
    private var sequence: UInt64 = 0
    private var stopped = 0
    private var replacedProviders: [Provider] = []
    private var revokedProviders: [Provider] = []
    private var lastRoots: [Provider: URL]?

    func results() -> AsyncStream<IngestionBatchResult> { AsyncStream { _ in } }
    func start(roots: [Provider: URL]) -> IngestionBatchResult {
        runID += 1
        sequence = 1
        lastRoots = roots
        return result(providers: Set(roots.keys))
    }
    func refreshAll() -> IngestionBatchResult {
        sequence += 1
        return result(providers: lastRoots.map { Set($0.keys) } ?? [])
    }
    func stop() { stopped += 1 }
    func replaceSource(
        _ provider: Provider,
        with root: URL,
        roots: [Provider: URL]
    ) -> IngestionBatchResult {
        runID += 1
        sequence = 1
        replacedProviders.append(provider)
        lastRoots = roots
        return result(providers: [provider])
    }
    func revokeSource(_ provider: Provider, remainingRoots: [Provider: URL]) -> UInt64? {
        revokedProviders.append(provider)
        lastRoots = remainingRoots
        guard !remainingRoots.isEmpty else { return nil }
        runID += 1
        sequence = 0
        return runID
    }
    func resetEvidence() {
        stopped = 0
        replacedProviders = []
        revokedProviders = []
    }
    func evidence() -> (
        stopped: Int,
        replacedProviders: [Provider],
        revokedProviders: [Provider],
        lastRoots: [Provider: URL]?
    ) {
        (stopped, replacedProviders, revokedProviders, lastRoots)
    }
    private func result(providers: Set<Provider>) -> IngestionBatchResult {
        IngestionBatchResult(
            runID: runID,
            sequence: sequence,
            scope: .inventory,
            providers: Dictionary(uniqueKeysWithValues: providers.map {
                ($0, .success(discoveredFiles: 0, scannedFiles: 0))
            })
        )
    }
}

private actor SettingsInbox: AppPricingInboxWatching {
    private var candidate: PendingPricingCandidate?
    private let ledger: SettingsLedger
    private let recorder: SettingsRecorder
    private var applyCount = 0
    private var rejectCount = 0

    init(candidate: ValidatedPricingCatalog?, ledger: SettingsLedger, recorder: SettingsRecorder) {
        self.ledger = ledger
        self.recorder = recorder
        if let candidate {
            self.candidate = PendingPricingCandidate(
                catalog: candidate,
                canonicalJSON: candidate.canonicalJSON,
                diff: CatalogDiff(modelsAdded: [], aliasesAdded: 0, ratesAdded: 0, conflicts: []),
                sourceURL: URL(fileURLWithPath: "/private/tmp/candidate.json")
            )
        }
    }

    func start() {}
    func stop() {}
    func pendingCandidate() -> PendingPricingCandidate? { candidate }
    func exportCurrentSnapshot() { recorder.append("inbox.export") }
    func applyPending() async {
        applyCount += 1
        if let candidate { await ledger.install(candidate.catalog) }
        candidate = nil
    }
    func rejectPending() { rejectCount += 1; candidate = nil }
    func counts() -> (apply: Int, reject: Int) { (applyCount, rejectCount) }
}

@MainActor
private final class SettingsPasteboard: AppPlainTextCopying {
    private let recorder: SettingsRecorder
    private(set) var values: [String] = []
    init(recorder: SettingsRecorder) { self.recorder = recorder }
    func replace(with value: String) -> Bool {
        recorder.append("pasteboard.replace")
        values = [value]
        return true
    }
}

@MainActor
private final class SettingsRevealer: AppLocalDataRevealing {
    private(set) var selections: [[URL]] = []
    func reveal(_ urls: [URL]) { selections.append(urls) }
}

@MainActor
private struct SettingsPicker: AppSourcePicking {
    let url: URL?
    func select(provider: Provider) throws -> URL? { url }
}

private final class SettingsBookmarkAccess: SecurityScopedBookmarkAccessing, @unchecked Sendable {
    var roots: [Data: URL] = [:]
    private(set) var stopCount = 0
    func makeBookmark(for url: URL, options: URL.BookmarkCreationOptions) -> Data {
        Data(url.path.utf8)
    }
    func resolveBookmark(
        _ data: Data,
        options: URL.BookmarkResolutionOptions
    ) -> ResolvedSourceBookmark {
        ResolvedSourceBookmark(
            url: roots[data] ?? URL(fileURLWithPath: String(decoding: data, as: UTF8.self)),
            isStale: false
        )
    }
    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) { stopCount += 1 }
}

@MainActor
private final class SettingsLoginService: MainAppLoginServicing {
    var isEnabled = false
    var registerCount = 0
    var unregisterCount = 0
    var registrationError: Error?
    func register() throws {
        registerCount += 1
        if let registrationError { throw registrationError }
        isEnabled = true
    }
    func unregister() throws {
        unregisterCount += 1
        isEnabled = false
    }
}
