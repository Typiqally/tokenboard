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

    func testConcurrentShutdownCallersAwaitOneBarrierAndKeepGrantsUntilQuiescent() async throws {
        let stopGate = AsyncTestGate()
        let setup = try makeSetup(approved: false, coordinatorStopGate: stopGate)
        defer { setup.cleanup() }
        await setup.model.start()
        let secondCompleted = AsyncFlag()

        let first = Task { await setup.model.shutdown() }
        await stopGate.waitUntilEntered()
        let second = Task {
            await setup.model.shutdown()
            await secondCompleted.set()
        }
        await Task.yield()

        let completedWhileStopping = await secondCompleted.value()
        XCTAssertFalse(completedWhileStopping)
        XCTAssertEqual(setup.access.counts, [2, 0])
        await stopGate.resume()
        await first.value
        await second.value

        let completedAfterStop = await secondCompleted.value()
        XCTAssertTrue(completedAfterStop)
        XCTAssertEqual(setup.access.counts, [2, 2])
        var coordinatorCounts = await setup.coordinator.counts()
        XCTAssertEqual(coordinatorCounts, [0, 0, 2])
        await setup.model.shutdown()
        coordinatorCounts = await setup.coordinator.counts()
        XCTAssertEqual(coordinatorCounts, [0, 0, 2])
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
            sequence: 2,
            scope: .incremental,
            providers: [
                .claudeCode: .success(discoveredFiles: 4, scannedFiles: 1),
                .codex: .attention(discoveredFiles: 2, scannedFiles: 1)
            ]
        ))
        await waitUntil { await setup.query.calls() == callsBeforeEvent + 1 }

        guard case let .healthy(fileCount, _) = setup.model.state.sourceHealth[.claudeCode] else {
            return XCTFail("successful provider was not healthy")
        }
        XCTAssertEqual(fileCount, 0)
        XCTAssertEqual(setup.model.state.sourceFileCounts[.claudeCode], 0)
        guard case .warning = setup.model.state.sourceHealth[.codex] else {
            return XCTFail("attention outcome was mislabeled healthy")
        }
        XCTAssertNotNil(setup.model.state.lastUpdated)
    }

    func testStartupEventIsBufferedUntilCatchUpActivatesAndThenApplied() async throws {
        let startGate = AsyncTestGate()
        let setup = try makeSetup(approved: true, coordinatorStartGate: startGate)
        defer { setup.cleanup() }
        let start = Task { await setup.model.start() }
        await startGate.waitUntilEntered()
        await setup.coordinator.emit(IngestionBatchResult(
            runID: 1,
            sequence: 2,
            scope: .incremental,
            providers: [.codex: .attention(discoveredFiles: 1, scannedFiles: 1)]
        ))
        await startGate.resume()
        await start.value
        await waitUntil {
            guard case .warning = setup.model.state.sourceHealth[.codex] else { return false }
            return true
        }

        guard case .warning = setup.model.state.sourceHealth[.codex] else {
            return XCTFail("startup event was discarded")
        }
    }

    func testNewerIncrementalResultWinsAndPreservesFullInventoryCount() async throws {
        let setup = try makeSetup(approved: false)
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.startHistoricalImport()
        let runID = await setup.coordinator.runID()
        let calls = await setup.query.calls()

        await setup.coordinator.emit(IngestionBatchResult(
            runID: runID,
            sequence: 2,
            scope: .inventory,
            providers: [.claudeCode: .success(discoveredFiles: 8, scannedFiles: 8)]
        ))
        let inventoryCalls = calls + 1
        await waitUntil { await setup.query.calls() == inventoryCalls }
        await setup.coordinator.emit(IngestionBatchResult(
            runID: runID,
            sequence: 4,
            scope: .incremental,
            providers: [.claudeCode: .attention(discoveredFiles: 1, scannedFiles: 1)]
        ))
        let newerCalls = inventoryCalls + 1
        await waitUntil { await setup.query.calls() == newerCalls }
        await setup.coordinator.emit(IngestionBatchResult(
            runID: runID,
            sequence: 3,
            scope: .inventory,
            providers: [.claudeCode: .success(discoveredFiles: 3, scannedFiles: 3)]
        ))
        await Task.yield()

        XCTAssertEqual(setup.model.state.sourceFileCounts[.claudeCode], 8)
        guard case .warning = setup.model.state.sourceHealth[.claudeCode] else {
            return XCTFail("older inventory result overwrote newer attention")
        }
    }

    func testFailedIncrementalAttemptDoesNotAdvanceLastSuccessfulUpdate() async throws {
        let dates = IncrementingNow()
        let setup = try makeSetup(approved: false, now: { dates() })
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.startHistoricalImport()
        let successfulUpdate = setup.model.state.lastUpdated
        let runID = await setup.coordinator.runID()
        let calls = await setup.query.calls()

        await setup.coordinator.emit(IngestionBatchResult(
            runID: runID,
            sequence: 2,
            scope: .incremental,
            providers: [.claudeCode: .failure(discoveredFiles: 1, scannedFiles: 1)]
        ))
        await waitUntil { await setup.query.calls() == calls + 1 }

        XCTAssertEqual(setup.model.state.lastUpdated, successfulUpdate)
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

        let runID = await setup.coordinator.runID()
        let calls = await setup.query.calls()
        await setup.coordinator.emit(IngestionBatchResult(
            runID: runID,
            sequence: 2,
            scope: .incremental,
            providers: [.claudeCode: .attention(discoveredFiles: 1, scannedFiles: 1)]
        ))
        await waitUntil { await setup.query.calls() == calls + 1 }
        guard case .warning = setup.model.state.sourceHealth[.claudeCode] else {
            return XCTFail("replacement runtime did not receive events")
        }
    }

    func testOverlappingReplacementIsRejectedBeforeStopBookmarkOrOldGrantMutation() async throws {
        let setup = try makeSetup(
            approved: true,
            pickedSource: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )
        defer { setup.cleanup() }
        await setup.model.start()
        let priorState = setup.model.state
        let priorBookmark = setup.defaults.data(forKey: "sourceBookmark.claude_code")
        let priorCounts = await setup.coordinator.counts()

        await setup.model.chooseSource(.claudeCode)

        XCTAssertEqual(setup.model.state, priorState)
        XCTAssertEqual(setup.defaults.data(forKey: "sourceBookmark.claude_code"), priorBookmark)
        let finalCounts = await setup.coordinator.counts()
        XCTAssertEqual(finalCounts, priorCounts)
        XCTAssertEqual(setup.access.counts, [3, 1])
    }

    func testFirstSourceGrantSucceedsBeforeACompleteRootPairExists() async throws {
        let source = URL(fileURLWithPath: "/tmp/replacement-first-source", isDirectory: true)
        let setup = try makeSetup(
            approved: false,
            grantedProviders: [],
            pickedSource: source
        )
        defer { setup.cleanup() }
        await setup.model.start()

        await setup.model.chooseSource(.claudeCode)

        XCTAssertTrue(setup.model.hasActiveGrant(for: .claudeCode))
        XCTAssertEqual(setup.defaults.data(forKey: "sourceBookmark.claude_code"), Data([9]))
        XCTAssertEqual(setup.model.state.sourceFileCounts[.claudeCode], 2)
        XCTAssertEqual(setup.model.state.grantedProviders, [.claudeCode])
        let counts = await setup.coordinator.counts()
        XCTAssertEqual(counts, [0, 0, 1])
    }

    func testFailedReplacementRestartRestoresOldBookmarkGrantAndRuntime() async throws {
        let dates = IncrementingNow()
        let replacement = URL(
            fileURLWithPath: "/tmp/replacement-restart-failure",
            isDirectory: true
        )
        let setup = try makeSetup(
            approved: true,
            pickedSource: replacement,
            coordinatorFailingStartRoot: replacement,
            now: { dates() }
        )
        defer { setup.cleanup() }
        await setup.model.start()
        let priorState = setup.model.state
        let priorBookmark = setup.defaults.data(forKey: "sourceBookmark.claude_code")

        await setup.model.chooseSource(.claudeCode)

        XCTAssertEqual(setup.model.state, priorState)
        XCTAssertEqual(setup.defaults.data(forKey: "sourceBookmark.claude_code"), priorBookmark)
        XCTAssertEqual(setup.access.counts, [3, 1])
        let counts = await setup.coordinator.counts()
        XCTAssertEqual(counts[0], 3)
        let restoredRoots = await setup.coordinator.activeRoots()
        XCTAssertFalse(restoredRoots[.claudeCode]?.lastPathComponent.hasPrefix("replacement-") == true)
    }

    func testRetryCleansUpOneShotCatalogAndInboxFailures() async throws {
        let catalog = try makeSetup(
            approved: false,
            failure: .applyCatalog,
            failureIsOneShot: true,
            catalogCommitBeforeFailure: true
        )
        defer { catalog.cleanup() }
        await catalog.model.start()
        await catalog.model.refresh()
        XCTAssertEqual(catalog.model.state.lifecycle, .ready)
        let applyCount = await catalog.ledger.appliedCount()
        XCTAssertEqual(applyCount, 1)

        let inbox = try makeSetup(
            approved: false,
            failure: .inbox,
            failureIsOneShot: true
        )
        defer { inbox.cleanup() }
        await inbox.model.start()
        let failedInboxCounts = await inbox.inbox.counts()
        XCTAssertEqual(failedInboxCounts, [1, 1])
        await inbox.model.refresh()
        XCTAssertEqual(inbox.model.state.lifecycle, .ready)
        let recoveredInboxCounts = await inbox.inbox.counts()
        XCTAssertEqual(recoveredInboxCounts, [2, 1])
    }

    private func makeSetup(
        approved: Bool,
        grantedProviders: Set<Provider> = Set(Provider.allCases),
        failure: StartupFailurePoint? = nil,
        failureIsOneShot: Bool = false,
        catalogAlreadyApplied: Bool = false,
        startupGate: AsyncTestGate? = nil,
        coordinatorStartGate: AsyncTestGate? = nil,
        coordinatorStopGate: AsyncTestGate? = nil,
        pickedSource: URL? = nil,
        discoveryFailureRoot: URL? = nil,
        replacementRecorder: ReplacementRecorder? = nil,
        coordinatorFailingStartRoot: URL? = nil,
        catalogCommitBeforeFailure: Bool = false,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_775_000_000) }
    ) throws -> LifecycleSetup {
        let suite = "AppModelLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = AppPreferences(defaults: defaults)
        preferences.historicalImportApproved = approved
        let access = LifecycleBookmarkAccess(recorder: replacementRecorder)
        for provider in grantedProviders {
            let marker = provider == .claudeCode ? Data([1]) : Data([2])
            let root = URL(fileURLWithPath: "/tmp/\(suite)-\(provider.rawValue)", isDirectory: true)
            defaults.set(marker, forKey: "sourceBookmark.\(provider.rawValue)")
            access.roots[marker] = root
        }
        let ledger = LifecycleLedger(
            failure: failure,
            failureIsOneShot: failureIsOneShot,
            catalogAlreadyApplied: catalogAlreadyApplied,
            catalogCommitBeforeFailure: catalogCommitBeforeFailure,
            startupGate: startupGate
        )
        let inbox = LifecycleInbox(
            failure: failure == .inbox,
            failureIsOneShot: failureIsOneShot
        )
        let coordinator = LifecycleCoordinator(
            startGate: coordinatorStartGate,
            stopGate: coordinatorStopGate,
            failingStartRoot: coordinatorFailingStartRoot,
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
            now: now,
            calendar: Calendar(identifier: .gregorian),
            discovery: LifecycleDiscovery(failingRoot: discoveryFailureRoot),
            sourcePicker: LifecycleSourcePicker(url: pickedSource)
        )
        return LifecycleSetup(
            model: model,
            ledger: ledger,
            inbox: inbox,
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

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async {
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
    let inbox: LifecycleInbox
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

private actor AsyncFlag {
    private var current = false
    func set() { current = true }
    func value() -> Bool { current }
}

private actor LifecycleLedger: AppLedgerRuntime {
    private var failure: StartupFailurePoint?
    private let failureIsOneShot: Bool
    private let catalogAlreadyApplied: Bool
    private let catalogCommitBeforeFailure: Bool
    private let startupGate: AsyncTestGate?
    private(set) var applyCount = 0
    private var appliedCatalog: Data?

    init(
        failure: StartupFailurePoint?,
        failureIsOneShot: Bool,
        catalogAlreadyApplied: Bool,
        catalogCommitBeforeFailure: Bool,
        startupGate: AsyncTestGate?
    ) {
        self.failure = failure
        self.failureIsOneShot = failureIsOneShot
        self.catalogAlreadyApplied = catalogAlreadyApplied
        self.catalogCommitBeforeFailure = catalogCommitBeforeFailure
        self.startupGate = startupGate
        appliedCatalog = catalogAlreadyApplied ? Data([1]) : nil
    }

    func migrate() async throws {
        if let startupGate { await startupGate.suspend() }
        try failIfNeeded(.migrate)
    }
    func integrityCheck() throws { try failIfNeeded(.integrity) }
    func latestAppliedPricingCatalogJSON() throws -> Data? {
        try failIfNeeded(.latestCatalog)
        return appliedCatalog
    }
    func applyPricingCatalog(
        _ catalog: ValidatedPricingCatalog,
        canonicalJSON: Data,
        origin: String,
        validationSummary: String
    ) throws {
        if failure == .applyCatalog, !catalogCommitBeforeFailure {
            try failIfNeeded(.applyCatalog)
        }
        applyCount += 1
        appliedCatalog = canonicalJSON
        if failure == .applyCatalog, catalogCommitBeforeFailure {
            if failureIsOneShot { failure = nil }
            throw LifecycleFailure.injected
        }
        try failIfNeeded(.applyCatalog)
    }

    private func failIfNeeded(_ point: StartupFailurePoint) throws {
        guard failure == point else { return }
        if failureIsOneShot { failure = nil }
        throw LifecycleFailure.injected
    }

    func appliedCount() -> Int { applyCount }
}

private actor LifecycleInbox: AppPricingInboxWatching {
    private var failure: Bool
    private let failureIsOneShot: Bool
    private var starts = 0
    private var stops = 0
    init(failure: Bool, failureIsOneShot: Bool) {
        self.failure = failure
        self.failureIsOneShot = failureIsOneShot
    }
    func start() throws {
        starts += 1
        if failure {
            if failureIsOneShot { failure = false }
            throw LifecycleFailure.injected
        }
    }
    func stop() { stops += 1 }
    func counts() -> [Int] { [starts, stops] }
}

private actor LifecycleCoordinator: AppIngestionCoordinating {
    private let startGate: AsyncTestGate?
    private let stopGate: AsyncTestGate?
    private let failingStartRoot: URL?
    private let recorder: ReplacementRecorder?
    private var resultContinuation: AsyncStream<IngestionBatchResult>.Continuation?
    private var starts = 0
    private var refreshes = 0
    private var stops = 0
    private(set) var currentRunID: UInt64 = 0
    private var currentSequence: UInt64 = 0
    private var roots: [Provider: URL] = [:]
    private var shouldSuspendStop = true
    private var shouldFailReplacementStart = true

    init(
        startGate: AsyncTestGate?,
        stopGate: AsyncTestGate?,
        failingStartRoot: URL?,
        recorder: ReplacementRecorder?
    ) {
        self.startGate = startGate
        self.stopGate = stopGate
        self.failingStartRoot = failingStartRoot
        self.recorder = recorder
    }

    func results() -> AsyncStream<IngestionBatchResult> {
        AsyncStream { continuation in resultContinuation = continuation }
    }
    func start(roots: [Provider: URL]) async throws -> IngestionBatchResult {
        starts += 1
        currentRunID += 1
        currentSequence = 0
        self.roots = roots
        if shouldFailReplacementStart,
           let failingStartRoot,
           roots.values.contains(where: {
               $0.lastPathComponent == failingStartRoot.lastPathComponent
           }) {
            shouldFailReplacementStart = false
            throw LifecycleFailure.injected
        }
        let result = successResult(scope: .inventory)
        resultContinuation?.yield(result)
        if let startGate { await startGate.suspend() }
        return result
    }
    func refreshAll() -> IngestionBatchResult {
        refreshes += 1
        let result = successResult(scope: .inventory)
        resultContinuation?.yield(result)
        return result
    }
    func stop() async {
        stops += 1
        recorder?.append("coordinator.stop")
        if shouldSuspendStop, let stopGate {
            shouldSuspendStop = false
            await stopGate.suspend()
        }
    }
    func counts() -> [Int] { [starts, refreshes, stops] }
    func runID() -> UInt64 { currentRunID }
    func activeRoots() -> [Provider: URL] { roots }
    func emit(_ result: IngestionBatchResult) {
        resultContinuation?.yield(result)
    }

    private func successResult(scope: IngestionBatchScope) -> IngestionBatchResult {
        currentSequence += 1
        return IngestionBatchResult(
            runID: currentRunID,
            sequence: currentSequence,
            scope: scope,
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
        if let failingRoot,
           root.lastPathComponent == failingRoot.lastPathComponent {
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

private final class IncrementingNow: @unchecked Sendable {
    private let lock = NSLock()
    private var tick: TimeInterval = 1_775_000_000

    func callAsFunction() -> Date {
        lock.withLock {
            defer { tick += 1 }
            return Date(timeIntervalSince1970: tick)
        }
    }
}
