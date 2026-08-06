import Foundation
import XCTest
@testable import TokenboardApp
import TokenboardCore

@MainActor
final class AppModelLifecycleTests: XCTestCase {
    func testEveryFailedStartupPrerequisiteBlocksSourcesScansAndQueries() async throws {
        for point in StartupFailurePoint.allCases {
            let setup = try makeSetup(approved: true, failure: point)
            defer { setup.cleanup() }

            await setup.model.start()

            guard case .failed = setup.model.state.lifecycle else {
                return XCTFail("expected failed lifecycle for \(point)")
            }
            XCTAssertFalse(setup.model.state.canStartHistoricalImport)
            XCTAssertEqual(setup.access.counts, [0, 0])
            let coordinatorCounts = await setup.coordinator.counts()
            let queryCalls = await setup.query.calls()
            XCTAssertEqual(coordinatorCounts, [0, 0, 0])
            XCTAssertEqual(queryCalls, 0)
        }
    }

    func testRefreshRetriesFailedPrerequisitesAndSkipsAlreadyAppliedCatalog() async throws {
        let setup = try makeSetup(
            approved: false,
            failure: .migrate,
            failureIsOneShot: true,
            catalogAlreadyApplied: true
        )
        defer { setup.cleanup() }
        await setup.model.start()
        guard case .failed = setup.model.state.lifecycle else {
            return XCTFail("expected first startup to fail")
        }

        await setup.model.refresh()

        XCTAssertEqual(setup.model.state.lifecycle, .ready)
        XCTAssertTrue(setup.model.state.onboardingRequired)
        let applyCount = await setup.ledger.appliedCount()
        let coordinatorCounts = await setup.coordinator.counts()
        XCTAssertEqual(applyCount, 0)
        XCTAssertEqual(setup.access.counts, [2, 0])
        XCTAssertEqual(coordinatorCounts, [0, 0, 0])
    }

    func testShutdownDuringStartupPreventsLateResourceRecreation() async throws {
        let gate = AsyncTestGate()
        let setup = try makeSetup(approved: true, startupGate: gate)
        defer { setup.cleanup() }
        let startTask = Task { await setup.model.start() }
        await gate.waitUntilEntered()

        let shutdownTask = Task { await setup.model.shutdown() }
        await Task.yield()
        await gate.resume()
        await startTask.value
        await shutdownTask.value

        XCTAssertEqual(setup.model.state.lifecycle, .stopped)
        XCTAssertEqual(setup.access.counts, [0, 0])
        let coordinatorCounts = await setup.coordinator.counts()
        let queryCalls = await setup.query.calls()
        XCTAssertEqual(coordinatorCounts, [0, 0, 2])
        XCTAssertEqual(queryCalls, 0)
    }

    func testDoubleImportCoalescesAndShutdownDuringCoordinatorStartBalancesScopes() async throws {
        let coordinatorGate = AsyncTestGate()
        let setup = try makeSetup(approved: false, coordinatorStartGate: coordinatorGate)
        defer { setup.cleanup() }
        await setup.model.start()
        XCTAssertEqual(setup.model.state.lifecycle, .ready)

        let first = Task { await setup.model.startHistoricalImport() }
        await coordinatorGate.waitUntilEntered()
        let second = Task { await setup.model.startHistoricalImport() }
        await Task.yield()
        XCTAssertTrue(setup.model.state.isImporting)
        XCTAssertFalse(setup.model.state.canStartHistoricalImport)
        let startingCounts = await setup.coordinator.counts()
        XCTAssertEqual(startingCounts, [1, 0, 0])

        let shutdown = Task { await setup.model.shutdown() }
        await Task.yield()
        await coordinatorGate.resume()
        await first.value
        await second.value
        await shutdown.value

        XCTAssertEqual(setup.model.state.lifecycle, .stopped)
        XCTAssertEqual(setup.access.counts, [2, 2])
        XCTAssertNil(setup.model.state.presentation)
    }

    func testNewestPeriodQueryWinsWhenOlderQueryCompletesLast() async throws {
        let setup = try makeSetup(approved: false)
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.startHistoricalImport()
        await setup.query.hold(periods: [.thisWeek, .thisMonth])

        let older = Task { await setup.model.select(period: .thisWeek) }
        await setup.query.waitUntilPending(.thisWeek)
        let newer = Task { await setup.model.select(period: .thisMonth) }
        await setup.query.waitUntilPending(.thisMonth)
        await setup.query.resume(.thisMonth)
        await newer.value
        await setup.query.resume(.thisWeek)
        await older.value

        XCTAssertEqual(setup.model.state.selectedPeriod, .thisMonth)
        XCTAssertEqual(setup.model.state.presentation?.tokenTitle, "3,000 tokens")
        XCTAssertEqual(setup.preferences.selectedPeriod, .thisMonth)
        let coordinatorCounts = await setup.coordinator.counts()
        XCTAssertEqual(coordinatorCounts, [1, 0, 0])
    }

    func testShutdownAwaitsSuspendedQueryAndRejectsItsLateResult() async throws {
        let setup = try makeSetup(approved: false)
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.startHistoricalImport()
        await setup.query.hold(periods: [.thisWeek])
        let selection = Task { await setup.model.select(period: .thisWeek) }
        await setup.query.waitUntilPending(.thisWeek)

        let shutdown = Task { await setup.model.shutdown() }
        await Task.yield()
        await setup.query.resume(.thisWeek)
        await selection.value
        await shutdown.value

        XCTAssertEqual(setup.model.state.lifecycle, .stopped)
        XCTAssertNil(setup.model.state.presentation)
        XCTAssertEqual(setup.access.counts, [2, 2])
    }

    func testEventBatchRequeriesOnceAndPublishesHonestProviderHealth() async throws {
        let setup = try makeSetup(approved: false)
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.startHistoricalImport()
        let callsBeforeEvent = await setup.query.calls()
        let runID = await setup.coordinator.runID()

        await setup.coordinator.emit(IngestionBatchResult(
            runID: runID,
            providers: [
                .claudeCode: .success(discoveredFiles: 4, scannedFiles: 1),
                .codex: .attention(discoveredFiles: 2, scannedFiles: 1)
            ]
        ))
        await waitUntil { await setup.query.calls() == callsBeforeEvent + 1 }

        guard case let .healthy(fileCount, _) = setup.model.state.sourceHealth[.claudeCode] else {
            return XCTFail("successful provider was not healthy")
        }
        XCTAssertEqual(fileCount, 4)
        guard case .warning = setup.model.state.sourceHealth[.codex] else {
            return XCTFail("attention outcome was mislabeled healthy")
        }
        XCTAssertNotNil(setup.model.state.lastUpdated)
    }

    func testFailedSourceReplacementPreservesOldBookmarkGrantAndPublishedState() async throws {
        let replacement = URL(fileURLWithPath: "/tmp/replacement-failure", isDirectory: true)
        let setup = try makeSetup(
            approved: true,
            pickedSource: replacement,
            discoveryFailureRoot: replacement
        )
        defer { setup.cleanup() }
        await setup.model.start()
        let priorState = setup.model.state
        let priorBookmark = setup.defaults.data(forKey: "sourceBookmark.claude_code")

        await setup.model.chooseSource(.claudeCode)

        XCTAssertEqual(setup.model.state, priorState)
        XCTAssertEqual(setup.defaults.data(forKey: "sourceBookmark.claude_code"), priorBookmark)
        let coordinatorCounts = await setup.coordinator.counts()
        XCTAssertEqual(coordinatorCounts, [1, 0, 0])
        XCTAssertEqual(setup.access.counts, [3, 1])
    }

    func testSuccessfulSourceReplacementStopsCoordinatorBeforeClosingOldGrant() async throws {
        let replacement = URL(fileURLWithPath: "/tmp/replacement-success", isDirectory: true)
        let recorder = ReplacementRecorder()
        let setup = try makeSetup(
            approved: true,
            pickedSource: replacement,
            replacementRecorder: recorder
        )
        defer { setup.cleanup() }
        await setup.model.start()
        recorder.reset()

        await setup.model.chooseSource(.claudeCode)

        XCTAssertEqual(setup.defaults.data(forKey: "sourceBookmark.claude_code"), Data([9]))
        XCTAssertEqual(setup.model.state.sourceFileCounts[.claudeCode], 2)
        let events = recorder.snapshot
        guard let stopIndex = events.firstIndex(of: "coordinator.stop"),
              let closeIndex = events.firstIndex(of: "grant.stop.claude_code") else {
            return XCTFail("missing replacement lifetime events: \(events)")
        }
        XCTAssertTrue(stopIndex < closeIndex)
    }

    private func makeSetup(
        approved: Bool,
        failure: StartupFailurePoint? = nil,
        failureIsOneShot: Bool = false,
        catalogAlreadyApplied: Bool = false,
        startupGate: AsyncTestGate? = nil,
        coordinatorStartGate: AsyncTestGate? = nil,
        pickedSource: URL? = nil,
        discoveryFailureRoot: URL? = nil,
        replacementRecorder: ReplacementRecorder? = nil
    ) throws -> LifecycleSetup {
        let suite = "AppModelLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = AppPreferences(defaults: defaults)
        preferences.historicalImportApproved = approved
        let access = LifecycleBookmarkAccess(recorder: replacementRecorder)
        for provider in Provider.allCases {
            let marker = provider == .claudeCode ? Data([1]) : Data([2])
            let root = URL(fileURLWithPath: "/tmp/\(suite)-\(provider.rawValue)", isDirectory: true)
            defaults.set(marker, forKey: "sourceBookmark.\(provider.rawValue)")
            access.roots[marker] = root
        }
        let ledger = LifecycleLedger(
            failure: failure,
            failureIsOneShot: failureIsOneShot,
            catalogAlreadyApplied: catalogAlreadyApplied,
            startupGate: startupGate
        )
        let inbox = LifecycleInbox(failure: failure == .inbox)
        let coordinator = LifecycleCoordinator(
            startGate: coordinatorStartGate,
            recorder: replacementRecorder
        )
        let query = LifecycleQuery()
        let store = SourceGrantStore(defaults: defaults, bookmarkAccess: access)
        let model = AppModel(
            ledger: ledger,
            queryService: query,
            coordinator: coordinator,
            pricingInbox: inbox,
            grantStore: store,
            preferences: preferences,
            bundledCatalogData: try bundledCatalogData(),
            now: { Date(timeIntervalSince1970: 1_775_000_000) },
            calendar: Calendar(identifier: .gregorian),
            discovery: LifecycleDiscovery(failingRoot: discoveryFailureRoot),
            sourcePicker: LifecycleSourcePicker(url: pickedSource)
        )
        return LifecycleSetup(
            model: model,
            ledger: ledger,
            coordinator: coordinator,
            query: query,
            access: access,
            preferences: preferences,
            defaults: defaults,
            cleanup: { defaults.removePersistentDomain(forName: suite) }
        )
    }

    private func bundledCatalogData() throws -> Data {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: repository.appending(path: "Resources/tokenboard-pricing.json"))
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("condition was not met")
    }
}

private enum StartupFailurePoint: CaseIterable, Sendable {
    case migrate
    case integrity
    case latestCatalog
    case applyCatalog
    case inbox
}

private enum LifecycleFailure: Error {
    case injected
}

private struct LifecycleSetup {
    let model: AppModel
    let ledger: LifecycleLedger
    let coordinator: LifecycleCoordinator
    let query: LifecycleQuery
    let access: LifecycleBookmarkAccess
    let preferences: AppPreferences
    let defaults: UserDefaults
    let cleanup: () -> Void
}

private actor AsyncTestGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor LifecycleLedger: AppLedgerRuntime {
    private var failure: StartupFailurePoint?
    private let failureIsOneShot: Bool
    private let catalogAlreadyApplied: Bool
    private let startupGate: AsyncTestGate?
    private(set) var applyCount = 0

    init(
        failure: StartupFailurePoint?,
        failureIsOneShot: Bool,
        catalogAlreadyApplied: Bool,
        startupGate: AsyncTestGate?
    ) {
        self.failure = failure
        self.failureIsOneShot = failureIsOneShot
        self.catalogAlreadyApplied = catalogAlreadyApplied
        self.startupGate = startupGate
    }

    func migrate() async throws {
        if let startupGate { await startupGate.suspend() }
        try failIfNeeded(.migrate)
    }
    func integrityCheck() throws { try failIfNeeded(.integrity) }
    func latestAppliedPricingCatalogJSON() throws -> Data? {
        try failIfNeeded(.latestCatalog)
        return catalogAlreadyApplied ? Data([1]) : nil
    }
    func applyPricingCatalog(
        _ catalog: ValidatedPricingCatalog,
        canonicalJSON: Data,
        origin: String,
        validationSummary: String
    ) throws {
        try failIfNeeded(.applyCatalog)
        applyCount += 1
    }

    private func failIfNeeded(_ point: StartupFailurePoint) throws {
        guard failure == point else { return }
        if failureIsOneShot { failure = nil }
        throw LifecycleFailure.injected
    }

    func appliedCount() -> Int { applyCount }
}

private actor LifecycleInbox: AppPricingInboxWatching {
    let failure: Bool
    init(failure: Bool) { self.failure = failure }
    func start() throws { if failure { throw LifecycleFailure.injected } }
    func stop() {}
}

private actor LifecycleCoordinator: AppIngestionCoordinating {
    private let startGate: AsyncTestGate?
    private let recorder: ReplacementRecorder?
    private var handler: (@Sendable (IngestionBatchResult) -> Void)?
    private var starts = 0
    private var refreshes = 0
    private var stops = 0
    private(set) var currentRunID: UInt64 = 0
    private var roots: [Provider: URL] = [:]

    init(startGate: AsyncTestGate?, recorder: ReplacementRecorder?) {
        self.startGate = startGate
        self.recorder = recorder
    }

    func setEventBatchHandler(_ handler: (@Sendable (IngestionBatchResult) -> Void)?) {
        self.handler = handler
    }
    func start(roots: [Provider: URL]) async throws -> IngestionBatchResult {
        starts += 1
        currentRunID += 1
        self.roots = roots
        if let startGate { await startGate.suspend() }
        return successResult()
    }
    func refreshAll() -> IngestionBatchResult {
        refreshes += 1
        return successResult()
    }
    func stop() {
        stops += 1
        recorder?.append("coordinator.stop")
    }
    func counts() -> [Int] { [starts, refreshes, stops] }
    func runID() -> UInt64 { currentRunID }
    func emit(_ result: IngestionBatchResult) { handler?(result) }

    private func successResult() -> IngestionBatchResult {
        IngestionBatchResult(
            runID: currentRunID,
            providers: Dictionary(uniqueKeysWithValues: Provider.allCases.map { provider in
                let discovered = roots[provider]?.lastPathComponent.hasPrefix("replacement-") == true
                    ? 2
                    : 0
                return (provider, .success(discoveredFiles: discovered, scannedFiles: 0))
            })
        )
    }
}

private actor LifecycleQuery: AppUsageQuerying {
    private var heldPeriods: Set<CalendarPeriod> = []
    private var continuations: [CalendarPeriod: CheckedContinuation<Void, Never>] = [:]
    private(set) var callCount = 0

    func hold(periods: Set<CalendarPeriod>) { heldPeriods = periods }
    func summary(period: CalendarPeriod, now: Date, calendar: Calendar) async -> UsageSummary {
        callCount += 1
        if heldPeriods.contains(period) {
            await withCheckedContinuation { continuations[period] = $0 }
        }
        let total: Int64 = switch period {
        case .thisWeek: 2_000
        case .thisMonth: 3_000
        default: 1_000
        }
        return UsageSummary(
            period: period,
            tokenTotal: total,
            knownAPIEquivalentUSD: 0,
            unpricedTokens: 0
        )
    }
    func waitUntilPending(_ period: CalendarPeriod) async {
        while continuations[period] == nil { await Task.yield() }
    }
    func resume(_ period: CalendarPeriod) {
        heldPeriods.remove(period)
        continuations.removeValue(forKey: period)?.resume()
    }

    func calls() -> Int { callCount }
}

private struct LifecycleDiscovery: LogDiscovering {
    let failingRoot: URL?

    func jsonlFiles(under root: URL) throws -> [URL] {
        if root.standardizedFileURL == failingRoot?.standardizedFileURL {
            throw LifecycleFailure.injected
        }
        if root.lastPathComponent.hasPrefix("replacement-") {
            return [root.appending(path: "one.jsonl"), root.appending(path: "two.jsonl")]
        }
        return []
    }
}

private final class LifecycleBookmarkAccess: SecurityScopedBookmarkAccessing, @unchecked Sendable {
    private let recorder: ReplacementRecorder?
    var roots: [Data: URL] = [:]
    private var starts = 0
    private var stops = 0
    var counts: [Int] { [starts, stops] }

    init(recorder: ReplacementRecorder?) { self.recorder = recorder }

    func makeBookmark(for url: URL, options: URL.BookmarkCreationOptions) -> Data { Data([9]) }
    func resolveBookmark(
        _ data: Data,
        options: URL.BookmarkResolutionOptions
    ) throws -> ResolvedSourceBookmark {
        ResolvedSourceBookmark(url: roots[data]!, isStale: false)
    }
    func startAccessing(_ url: URL) -> Bool { starts += 1; return true }
    func stopAccessing(_ url: URL) {
        stops += 1
        let provider = url.lastPathComponent.hasSuffix(Provider.claudeCode.rawValue)
            ? Provider.claudeCode
            : Provider.codex
        recorder?.append("grant.stop.\(provider.rawValue)")
    }
}

@MainActor
private struct LifecycleSourcePicker: AppSourcePicking {
    let url: URL?
    func select(provider: Provider) throws -> URL? { url }
}

private final class ReplacementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    var snapshot: [String] { lock.withLock { events } }
    func append(_ event: String) { lock.withLock { events.append(event) } }
    func reset() { lock.withLock { events.removeAll() } }
}
