import Foundation
import XCTest
@testable import TokenboardCore

final class IngestionCoordinatorTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testWatcherStartupFailureLeavesCoordinatorInactiveWithoutInventoryWork() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let watcher = FakeSourceEventWatcher(startError: .injected)
        let scanner = RecordingScanner()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: ManualIngestionClock(),
            calendar: calendar
        )

        do {
            _ = try await coordinator.start(roots: setup.roots)
            XCTFail("expected watcher startup to fail")
        } catch {
            XCTAssertEqual(error as? FakeSourceEventWatcher.StartError, .injected)
        }

        XCTAssertEqual(watcher.eventsRequestCount, 1)
        XCTAssertEqual(
            watcher.requestedRoots.map(\.path),
            [setup.claudeRoot.path, setup.codexRoot.path]
        )
        XCTAssertFalse(watcher.isActive)
        let scannedURLs = await scanner.scannedURLs
        XCTAssertEqual(scannedURLs, [])
        let refresh = await coordinator.refreshAll()
        XCTAssertEqual(refresh.runID, 1)
        XCTAssertEqual(refresh.sequence, 0)
        XCTAssertEqual(
            refresh.providers,
            Dictionary(uniqueKeysWithValues: Provider.allCases.map {
                ($0, .failure(discoveredFiles: 0, scannedFiles: 0))
            })
        )
        let diagnostics = await coordinator.diagnostics()
        XCTAssertEqual(diagnostics.pendingBatchCount, 0)
        XCTAssertFalse(diagnostics.isDraining)
    }

    func testRapidEventsAreDebouncedDeduplicatedAndScannedSerially() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let watcher = FakeSourceEventWatcher()
        let scanner = RecordingScanner()
        let clock = ManualIngestionClock()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: clock,
            calendar: calendar
        )
        _ = try await coordinator.start(roots: setup.roots)
        let changedA = setup.claudeRoot.appending(path: "a.jsonl")
        let changedB = setup.codexRoot.appending(path: "nested/b.jsonl")
        try FileManager.default.createDirectory(
            at: changedB.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: changedA)
        try Data().write(to: changedB)

        watcher.emit([changedA])
        await clock.waitForSleepStartCount(1)
        watcher.emit([changedA, changedB])
        await waitUntil { await clock.debounceRestarted }
        await clock.advancePastDebounce()
        await waitUntil { await scanner.scannedURLs.count == 2 }

        let scannedURLs = await scanner.scannedURLs
        let scannedProviders = await scanner.scannedProviders
        let maximumConcurrentScans = await scanner.maximumConcurrentScans
        let debounceRequests = await clock.requestCount(for: .milliseconds(750))
        let maximumLatencyRequests = await clock.requestCount(
            for: IngestionCoordinator.maximumEventLatency
        )
        XCTAssertEqual(scannedURLs, [changedA, changedB])
        XCTAssertEqual(scannedProviders, [.claudeCode, .codex])
        XCTAssertEqual(maximumConcurrentScans, 1)
        XCTAssertEqual(debounceRequests, 2)
        XCTAssertEqual(maximumLatencyRequests, 1)
        XCTAssertEqual(coordinator.usesPeriodicRefresh, false)
        await coordinator.stop()
    }

    func testRefreshAllDiscoversAndScansEveryFileImmediately() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let claudeFile = setup.claudeRoot.appending(path: "project/session.jsonl")
        let codexFile = setup.codexRoot.appending(path: "session.jsonl")
        try FileManager.default.createDirectory(
            at: claudeFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: claudeFile)
        try Data().write(to: codexFile)
        let watcher = FakeSourceEventWatcher()
        let scanner = RecordingScanner()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: ManualIngestionClock(),
            calendar: calendar
        )

        let initial = try await coordinator.start(roots: setup.roots)

        var scannedURLs = await scanner.scannedURLs
        XCTAssertEqual(scannedURLs, [claudeFile, codexFile])
        XCTAssertEqual(initial.providers[.claudeCode], .success(discoveredFiles: 1, scannedFiles: 1))
        XCTAssertEqual(initial.providers[.codex], .success(discoveredFiles: 1, scannedFiles: 1))
        XCTAssertEqual(initial.scope, .inventory)
        XCTAssertEqual(initial.sequence, 1)
        await scanner.reset()
        let refreshed = await coordinator.refreshAll()
        scannedURLs = await scanner.scannedURLs
        XCTAssertEqual(scannedURLs, [claudeFile, codexFile])
        XCTAssertEqual(refreshed.providers[.claudeCode], .success(discoveredFiles: 1, scannedFiles: 1))
        XCTAssertEqual(refreshed.providers[.codex], .success(discoveredFiles: 1, scannedFiles: 1))
        XCTAssertEqual(refreshed.scope, .inventory)
        XCTAssertEqual(refreshed.sequence, 2)
        XCTAssertEqual(
            watcher.requestedRoots.map(\.path),
            [setup.claudeRoot.path, setup.codexRoot.path]
        )
        await coordinator.stop()
    }

    func testStartMonitoringInventoriesAndWatchesOneApprovedRoot() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let file = setup.codexRoot.appending(path: "retained.jsonl")
        try Data().write(to: file)
        let watcher = FakeSourceEventWatcher()
        let scanner = RecordingScanner()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: ManualIngestionClock(),
            calendar: calendar
        )

        let result = try await coordinator.startMonitoring(
            roots: [.codex: setup.codexRoot]
        )

        XCTAssertEqual(result.providers, [
            .codex: .success(discoveredFiles: 1, scannedFiles: 1)
        ])
        let scannedURLs = await scanner.scannedURLs
        XCTAssertEqual(scannedURLs, [file])
        XCTAssertEqual(watcher.requestedRoots.map(\.path), [setup.codexRoot.path])
        await coordinator.stop()
    }

    func testReplacingOneSourceInventoriesOnlyThatProviderAndKeepsBothRootsWatched() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let watcher = FakeSourceEventWatcher()
        let scanner = RecordingScanner()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: ManualIngestionClock(),
            calendar: calendar
        )
        _ = try await coordinator.start(roots: setup.roots)
        await scanner.reset()

        let replacementRoot = setup.directory.appending(path: "claude-replacement")
        try FileManager.default.createDirectory(at: replacementRoot, withIntermediateDirectories: true)
        let replacementFile = replacementRoot.appending(path: "replacement.jsonl")
        try Data().write(to: replacementFile)
        var roots = setup.roots
        roots[.claudeCode] = replacementRoot

        let result = try await coordinator.replaceSource(
            .claudeCode,
            with: replacementRoot,
            roots: roots
        )

        let scannedURLs = await scanner.scannedURLs
        let scannedProviders = await scanner.scannedProviders
        XCTAssertEqual(scannedURLs, [replacementFile])
        XCTAssertEqual(scannedProviders, [.claudeCode])
        XCTAssertEqual(
            result.providers,
            [.claudeCode: .success(discoveredFiles: 1, scannedFiles: 1)]
        )
        XCTAssertEqual(
            watcher.requestedRoots.map(\.path),
            [replacementRoot.path, setup.codexRoot.path]
        )
        await coordinator.stop()
    }

    func testReplacingTheOnlyRemainingSourceKeepsOneRootWatched() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let watcher = FakeSourceEventWatcher()
        let scanner = RecordingScanner()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: ManualIngestionClock(),
            calendar: calendar
        )

        _ = try await coordinator.revokeSource(
            .claudeCode,
            remainingRoots: [.codex: setup.codexRoot]
        )
        await scanner.reset()
        let replacement = setup.directory.appending(path: "codex-replacement")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let replacementFile = replacement.appending(path: "replacement.jsonl")
        try Data().write(to: replacementFile)
        let result = try await coordinator.replaceSource(
            .codex,
            with: replacement,
            roots: [.codex: replacement]
        )

        let scannedURLs = await scanner.scannedURLs
        let scannedProviders = await scanner.scannedProviders
        XCTAssertEqual(
            watcher.requestedRoots.map(\.path),
            [replacement.standardizedFileURL.path]
        )
        XCTAssertEqual(Set(result.providers.keys), [.codex])
        XCTAssertEqual(scannedURLs, [replacementFile])
        XCTAssertEqual(scannedProviders, [.codex])
        await coordinator.stop()
    }

    func testRevokingOneSourceKeepsOnlyTheOtherRootWatchedWithoutRescanningIt() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let watcher = FakeSourceEventWatcher()
        let scanner = RecordingScanner()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: ManualIngestionClock(),
            calendar: calendar
        )
        _ = try await coordinator.start(roots: setup.roots)
        await scanner.reset()

        try await coordinator.revokeSource(
            .claudeCode,
            remainingRoots: [.codex: setup.codexRoot]
        )

        let scannedURLs = await scanner.scannedURLs
        XCTAssertEqual(scannedURLs, [])
        XCTAssertEqual(watcher.requestedRoots.map(\.path), [setup.codexRoot.path])
        XCTAssertEqual(watcher.eventsRequestCount, 2)
        await coordinator.stop()
    }

    func testReplacementPreservesDebouncedRetainedProviderPathExactlyOnce() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let retainedOldFile = setup.codexRoot.appending(path: "old.jsonl")
        let retainedEventFile = setup.codexRoot.appending(path: "changed.jsonl")
        try Data().write(to: retainedOldFile)
        try Data().write(to: retainedEventFile)
        let watcher = FakeSourceEventWatcher()
        let scanner = RecordingScanner()
        let clock = ManualIngestionClock()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: clock,
            calendar: calendar
        )
        _ = try await coordinator.start(roots: setup.roots)
        await scanner.reset()
        watcher.emit([retainedEventFile])
        await clock.waitForSleepStartCount(1)

        let replacementRoot = setup.directory.appending(path: "claude-handoff")
        try FileManager.default.createDirectory(at: replacementRoot, withIntermediateDirectories: true)
        let replacementFile = replacementRoot.appending(path: "replacement.jsonl")
        try Data().write(to: replacementFile)
        var roots = setup.roots
        roots[.claudeCode] = replacementRoot
        _ = try await coordinator.replaceSource(
            .claudeCode,
            with: replacementRoot,
            roots: roots
        )

        let scannedURLs = await scanner.scannedURLs
        XCTAssertEqual(scannedURLs.filter { $0 == retainedEventFile }.count, 1)
        XCTAssertFalse(scannedURLs.contains(retainedOldFile))
        XCTAssertTrue(scannedURLs.contains(replacementFile))
        await coordinator.stop()
    }

    func testRevokeDrainsRetainedProviderDeliveryAtWatcherStopExactlyOnce() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let retainedEventFile = setup.codexRoot.appending(path: "handoff.jsonl")
        try Data().write(to: retainedEventFile)
        let watcher = FakeSourceEventWatcher()
        let scanner = RecordingScanner()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: ManualIngestionClock(),
            calendar: calendar
        )
        _ = try await coordinator.start(roots: setup.roots)
        await scanner.reset()
        watcher.emitOnNextStop([retainedEventFile])

        _ = try await coordinator.revokeSource(
            .claudeCode,
            remainingRoots: [.codex: setup.codexRoot]
        )

        let scannedURLs = await scanner.scannedURLs
        XCTAssertEqual(scannedURLs, [retainedEventFile])
        await coordinator.stop()
    }

    func testRetainedEventReplayAcrossReplacementKeepsFinalLedgerUsageExact() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let ledger = try SQLiteLedger(
            databaseURL: setup.directory.appending(path: "ledger.sqlite"),
            backupDirectory: setup.directory.appending(path: "Backups")
        )
        try await ledger.migrate()
        let watcher = FakeSourceEventWatcher()
        let clock = ManualIngestionClock()
        let coordinator = IngestionCoordinator(
            scanner: IncrementalScanner(ledger: ledger),
            watcher: watcher,
            clock: clock,
            calendar: calendar
        )
        _ = try await coordinator.start(roots: setup.roots)
        let changed = setup.codexRoot.appending(path: "replayed.jsonl")
        let source = #"""
        {"type":"session_meta","payload":{"id":"session-replay"}}
        {"type":"turn_context","payload":{"model":"gpt-test"}}
        {"timestamp":"2026-08-05T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":3,"cached_input_tokens":1,"output_tokens":2,"total_tokens":5}}}}
        """#
        try Data("\(source)\n".utf8).write(to: changed)
        watcher.emit([changed])
        await clock.waitForSleepStartCount(1)

        let replacement = setup.directory.appending(path: "claude-replacement")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        var newRoots = setup.roots
        newRoots[.claudeCode] = replacement
        _ = try await coordinator.replaceSource(
            .claudeCode,
            with: replacement,
            roots: newRoots
        )

        watcher.emit([changed])
        await clock.waitForSleepStartCount(2)
        await clock.advancePastDebounce()
        await waitUntil {
            let diagnostics = await coordinator.diagnostics()
            return !diagnostics.isDraining && diagnostics.pendingBatchCount == 0
        }
        let rows = try await ledger.usageRows(in: nil, calendar: calendar)

        XCTAssertEqual(
            rows.filter { $0.metric.countsTowardTokenTotal }.reduce(0) { $0 + $1.quantity },
            5
        )
        await coordinator.stop()
    }

    func testWrappedRootRecoveryAcrossReplacementKeepsLedgerExactAndAcknowledgesReset() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let ledger = try SQLiteLedger(
            databaseURL: setup.directory.appending(path: "wrapped-ledger.sqlite"),
            backupDirectory: setup.directory.appending(path: "WrappedBackups")
        )
        try await ledger.migrate()
        let watcher = FakeSourceEventWatcher()
        let clock = ManualIngestionClock()
        let coordinator = IngestionCoordinator(
            scanner: IncrementalScanner(ledger: ledger),
            watcher: watcher,
            clock: clock,
            calendar: calendar
        )
        _ = try await coordinator.start(roots: setup.roots)
        let changed = setup.codexRoot.appending(path: "wrapped-recovery.jsonl")
        let source = #"""
        {"type":"session_meta","payload":{"id":"session-wrap"}}
        {"type":"turn_context","payload":{"model":"gpt-test"}}
        {"timestamp":"2026-08-05T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":3,"cached_input_tokens":1,"output_tokens":2,"total_tokens":5}}}}
        """#
        try Data("\(source)\n".utf8).write(to: changed)
        let reset = SourceEventCheckpoint(eventID: 7, disposition: .reset)
        watcher.emit(SourceEventBatch(paths: [setup.codexRoot], checkpoint: reset))
        await clock.waitForSleepStartCount(1)

        let replacement = setup.directory.appending(path: "claude-wrap-replacement")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        var newRoots = setup.roots
        newRoots[.claudeCode] = replacement
        _ = try await coordinator.replaceSource(
            .claudeCode,
            with: replacement,
            roots: newRoots
        )

        watcher.emit(SourceEventBatch(
            paths: [setup.codexRoot],
            checkpoint: SourceEventCheckpoint(eventID: 8)
        ))
        await clock.waitForSleepStartCount(2)
        await clock.advancePastDebounce()
        await waitUntil {
            let diagnostics = await coordinator.diagnostics()
            return !diagnostics.isDraining && diagnostics.pendingBatchCount == 0
        }
        let rows = try await ledger.usageRows(in: nil, calendar: calendar)

        XCTAssertEqual(watcher.acknowledgements, [
            reset,
            SourceEventCheckpoint(eventID: 8)
        ])
        XCTAssertEqual(
            rows.filter { $0.metric.countsTowardTokenTotal }.reduce(0) { $0 + $1.quantity },
            5
        )
        await coordinator.stop()
    }

    func testTransitionCollapsesCombinedRetainedOverflowToProviderRoot() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let watcher = FakeSourceEventWatcher()
        let scanner = RecordingScanner(suspendFirstScan: true)
        let clock = ManualIngestionClock()
        let discovery = ChunkedLogicalDiscovery(counts: [:])
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: clock,
            discovery: discovery,
            calendar: calendar
        )
        _ = try await coordinator.start(roots: setup.roots)
        discovery.resetMetrics()
        let active = Set((0..<64).map {
            setup.codexRoot.appending(path: "active-\($0).jsonl")
        })
        for path in active {
            try Data().write(to: path)
        }
        watcher.emit(active)
        await clock.waitForSleepStartCount(1)
        await clock.advancePastDebounce()
        await scanner.waitForScanCount(1)

        let pending = Set((0..<64).map {
            setup.codexRoot.appending(path: "pending-\($0).jsonl")
        })
        watcher.emit(pending)
        await clock.waitForSleepStartCount(2)
        let replacement = setup.directory.appending(path: "claude-replacement-bound")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        var roots = setup.roots
        roots[.claudeCode] = replacement
        let transition = Task {
            try await coordinator.replaceSource(
                .claudeCode,
                with: replacement,
                roots: roots
            )
        }
        await scanner.waitUntilCancelled()
        await scanner.resumeFirstScan()
        _ = try await transition.value

        let snapshot = discovery.snapshot()
        let diagnostics = await coordinator.diagnostics()
        XCTAssertEqual(snapshot.rootNames, ["codex", "claude-replacement-bound"])
        XCTAssertLessThanOrEqual(
            diagnostics.pendingEventPathCount,
            IngestionCoordinator.maximumPendingEventPaths
        )
        await coordinator.stop()
    }

    func testCatchUpReportsAttentionAndFailureWithoutPathsOrMessages() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let claudeFile = setup.claudeRoot.appending(path: "attention.jsonl")
        let codexFile = setup.codexRoot.appending(path: "failure.jsonl")
        try Data().write(to: claudeFile)
        try Data().write(to: codexFile)
        let scanner = RecordingScanner(
            outcomes: [
                .claudeCode: ScanOutcome(
                    committedUsageRecords: 0,
                    skippedRecords: 0,
                    finalOffset: 0,
                    attention: .truncated
                )
            ],
            failingProviders: [.codex]
        )
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: FakeSourceEventWatcher(),
            clock: ManualIngestionClock(),
            calendar: calendar
        )

        let result = try await coordinator.start(roots: setup.roots)

        XCTAssertEqual(result.providers[.claudeCode], .attention(discoveredFiles: 1, scannedFiles: 1))
        XCTAssertEqual(result.providers[.codex], .failure(discoveredFiles: 1, scannedFiles: 1))
        await coordinator.stop()
    }

    func testSkippedUnknownFormatReportsAttentionAndBoundedDiagnostics() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let claudeFile = setup.claudeRoot.appending(path: "unknown.jsonl")
        try Data().write(to: claudeFile)
        let scanner = RecordingScanner(outcomes: [
            .claudeCode: ScanOutcome(
                committedUsageRecords: 0,
                skippedRecords: 3,
                finalOffset: 0
            )
        ])
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: FakeSourceEventWatcher(),
            clock: ManualIngestionClock(),
            calendar: calendar
        )

        let result = try await coordinator.start(roots: setup.roots)

        XCTAssertEqual(
            result.providers[.claudeCode],
            .attention(discoveredFiles: 1, scannedFiles: 1)
        )
        XCTAssertEqual(
            result.diagnostics[.claudeCode],
            ProviderIngestionDiagnostics(skippedRecordCount: 3, attention: [])
        )
        await coordinator.stop()
    }

    func testDiscoveryFailureIsReportedAndDoesNotBecomeHealthySuccess() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let coordinator = IngestionCoordinator(
            scanner: RecordingScanner(),
            watcher: FakeSourceEventWatcher(),
            clock: ManualIngestionClock(),
            discovery: ProviderFailingDiscovery(failingRoot: setup.claudeRoot),
            calendar: calendar
        )

        let result = try await coordinator.start(roots: setup.roots)

        XCTAssertEqual(result.providers[.claudeCode], .failure(discoveredFiles: 0, scannedFiles: 0))
        XCTAssertEqual(result.providers[.codex], .success(discoveredFiles: 0, scannedFiles: 0))
        await coordinator.stop()
    }

    func testOnlyDrainedEventBatchIsStreamedOnce() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let watcher = FakeSourceEventWatcher()
        let clock = ManualIngestionClock()
        let coordinator = IngestionCoordinator(
            scanner: RecordingScanner(),
            watcher: watcher,
            clock: clock,
            calendar: calendar
        )
        let results = await coordinator.results()
        let completion = Task { () -> IngestionBatchResult? in
            for await result in results { return result }
            return nil
        }
        let initial = try await coordinator.start(roots: setup.roots)
        let changed = setup.claudeRoot.appending(path: "changed.jsonl")
        try Data().write(to: changed)

        watcher.emit([changed, changed])
        await clock.waitForSleepStartCount(1)
        await clock.advancePastDebounce()
        let value = await completion.value
        XCTAssertEqual(value?.runID, initial.runID)
        XCTAssertEqual(value?.sequence, initial.sequence + 1)
        XCTAssertEqual(value?.scope, .incremental)
        XCTAssertEqual(value?.providers[.claudeCode], .success(discoveredFiles: 1, scannedFiles: 1))
        XCTAssertNil(value?.providers[.codex])
        await coordinator.stop()
    }

    func testEventArrivingDuringStartupCatchUpIsDeliveredAfterInventoryResult() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let initialFile = setup.claudeRoot.appending(path: "initial.jsonl")
        let eventFile = setup.codexRoot.appending(path: "event.jsonl")
        try Data().write(to: initialFile)
        let watcher = FakeSourceEventWatcher()
        let scanner = RecordingScanner(suspendFirstScan: true)
        let clock = ManualIngestionClock()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: clock,
            calendar: calendar
        )
        let stream = await coordinator.results()
        let received = Task { () -> IngestionBatchResult? in
            for await result in stream { return result }
            return nil
        }

        let start = Task { try await coordinator.start(roots: setup.roots) }
        await waitUntil { await scanner.activeScans == 1 }
        try Data().write(to: eventFile)
        watcher.emit([eventFile])
        await clock.waitForSleepStartCount(1)
        await clock.advancePastDebounce()
        await scanner.resumeFirstScan()
        let initial = try await start.value
        let value = await received.value

        XCTAssertEqual(value?.sequence, initial.sequence + 1)
        XCTAssertEqual(value?.scope, .incremental)
        XCTAssertEqual(value?.providers[.codex], .success(discoveredFiles: 1, scannedFiles: 1))
        await coordinator.stop()
    }

    func testStopUnblocksMultipleQueuedManualRefreshesAndRestartUsesFreshRun() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let firstFile = setup.claudeRoot.appending(path: "first.jsonl")
        let scanner = RecordingScanner(suspendFirstScan: true)
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: FakeSourceEventWatcher(),
            clock: ManualIngestionClock(),
            calendar: calendar
        )
        let initial = try await coordinator.start(roots: setup.roots)
        try Data().write(to: firstFile)

        var refreshes = [Task { await coordinator.refreshAll() }]
        await scanner.waitForScanCount(1)
        for _ in 1..<32 {
            refreshes.append(Task { await coordinator.refreshAll() })
        }
        await waitUntil {
            await coordinator.diagnostics().inventoryWaiterCount == 32
        }
        let stop = Task { await coordinator.stop() }
        await scanner.waitUntilCancelled()
        await scanner.resumeFirstScan()
        await stop.value
        var stoppedResults: [IngestionBatchResult] = []
        for refresh in refreshes { stoppedResults.append(await refresh.value) }

        await scanner.reset()
        let restarted = try await coordinator.start(roots: setup.roots)
        XCTAssertEqual(Set(stoppedResults.map(\.runID)), [initial.runID])
        XCTAssertEqual(Set(stoppedResults.map(\.sequence)), [2])
        XCTAssertNotEqual(restarted.runID, initial.runID)
        XCTAssertEqual(restarted.sequence, 1)
        let restartedDiagnostics = await coordinator.diagnostics()
        XCTAssertEqual(restartedDiagnostics.inventoryWaiterCount, 0)
        XCTAssertEqual(restartedDiagnostics.pendingBatchCount, 0)
        await coordinator.stop()
    }

    func testBoundedEventDeliveryEmitsRecoveryMarkerAfterOverflow() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let watcher = FakeSourceEventWatcher()
        let scanner = RecordingScanner()
        let clock = ManualIngestionClock()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: clock,
            calendar: calendar
        )
        let stream = await coordinator.results()
        let initial = try await coordinator.start(roots: setup.roots)

        for index in 1...2 {
            let changed = setup.claudeRoot.appending(path: "event-\(index).jsonl")
            try Data().write(to: changed)
            watcher.emit([changed])
            await clock.waitForSleepStartCount(index)
            await clock.advancePastDebounce()
            await scanner.waitForCompletedScanCount(index)
        }

        let recovered = await coordinator.refreshAll()
        var iterator = stream.makeAsyncIterator()
        let overflow = await iterator.next()
        XCTAssertEqual(overflow?.runID, initial.runID)
        XCTAssertTrue(overflow?.requiresInventoryRefresh == true)
        XCTAssertEqual(overflow?.providers, [:])
        XCTAssertEqual(recovered.scope, .inventory)
        XCTAssertEqual(recovered.sequence, overflow!.sequence + 1)
        await coordinator.stop()
    }

    func testConcurrentStopsShareOneQuiescenceBarrier() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let changed = setup.claudeRoot.appending(path: "suspended.jsonl")
        let scanner = RecordingScanner(suspendFirstScan: true)
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: FakeSourceEventWatcher(),
            clock: ManualIngestionClock(),
            calendar: calendar
        )
        _ = try await coordinator.start(roots: setup.roots)
        try Data().write(to: changed)
        let refresh = Task { await coordinator.refreshAll() }
        await scanner.waitForScanCount(1)

        let firstStop = Task { await coordinator.stop() }
        await scanner.waitUntilCancelled()
        let secondFinished = TimedAsyncFlag()
        let secondStop = Task {
            await coordinator.stop()
            await secondFinished.set()
        }
        let returnedBeforeQuiescence = await secondFinished.wait(for: .milliseconds(50))
        await scanner.resumeFirstScan()
        await firstStop.value
        await secondStop.value
        _ = await refresh.value

        XCTAssertFalse(returnedBeforeQuiescence)
    }

    func testContinuousChurnDrainsAtMaximumLatencyWithBoundedRootDirtyState() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let watcher = FakeSourceEventWatcher()
        let scanner = RecordingScanner()
        let clock = ManualIngestionClock()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: clock,
            calendar: calendar
        )
        let stream = await coordinator.results()
        let received = Task { () -> IngestionBatchResult? in
            for await result in stream { return result }
            return nil
        }
        _ = try await coordinator.start(roots: setup.roots)

        for index in 0..<80 {
            let root = index.isMultiple(of: 2) ? setup.claudeRoot : setup.codexRoot
            let changed = root.appending(path: "continuous-\(index).jsonl")
            try Data().write(to: changed)
            watcher.emit([changed])
            await clock.waitForSleepStartCount(index + 1)
        }

        let duringChurn = await coordinator.diagnostics()
        XCTAssertTrue(
            duringChurn.pendingEventPathCount
                <= IngestionCoordinator.maximumPendingEventPaths
        )
        XCTAssertTrue(duringChurn.eventPathsCollapsedToRoots)
        let requestedMaximumLatency = await clock.hasRequested(
            IngestionCoordinator.maximumEventLatency
        )
        XCTAssertTrue(requestedMaximumLatency)

        await clock.resumeAll(for: IngestionCoordinator.maximumEventLatency)
        let result = await received.value

        XCTAssertEqual(
            result?.providers[.claudeCode],
            .success(discoveredFiles: 40, scannedFiles: 40)
        )
        XCTAssertEqual(
            result?.providers[.codex],
            .success(discoveredFiles: 40, scannedFiles: 40)
        )
        await coordinator.stop()
    }

    func testBurstsDuringSlowEventScanCollapseToOneProviderDirtyFollowUp() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let watcher = FakeSourceEventWatcher()
        let scanner = RecordingScanner(suspendFirstScan: true)
        let clock = ManualIngestionClock()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: clock,
            calendar: calendar
        )
        let stream = await coordinator.results()
        let received = Task { () -> [IngestionBatchResult] in
            var values: [IngestionBatchResult] = []
            for await result in stream {
                values.append(result)
                if values.count == 2 { return values }
            }
            return values
        }
        _ = try await coordinator.start(roots: setup.roots)
        let initial = setup.claudeRoot.appending(path: "initial.jsonl")
        try Data().write(to: initial)
        watcher.emit([initial])
        await clock.waitForSleepStartCount(1)
        await clock.advancePastDebounce()
        await scanner.waitForScanCount(1)

        for index in 0..<12 {
            let root = index.isMultiple(of: 2) ? setup.claudeRoot : setup.codexRoot
            let changed = root.appending(path: "burst-\(index).jsonl")
            try Data().write(to: changed)
            watcher.emit([changed])
            await clock.waitForSleepStartCount(index + 2)
            await clock.advancePastDebounce()
            await waitUntil {
                let diagnostics = await coordinator.diagnostics()
                return diagnostics.followUpDirtyProviderCount == min(index + 1, 2)
            }
        }

        let whileScanning = await coordinator.diagnostics()
        XCTAssertEqual(whileScanning.followUpDirtyProviderCount, 2)
        XCTAssertEqual(whileScanning.pendingEventBatchCount, 0)
        XCTAssertTrue(whileScanning.pendingBatchCount <= 1)

        await scanner.resumeFirstScan()
        let values = await received.value
        await waitUntil {
            let diagnostics = await coordinator.diagnostics()
            return !diagnostics.isDraining && diagnostics.pendingBatchCount == 0
        }

        let scannedURLs = await scanner.scannedURLs
        let maximumConcurrentScans = await scanner.maximumConcurrentScans
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(
            values[1].providers[.claudeCode],
            .success(discoveredFiles: 7, scannedFiles: 7)
        )
        XCTAssertEqual(
            values[1].providers[.codex],
            .success(discoveredFiles: 6, scannedFiles: 6)
        )
        XCTAssertEqual(scannedURLs.count, 14)
        XCTAssertEqual(maximumConcurrentScans, 1)
        await coordinator.stop()
    }

    func testManyManualRefreshCallersShareOnePassAndAllResumeOnce() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let scanner = RecordingScanner(suspendFirstScan: true)
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: FakeSourceEventWatcher(),
            clock: ManualIngestionClock(),
            calendar: calendar
        )
        _ = try await coordinator.start(roots: setup.roots)
        let changed = setup.claudeRoot.appending(path: "manual.jsonl")
        try Data().write(to: changed)

        var refreshes: [Task<IngestionBatchResult, Never>] = []
        refreshes.append(Task { await coordinator.refreshAll() })
        await scanner.waitForScanCount(1)
        for _ in 1..<50 {
            refreshes.append(Task { await coordinator.refreshAll() })
        }
        await waitUntil {
            await coordinator.diagnostics().inventoryWaiterCount == 50
        }
        let whileSuspended = await coordinator.diagnostics()
        XCTAssertEqual(whileSuspended.pendingInventoryBatchCount, 0)

        await scanner.resumeFirstScan()
        var results: [IngestionBatchResult] = []
        for refresh in refreshes { results.append(await refresh.value) }

        let scannedURLs = await scanner.scannedURLs
        let finished = await coordinator.diagnostics()
        XCTAssertEqual(Set(results.map(\.sequence)), [2])
        XCTAssertEqual(scannedURLs, [changed])
        XCTAssertEqual(finished.inventoryWaiterCount, 0)
        XCTAssertEqual(finished.pendingBatchCount, 0)
        await coordinator.stop()
    }

    func testInventoryDiscoveryUsesBackpressuredChunksWithoutFullMaterialization() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let discovery = ChunkedLogicalDiscovery(counts: [
            "claude": 2_049,
            "codex": 2_048
        ])
        let scanner = ChunkCountingScanner()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: FakeSourceEventWatcher(),
            clock: ManualIngestionClock(),
            discovery: discovery,
            calendar: calendar
        )

        let result = try await coordinator.start(roots: setup.roots)

        let discoverySnapshot = discovery.snapshot()
        let scannerSnapshot = await scanner.snapshot()
        XCTAssertEqual(discoverySnapshot.synchronousArrayCalls, 0)
        XCTAssertEqual(discoverySnapshot.maximumChunkSize, 64)
        XCTAssertEqual(discoverySnapshot.maximumActiveConsumers, 1)
        XCTAssertEqual(discoverySnapshot.generatedFiles, 4_097)
        XCTAssertEqual(scannerSnapshot.scansByProvider[.claudeCode], 2_049)
        XCTAssertEqual(scannerSnapshot.scansByProvider[.codex], 2_048)
        XCTAssertEqual(scannerSnapshot.maximumActiveScans, 1)
        XCTAssertEqual(
            result.providers[.claudeCode],
            .success(discoveredFiles: 2_049, scannedFiles: 2_049)
        )
        XCTAssertEqual(
            result.providers[.codex],
            .success(discoveredFiles: 2_048, scannedFiles: 2_048)
        )
        await coordinator.stop()
    }

    func testStopCancelsAndAwaitsGatedDiscoveryBeforeSettlingCoalescedCallers() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let watcher = FakeSourceEventWatcher()
        let clock = ManualIngestionClock()
        let discovery = ChunkedLogicalDiscovery(counts: [:])
        let scanner = ChunkCountingScanner()
        let gate = CancellableDiscoveryGate()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: clock,
            discovery: discovery,
            calendar: calendar
        )
        let initial = try await coordinator.start(roots: setup.roots)
        discovery.configure(
            counts: ["claude": 10_000, "codex": 10_000],
            gate: gate
        )
        discovery.resetMetrics()
        await scanner.reset()
        let recorder = IngestionResultRecorder()
        let consumerFinished = TimedAsyncFlag()
        let stream = await coordinator.results()
        let consumer = Task {
            for await result in stream { await recorder.append(result) }
            await consumerFinished.set()
        }
        defer {
            consumer.cancel()
            Task {
                await gate.release()
                await clock.resumeAll(for: .milliseconds(750))
                await clock.resumeAll(for: IngestionCoordinator.maximumEventLatency)
                await coordinator.stop()
            }
        }
        watcher.emit([setup.claudeRoot, setup.codexRoot])
        try await requireEventually("root event debounce was not acknowledged") {
            await clock.hasStartedSleep(count: 1, duration: .milliseconds(750))
        }
        await clock.advancePastDebounce()
        try await requireEventually("gated discovery did not start") {
            await gate.hasEntered
        }
        var refreshes: [Task<IngestionBatchResult, Never>] = []
        defer { refreshes.forEach { $0.cancel() } }
        for _ in 0..<32 {
            refreshes.append(Task { await coordinator.refreshAll() })
        }
        try await requireEventually("manual refresh callers did not coalesce") {
            await coordinator.diagnostics().inventoryWaiterCount == 32
        }
        let stopFinished = TimedAsyncFlag()
        let stop = Task {
            await coordinator.stop()
            await stopFinished.set()
        }
        let stoppedBeforeRelease = await stopFinished.wait(for: .milliseconds(200))
        if !stoppedBeforeRelease { await gate.release() }
        try await requireEventually("stop did not settle after gate cancellation") {
            await stopFinished.isSet
        }
        await stop.value
        var stoppedResults: [IngestionBatchResult] = []
        for refresh in refreshes { stoppedResults.append(await refresh.value) }

        let stoppedDiscovery = discovery.snapshot()
        let stoppedScans = await scanner.snapshot()
        let discoveryWasCancelled = await gate.wasCancelled
        let stoppedStreamValues = await recorder.snapshot()

        discovery.configure(counts: [:], gate: nil)
        discovery.resetMetrics()
        let restarted = try await startCoordinator(coordinator, roots: setup.roots)
        let later = setup.codexRoot.appending(path: "later.jsonl")
        try Data().write(to: later)
        watcher.emit([later])
        try await requireEventually("restart event debounce was not acknowledged") {
            await clock.hasStartedSleep(count: 2, duration: .milliseconds(750))
        }
        await clock.advancePastDebounce()
        try await requireEventually("restart event result did not arrive") {
            await recorder.count == 1
        }
        try await requireEventually("restart event work did not become quiescent") {
            let diagnostics = await coordinator.diagnostics()
            return !diagnostics.isDraining && diagnostics.pendingBatchCount == 0
        }
        let values = await recorder.snapshot()
        consumer.cancel()
        try await requireEventually("result consumer did not stop") {
            await consumerFinished.isSet
        }
        _ = await consumer.value
        try await stopCoordinator(coordinator)

        XCTAssertTrue(stoppedBeforeRelease)
        XCTAssertTrue(discoveryWasCancelled)
        XCTAssertEqual(stoppedStreamValues, [])
        XCTAssertEqual(stoppedDiscovery.synchronousArrayCalls, 0)
        XCTAssertEqual(stoppedDiscovery.generatedFiles, 0)
        XCTAssertEqual(stoppedScans.totalScans, 0)
        XCTAssertEqual(Set(stoppedResults.map(\.runID)), [initial.runID])
        XCTAssertEqual(Set(stoppedResults.map(\.sequence)), [3])
        XCTAssertNotEqual(restarted.runID, initial.runID)
        XCTAssertEqual(restarted.sequence, 1)
        XCTAssertEqual(values.count, 1)
        guard let laterResult = values.first else { return }
        XCTAssertEqual(laterResult.runID, restarted.runID)
        XCTAssertEqual(laterResult.sequence, 2)
        XCTAssertEqual(
            laterResult.providers[.codex],
            .success(discoveredFiles: 1, scannedFiles: 1)
        )
    }

    func testStopBeforeScheduledDrainEntryPreventsWorkerCreationAndSettlesWaitersOnce() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let watcher = FakeSourceEventWatcher()
        let clock = ManualIngestionClock()
        let discovery = ChunkedLogicalDiscovery(counts: [:])
        let scanner = ChunkCountingScanner()
        let drainEntry = CancellableDrainEntryGate()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: clock,
            discovery: discovery,
            calendar: calendar,
            drainEntryHook: { await drainEntry.wait() }
        )
        let stream = await coordinator.results()
        let recorder = IngestionResultRecorder()
        let consumerFinished = TimedAsyncFlag()
        let consumer = Task {
            for await result in stream { await recorder.append(result) }
            await consumerFinished.set()
        }
        let startRecorder = IngestionStartRecorder()
        let start = Task {
            do {
                await startRecorder.succeed(
                    try await coordinator.start(roots: setup.roots)
                )
            } catch is CancellationError {
                await startRecorder.cancel()
            } catch {
                await startRecorder.fail()
            }
        }
        defer {
            consumer.cancel()
            start.cancel()
            Task {
                await drainEntry.release()
                await clock.resumeAll(for: .milliseconds(750))
                await clock.resumeAll(for: IngestionCoordinator.maximumEventLatency)
                await coordinator.stop()
            }
        }
        try await requireEventually("scheduled drain did not reach its entry gate") {
            await drainEntry.hasEntered
        }
        var refreshes: [Task<IngestionBatchResult, Never>] = []
        defer { refreshes.forEach { $0.cancel() } }
        for _ in 0..<16 {
            refreshes.append(Task { await coordinator.refreshAll() })
        }
        try await requireEventually("manual refresh callers did not coalesce") {
            await coordinator.diagnostics().inventoryWaiterCount == 17
        }

        try await stopCoordinator(coordinator)
        await drainEntry.release()
        try await requireEventually("stopped start did not settle") {
            await startRecorder.hasCompleted
        }
        _ = await start.value
        var stoppedResults: [IngestionBatchResult] = []
        for refresh in refreshes { stoppedResults.append(await refresh.value) }

        let stoppedDiscovery = discovery.snapshot()
        let stoppedScans = await scanner.snapshot()
        let drainWasCancelled = await drainEntry.wasCancelled
        let stoppedDiagnostics = await coordinator.diagnostics()

        discovery.resetMetrics()
        await scanner.reset()
        let restarted = try await startCoordinator(coordinator, roots: setup.roots)
        let later = setup.codexRoot.appending(path: "later-after-entry-stop.jsonl")
        try Data().write(to: later)
        watcher.emit([later])
        try await requireEventually("restart event debounce was not acknowledged") {
            await clock.hasStartedSleep(count: 1, duration: .milliseconds(750))
        }
        await clock.advancePastDebounce()
        try await requireEventually("restart event result did not arrive") {
            await recorder.count == 1
        }
        try await requireEventually("restart event work did not become quiescent") {
            let diagnostics = await coordinator.diagnostics()
            return !diagnostics.isDraining && diagnostics.pendingBatchCount == 0
        }
        let values = await recorder.snapshot()
        consumer.cancel()
        try await requireEventually("result consumer did not stop") {
            await consumerFinished.isSet
        }
        _ = await consumer.value
        try await stopCoordinator(coordinator)

        let startWasCancelled = await startRecorder.wasCancelled
        XCTAssertTrue(drainWasCancelled)
        XCTAssertEqual(stoppedDiscovery.enumerationCalls, 0)
        XCTAssertEqual(stoppedDiscovery.generatedFiles, 0)
        XCTAssertEqual(stoppedScans.totalScans, 0)
        XCTAssertEqual(stoppedResults.count, 16)
        XCTAssertEqual(Set(stoppedResults.map(\.runID)).count, 1)
        XCTAssertEqual(Set(stoppedResults.map(\.sequence)), [1])
        XCTAssertEqual(stoppedDiagnostics.inventoryWaiterCount, 0)
        XCTAssertEqual(stoppedDiagnostics.pendingBatchCount, 0)
        XCTAssertTrue(startWasCancelled)
        XCTAssertFalse(stoppedResults.isEmpty)
        let stoppedRunIDs = Set(stoppedResults.map(\.runID))
        XCTAssertFalse(stoppedRunIDs.contains(restarted.runID))
        XCTAssertEqual(values.count, 1)
        guard let laterResult = values.first else { return }
        XCTAssertEqual(laterResult.runID, restarted.runID)
        XCTAssertEqual(laterResult.sequence, 2)
        XCTAssertEqual(
            laterResult.providers[.codex],
            ProviderIngestionResult.success(discoveredFiles: 1, scannedFiles: 1)
        )
    }

    func testEventsDuringChunkedRootDiscoveryCollapseToOneTwoProviderFollowUp() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let watcher = FakeSourceEventWatcher()
        let clock = ManualIngestionClock()
        let discovery = ChunkedLogicalDiscovery(counts: [:])
        let scanner = ChunkCountingScanner()
        let gate = CancellableDiscoveryGate()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: clock,
            discovery: discovery,
            calendar: calendar
        )
        _ = try await coordinator.start(roots: setup.roots)
        discovery.configure(
            counts: ["claude": 130, "codex": 129],
            gate: gate
        )
        discovery.resetMetrics()
        await scanner.reset()
        let stream = await coordinator.results()
        let recorder = IngestionResultRecorder()
        let consumerFinished = TimedAsyncFlag()
        let consumer = Task {
            for await result in stream { await recorder.append(result) }
            await consumerFinished.set()
        }
        defer {
            consumer.cancel()
            Task {
                await gate.release()
                await clock.resumeAll(for: .milliseconds(750))
                await clock.resumeAll(for: IngestionCoordinator.maximumEventLatency)
                await coordinator.stop()
            }
        }

        watcher.emit([setup.claudeRoot, setup.codexRoot])
        try await requireEventually("root event debounce was not acknowledged") {
            await clock.hasStartedSleep(count: 1, duration: .milliseconds(750))
        }
        await clock.advancePastDebounce()
        try await requireEventually("root discovery did not reach its gate") {
            await gate.hasEntered
        }
        for index in 0..<12 {
            let root = index.isMultiple(of: 2) ? setup.claudeRoot : setup.codexRoot
            watcher.emit([root.appending(path: "burst-\(index).jsonl")])
            try await requireEventually("burst debounce was not acknowledged") {
                await clock.hasStartedSleep(
                    count: index + 2,
                    duration: .milliseconds(750)
                )
            }
            await clock.advancePastDebounce()
        }
        let duringDiscovery = await coordinator.diagnostics()

        await gate.release()
        try await requireEventually("two event results did not arrive") {
            await recorder.count >= 2
        }
        try await requireEventually("root follow-up work did not become quiescent") {
            let diagnostics = await coordinator.diagnostics()
            return !diagnostics.isDraining && diagnostics.pendingBatchCount == 0
        }
        await clock.resumeAll(for: .milliseconds(750))
        await clock.resumeAll(for: IngestionCoordinator.maximumEventLatency)
        let values = await recorder.snapshot()
        let discoverySnapshot = discovery.snapshot()
        let scannerSnapshot = await scanner.snapshot()
        consumer.cancel()
        try await requireEventually("result consumer did not stop") {
            await consumerFinished.isSet
        }
        _ = await consumer.value
        try await stopCoordinator(coordinator)

        XCTAssertEqual(duringDiscovery.followUpDirtyProviderCount, 2)
        XCTAssertEqual(duringDiscovery.pendingEventBatchCount, 0)
        XCTAssertEqual(values.count, 2)
        guard values.count == 2 else { return }
        for value in values {
            XCTAssertEqual(
                value.providers[.claudeCode],
                .success(discoveredFiles: 130, scannedFiles: 130)
            )
            XCTAssertEqual(
                value.providers[.codex],
                .success(discoveredFiles: 129, scannedFiles: 129)
            )
        }
        XCTAssertEqual(discoverySnapshot.enumerationCalls, 4)
        XCTAssertEqual(discoverySnapshot.synchronousArrayCalls, 0)
        XCTAssertEqual(discoverySnapshot.maximumChunkSize, 64)
        XCTAssertEqual(discoverySnapshot.maximumActiveConsumers, 1)
        XCTAssertEqual(discoverySnapshot.generatedFiles, 518)
        XCTAssertEqual(scannerSnapshot.totalScans, 518)
        XCTAssertEqual(scannerSnapshot.maximumActiveScans, 1)
    }

    func testEventsDuringActiveInventoryCollapseToExactlyOneRootFollowUp() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let watcher = FakeSourceEventWatcher()
        let clock = ManualIngestionClock()
        let gate = CancellableDiscoveryGate()
        let discovery = ChunkedLogicalDiscovery(counts: [
            "claude": 65,
            "codex": 66
        ])
        discovery.configure(
            counts: ["claude": 65, "codex": 66],
            gate: gate
        )
        let scanner = ChunkCountingScanner()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: clock,
            discovery: discovery,
            calendar: calendar
        )
        let stream = await coordinator.results()
        let recorder = IngestionResultRecorder()
        let consumerFinished = TimedAsyncFlag()
        let consumer = Task {
            for await result in stream { await recorder.append(result) }
            await consumerFinished.set()
        }
        let startRecorder = IngestionStartRecorder()
        let start = Task {
            do {
                await startRecorder.succeed(
                    try await coordinator.start(roots: setup.roots)
                )
            } catch is CancellationError {
                await startRecorder.cancel()
            } catch {
                await startRecorder.fail()
            }
        }
        defer {
            consumer.cancel()
            start.cancel()
            Task {
                await gate.release()
                await clock.resumeAll(for: .milliseconds(750))
                await clock.resumeAll(for: IngestionCoordinator.maximumEventLatency)
                await coordinator.stop()
            }
        }
        try await requireEventually("inventory discovery did not reach its gate") {
            await gate.hasEntered
        }
        let early = setup.claudeRoot.appending(path: "early.jsonl")
        try Data().write(to: early)
        watcher.emit([early])
        try await requireEventually("early event debounce was not acknowledged") {
            await clock.hasStartedSleep(count: 1, duration: .milliseconds(750))
        }
        await clock.advancePastDebounce()
        for index in 0..<3 {
            let root = index.isMultiple(of: 2) ? setup.codexRoot : setup.claudeRoot
            watcher.emit([root.appending(path: "later-\(index).jsonl")])
            try await requireEventually("later event debounce was not acknowledged") {
                await clock.hasStartedSleep(
                    count: index + 2,
                    duration: .milliseconds(750)
                )
            }
            await clock.advancePastDebounce()
        }
        watcher.emit([setup.claudeRoot, setup.codexRoot])
        try await requireEventually("root fallback debounce was not acknowledged") {
            await clock.hasStartedSleep(count: 5, duration: .milliseconds(750))
        }
        await clock.advancePastDebounce()

        try await requireEventually("root fallback did not mark both providers dirty") {
            let diagnostics = await coordinator.diagnostics()
            return diagnostics.followUpDirtyProviderCount == 2
        }
        let whileInventoryIsGated = await coordinator.diagnostics()

        await gate.release()
        try await requireEventually("startup inventory did not settle") {
            await startRecorder.hasCompleted
        }
        guard let initial = await startRecorder.success else {
            throw AsyncTestTimeout.failed("startup inventory failed")
        }
        _ = await start.value
        try await requireEventually("inventory follow-up did not become quiescent") {
            let diagnostics = await coordinator.diagnostics()
            return !diagnostics.isDraining
                && diagnostics.pendingBatchCount == 0
                && diagnostics.pendingEventPathCount == 0
                && diagnostics.followUpDirtyProviderCount == 0
        }
        try await requireEventually("inventory follow-up result did not arrive") {
            await recorder.count == 1
        }
        await clock.resumeAll(for: .milliseconds(750))
        await clock.resumeAll(for: IngestionCoordinator.maximumEventLatency)
        try await requireEventually("event timers did not settle") {
            await clock.waiterCount == 0
        }
        let values = await recorder.snapshot()
        consumer.cancel()
        try await requireEventually("result consumer did not stop") {
            await consumerFinished.isSet
        }
        _ = await consumer.value

        let discoverySnapshot = discovery.snapshot()
        let scannerSnapshot = await scanner.snapshot()
        try await stopCoordinator(coordinator)

        XCTAssertEqual(whileInventoryIsGated.pendingEventBatchCount, 0)
        XCTAssertEqual(whileInventoryIsGated.followUpDirtyProviderCount, 2)
        XCTAssertTrue(whileInventoryIsGated.pendingBatchCount <= 1)
        XCTAssertEqual(values.count, 1)
        guard values.count == 1 else { return }
        XCTAssertEqual(values[0].runID, initial.runID)
        XCTAssertEqual(values[0].sequence, initial.sequence + 1)
        XCTAssertEqual(values[0].scope, .incremental)
        XCTAssertEqual(
            values[0].providers[.claudeCode],
            .success(discoveredFiles: 65, scannedFiles: 65)
        )
        XCTAssertEqual(
            values[0].providers[.codex],
            .success(discoveredFiles: 66, scannedFiles: 66)
        )
        XCTAssertEqual(discoverySnapshot.enumerationCalls, 4)
        XCTAssertEqual(discoverySnapshot.maximumChunkSize, 64)
        XCTAssertEqual(discoverySnapshot.maximumActiveConsumers, 1)
        XCTAssertEqual(discoverySnapshot.generatedFiles, 262)
        XCTAssertEqual(scannerSnapshot.scansByProvider[.claudeCode], 130)
        XCTAssertEqual(scannerSnapshot.scansByProvider[.codex], 132)
        XCTAssertEqual(scannerSnapshot.totalScans, 262)
        XCTAssertEqual(scannerSnapshot.maximumActiveScans, 1)
    }

    func testBatchCompletionAbsorbsHeldDebounceIntoUnionFollowUpWithoutSwallowingLaterEvent() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let watcher = FakeSourceEventWatcher()
        let clock = ManualIngestionClock()
        let gate = CallIndexedDiscoveryGate(blockedCalls: [1, 3])
        let discovery = ChunkedLogicalDiscovery(
            counts: ["claude": 65, "codex": 66],
            indexedGate: gate
        )
        let scanner = ChunkCountingScanner()
        let timerCompletions = SynchronousCountRecorder()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: clock,
            discovery: discovery,
            calendar: calendar,
            drainEntryHook: nil,
            eventTimerCompletionHook: { timerCompletions.record() }
        )
        let stream = await coordinator.results()
        let recorder = IngestionResultRecorder()
        let consumerFinished = TimedAsyncFlag()
        let consumer = Task {
            for await result in stream { await recorder.append(result) }
            await consumerFinished.set()
        }
        let startRecorder = IngestionStartRecorder()
        let start = Task {
            do {
                await startRecorder.succeed(
                    try await coordinator.start(roots: setup.roots)
                )
            } catch is CancellationError {
                await startRecorder.cancel()
            } catch {
                await startRecorder.fail()
            }
        }
        defer {
            consumer.cancel()
            start.cancel()
            Task {
                await gate.releaseAll()
                await clock.resumeAll(for: .milliseconds(750))
                await clock.resumeAll(for: IngestionCoordinator.maximumEventLatency)
                await coordinator.stop()
            }
        }

        try await requireEventually("inventory discovery did not enter call 1") {
            await gate.hasEntered(call: 1)
        }
        watcher.emit([setup.claudeRoot])
        try await requireEventually("event A debounce was not acknowledged") {
            await clock.hasStartedSleep(count: 1, duration: .milliseconds(750))
        }
        await clock.advancePastDebounce()
        try await requireEventually("event A did not enter dirty state") {
            await coordinator.diagnostics().followUpDirtyProviderCount == 1
        }

        watcher.emit([setup.codexRoot])
        try await requireEventually("event B debounce was not acknowledged") {
            await clock.hasStartedSleep(count: 2, duration: .milliseconds(750))
        }
        let beforeInventoryRelease = await coordinator.diagnostics()
        await gate.release(call: 1)
        try await requireEventually("first follow-up did not enter discovery call 3") {
            await gate.hasEntered(call: 3)
        }
        let atAtomicHandoff = await coordinator.diagnostics()

        await clock.advancePastDebounce()
        try await requireEventually("event B timer did not finish") {
            timerCompletions.count >= 4
        }
        let afterOldDebounceRelease = await coordinator.diagnostics()

        watcher.emit([setup.claudeRoot])
        try await requireEventually("event C debounce was not acknowledged") {
            await clock.hasStartedSleep(count: 3, duration: .milliseconds(750))
        }
        await clock.advancePastDebounce()
        try await requireEventually("event C did not become the sole next dirty provider") {
            await coordinator.diagnostics().followUpDirtyProviderCount >= 1
        }
        await gate.release(call: 3)

        try await requireEventually("startup inventory did not settle") {
            await startRecorder.hasCompleted
        }
        guard let initial = await startRecorder.success else {
            throw AsyncTestTimeout.failed("startup inventory failed")
        }
        try await requireEventually("two legitimate follow-up results did not arrive") {
            await recorder.count >= 2
        }
        try await requireEventually("coordinator did not become quiescent") {
            let diagnostics = await coordinator.diagnostics()
            return !diagnostics.isDraining
                && diagnostics.pendingBatchCount == 0
                && diagnostics.pendingEventPathCount == 0
                && diagnostics.followUpDirtyProviderCount == 0
        }
        await clock.resumeAll(for: .milliseconds(750))
        await clock.resumeAll(for: IngestionCoordinator.maximumEventLatency)
        try await requireEventually("event timer tasks did not all settle") {
            timerCompletions.count >= 6
        }
        try await ContinuousClock().sleep(for: .milliseconds(50))
        let finalDiagnostics = await coordinator.diagnostics()
        let values = await recorder.snapshot()
        let discoverySnapshot = discovery.snapshot()
        let scannerSnapshot = await scanner.snapshot()

        consumer.cancel()
        try await requireEventually("result consumer did not stop") {
            await consumerFinished.wait(for: .zero)
        }
        _ = await consumer.value
        await coordinator.stop()
        await gate.releaseAll()
        _ = await start.value

        XCTAssertEqual(beforeInventoryRelease.pendingEventPathCount, 1)
        XCTAssertEqual(atAtomicHandoff.pendingEventPathCount, 0)
        XCTAssertEqual(atAtomicHandoff.followUpDirtyProviderCount, 0)
        XCTAssertTrue(atAtomicHandoff.pendingEventBatchCount <= 1)
        XCTAssertEqual(afterOldDebounceRelease.pendingEventPathCount, 0)
        XCTAssertEqual(afterOldDebounceRelease.followUpDirtyProviderCount, 0)
        XCTAssertEqual(finalDiagnostics.pendingBatchCount, 0)
        XCTAssertEqual(finalDiagnostics.followUpDirtyProviderCount, 0)
        XCTAssertEqual(values.count, 2)
        guard values.count == 2 else { return }
        XCTAssertEqual(values[0].runID, initial.runID)
        XCTAssertEqual(values[0].sequence, initial.sequence + 1)
        XCTAssertEqual(values[0].scope, .incremental)
        XCTAssertEqual(
            values[0].providers[.claudeCode],
            .success(discoveredFiles: 65, scannedFiles: 65)
        )
        XCTAssertEqual(
            values[0].providers[.codex],
            .success(discoveredFiles: 66, scannedFiles: 66)
        )
        XCTAssertEqual(values[1].sequence, values[0].sequence + 1)
        XCTAssertEqual(values[1].scope, .incremental)
        XCTAssertEqual(
            values[1].providers,
            [.claudeCode: .success(discoveredFiles: 65, scannedFiles: 65)]
        )
        XCTAssertEqual(
            discoverySnapshot.rootNames,
            ["claude", "codex", "claude", "codex", "claude"]
        )
        XCTAssertEqual(discoverySnapshot.maximumChunkSize, 64)
        XCTAssertEqual(discoverySnapshot.maximumActiveConsumers, 1)
        XCTAssertEqual(discoverySnapshot.generatedFiles, 327)
        XCTAssertEqual(scannerSnapshot.scansByProvider[.claudeCode], 195)
        XCTAssertEqual(scannerSnapshot.scansByProvider[.codex], 132)
        XCTAssertEqual(scannerSnapshot.totalScans, 327)
        XCTAssertEqual(scannerSnapshot.maximumActiveScans, 1)
    }

    func testEventDuringScanSchedulesOneFollowUpPassWithoutOverlap() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let first = setup.claudeRoot.appending(path: "first.jsonl")
        let followUp = setup.claudeRoot.appending(path: "follow-up.jsonl")
        try Data().write(to: first)
        let watcher = FakeSourceEventWatcher()
        let scanner = RecordingScanner(suspendFirstScan: true)
        let clock = ManualIngestionClock()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: clock,
            calendar: calendar
        )

        let startTask = Task { try await coordinator.start(roots: setup.roots) }
        await waitUntil { await scanner.activeScans == 1 }
        try Data().write(to: followUp)
        watcher.emit([followUp])
        await clock.waitForSleepStartCount(1)
        await clock.advancePastDebounce()
        await scanner.resumeFirstScan()
        _ = try await startTask.value
        await waitUntil { await scanner.scannedURLs.count == 3 }

        let scannedURLs = await scanner.scannedURLs
        let maximumConcurrentScans = await scanner.maximumConcurrentScans
        XCTAssertEqual(scannedURLs, [first, first, followUp])
        XCTAssertEqual(maximumConcurrentScans, 1)
        await coordinator.stop()
    }

    func testIdenticalRootsAreRejectedBeforeWatcherOrScannerStarts() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await assertAmbiguousRootsRejected(
            [.claudeCode: directory, .codex: directory]
        )
    }

    func testClaudeParentAndCodexChildAreRejectedBeforeWatcherOrScannerStarts() async throws {
        let parent = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let child = parent.appending(path: "nested")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        try await assertAmbiguousRootsRejected(
            [.claudeCode: parent, .codex: child]
        )
    }

    func testCodexParentAndClaudeChildAreRejectedBeforeWatcherOrScannerStarts() async throws {
        let parent = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let child = parent.appending(path: "nested")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        try await assertAmbiguousRootsRejected(
            [.claudeCode: child, .codex: parent]
        )
    }

    func testNonOverlappingRootsStartAndAssignProvidersFromContainingRoot() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let claudeFile = setup.claudeRoot.appending(path: "claude.jsonl")
        let codexFile = setup.codexRoot.appending(path: "codex.jsonl")
        try Data().write(to: claudeFile)
        try Data().write(to: codexFile)
        let watcher = FakeSourceEventWatcher()
        let scanner = RecordingScanner()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: ManualIngestionClock(),
            calendar: calendar
        )

        _ = try await coordinator.start(roots: setup.roots)

        let scannedURLs = await scanner.scannedURLs
        let scannedProviders = await scanner.scannedProviders
        XCTAssertEqual(watcher.eventsRequestCount, 1)
        XCTAssertEqual(scannedURLs, [claudeFile, codexFile])
        XCTAssertEqual(scannedProviders, [.claudeCode, .codex])
        await coordinator.stop()
    }

    private func makeSetup() throws -> (
        directory: URL,
        claudeRoot: URL,
        codexRoot: URL,
        roots: [Provider: URL]
    ) {
        let directory = canonicalTestTemporaryDirectory.appending(path: UUID().uuidString)
        let claudeRoot = directory.appending(path: "claude")
        let codexRoot = directory.appending(path: "codex")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        return (
            directory,
            claudeRoot,
            codexRoot,
            [.claudeCode: claudeRoot, .codex: codexRoot]
        )
    }

    private func makeDirectory() throws -> URL {
        let directory = canonicalTestTemporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func assertAmbiguousRootsRejected(_ roots: [Provider: URL]) async throws {
        let watcher = FakeSourceEventWatcher()
        let scanner = RecordingScanner()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: ManualIngestionClock(),
            calendar: calendar
        )
        do {
            _ = try await coordinator.start(roots: roots)
            XCTFail("expected ambiguous source roots to be rejected")
        } catch let error as IngestionCoordinatorError {
            XCTAssertEqual(error, .overlappingRoots)
        }
        let scannedURLs = await scanner.scannedURLs
        XCTAssertEqual(watcher.eventsRequestCount, 0)
        XCTAssertEqual(scannedURLs, [])
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if await condition() { return }
            try? await clock.sleep(for: .milliseconds(1))
        }
        XCTFail("condition was not met", file: file, line: line)
    }

    private func requireEventually(
        _ message: String,
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try? await clock.sleep(for: .milliseconds(1))
        }
        throw AsyncTestTimeout.failed(message)
    }

    private func startCoordinator(
        _ coordinator: IngestionCoordinator,
        roots: [Provider: URL]
    ) async throws -> IngestionBatchResult {
        let recorder = IngestionStartRecorder()
        let task = Task {
            do {
                await recorder.succeed(try await coordinator.start(roots: roots))
            } catch is CancellationError {
                await recorder.cancel()
            } catch {
                await recorder.fail()
            }
        }
        defer { task.cancel() }
        try await requireEventually("coordinator start timed out") {
            await recorder.hasCompleted
        }
        guard let result = await recorder.success else {
            throw AsyncTestTimeout.failed("coordinator start failed")
        }
        _ = await task.value
        return result
    }

    private func stopCoordinator(_ coordinator: IngestionCoordinator) async throws {
        let finished = TimedAsyncFlag()
        let task = Task {
            await coordinator.stop()
            await finished.set()
        }
        defer { task.cancel() }
        try await requireEventually("coordinator stop timed out") {
            await finished.isSet
        }
        _ = await task.value
    }
}

private enum AsyncTestTimeout: Error {
    case failed(String)
}

private actor TimedAsyncFlag {
    private var current = false

    var isSet: Bool { current }

    func set() { current = true }

    func wait(for duration: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while clock.now < deadline {
            if current { return true }
            try? await clock.sleep(for: .milliseconds(1))
        }
        return current
    }
}

private actor IngestionResultRecorder {
    private var values: [IngestionBatchResult] = []

    var count: Int { values.count }

    func append(_ value: IngestionBatchResult) {
        values.append(value)
    }

    func snapshot() -> [IngestionBatchResult] {
        values
    }
}

private actor IngestionStartRecorder {
    private(set) var success: IngestionBatchResult?
    private(set) var hasCompleted = false
    private(set) var wasCancelled = false

    func succeed(_ result: IngestionBatchResult) {
        success = result
        hasCompleted = true
    }

    func cancel() {
        wasCancelled = true
        hasCompleted = true
    }

    func fail() {
        hasCompleted = true
    }
}

private final class SynchronousCountRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func record() {
        lock.withLock { value += 1 }
    }
}

private final class FakeSourceEventWatcher: SourceEventWatching, @unchecked Sendable {
    enum StartError: Error, Equatable {
        case injected
    }

    private let lock = NSLock()
    private let startError: StartError?
    private var continuation: AsyncStream<SourceEventBatch>.Continuation?
    private(set) var requestedRoots: [URL] = []
    private(set) var eventsRequestCount = 0
    private var pathsToEmitOnStop: Set<URL> = []
    private var nextEventID: UInt64 = 0
    private var recordedAcknowledgements: [SourceEventCheckpoint] = []

    init(startError: StartError? = nil) {
        self.startError = startError
    }

    var acknowledgements: [SourceEventCheckpoint] {
        lock.withLock { recordedAcknowledgements }
    }

    var isActive: Bool { lock.withLock { continuation != nil } }

    func start(roots: [URL]) throws -> AsyncStream<SourceEventBatch> {
        lock.withLock {
            requestedRoots = roots
            eventsRequestCount += 1
        }
        if let startError { throw startError }
        return AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func emit(_ paths: Set<URL>) {
        let delivery = lock.withLock { () -> (AsyncStream<SourceEventBatch>.Continuation?, SourceEventBatch) in
            nextEventID &+= 1
            return (
                continuation,
                SourceEventBatch(
                    paths: paths,
                    checkpoint: SourceEventCheckpoint(eventID: nextEventID)
                )
            )
        }
        delivery.0?.yield(delivery.1)
    }

    func emit(_ batch: SourceEventBatch) {
        lock.withLock { continuation }?.yield(batch)
    }

    func emitOnNextStop(_ paths: Set<URL>) {
        lock.withLock { pathsToEmitOnStop = paths }
    }

    func acknowledge(_ checkpoint: SourceEventCheckpoint?) {
        guard let checkpoint else { return }
        lock.withLock { recordedAcknowledgements.append(checkpoint) }
    }

    func stop() {
        let (continuation, batch) = lock.withLock { () -> (AsyncStream<SourceEventBatch>.Continuation?, SourceEventBatch?) in
            defer { self.continuation = nil }
            defer { pathsToEmitOnStop.removeAll() }
            guard !pathsToEmitOnStop.isEmpty else { return (self.continuation, nil) }
            nextEventID &+= 1
            return (
                self.continuation,
                SourceEventBatch(
                    paths: pathsToEmitOnStop,
                    checkpoint: SourceEventCheckpoint(eventID: nextEventID)
                )
            )
        }
        if let batch { continuation?.yield(batch) }
        continuation?.finish()
    }
}

private enum RecordingScannerError: Error {
    case injected
}

private actor RecordingScanner: IngestionScanning {
    private(set) var scannedURLs: [URL] = []
    private(set) var scannedProviders: [Provider] = []
    private(set) var activeScans = 0
    private(set) var maximumConcurrentScans = 0
    private var shouldSuspendFirstScan: Bool
    private var firstScanContinuation: CheckedContinuation<Void, Never>?
    private var scanCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var completedScanCount = 0
    private var completedScanWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var wasCancelled = false
    private let outcomes: [Provider: ScanOutcome]
    private let failingProviders: Set<Provider>

    init(
        suspendFirstScan: Bool = false,
        outcomes: [Provider: ScanOutcome] = [:],
        failingProviders: Set<Provider> = []
    ) {
        shouldSuspendFirstScan = suspendFirstScan
        self.outcomes = outcomes
        self.failingProviders = failingProviders
    }

    func scan(file: URL, provider: Provider, calendar: Calendar) async throws -> ScanOutcome {
        activeScans += 1
        maximumConcurrentScans = max(maximumConcurrentScans, activeScans)
        scannedURLs.append(file)
        scannedProviders.append(provider)
        resumeScanCountWaiters()
        if shouldSuspendFirstScan {
            shouldSuspendFirstScan = false
            await withTaskCancellationHandler {
                await withCheckedContinuation { firstScanContinuation = $0 }
            } onCancel: {
                Task { await self.recordCancellation() }
            }
        }
        activeScans -= 1
        completedScanCount += 1
        resumeCompletedScanWaiters()
        if failingProviders.contains(provider) { throw RecordingScannerError.injected }
        return outcomes[provider] ?? ScanOutcome(
            committedUsageRecords: 0,
            skippedRecords: 0,
            finalOffset: 0,
            attention: nil
        )
    }

    func resumeFirstScan() {
        firstScanContinuation?.resume()
        firstScanContinuation = nil
    }

    func waitForScanCount(_ count: Int) async {
        guard scannedURLs.count < count else { return }
        await withCheckedContinuation { scanCountWaiters.append((count, $0)) }
    }

    func waitUntilCancelled() async {
        guard !wasCancelled else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func waitForCompletedScanCount(_ count: Int) async {
        guard completedScanCount < count else { return }
        await withCheckedContinuation { completedScanWaiters.append((count, $0)) }
    }

    private func recordCancellation() {
        wasCancelled = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func resumeScanCountWaiters() {
        let ready = scanCountWaiters.filter { scannedURLs.count >= $0.0 }
        scanCountWaiters.removeAll { scannedURLs.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    private func resumeCompletedScanWaiters() {
        let ready = completedScanWaiters.filter { completedScanCount >= $0.0 }
        completedScanWaiters.removeAll { completedScanCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func reset() {
        scannedURLs = []
        scannedProviders = []
        activeScans = 0
        maximumConcurrentScans = 0
        completedScanCount = 0
        wasCancelled = false
    }
}

private actor ChunkCountingScanner: IngestionScanning {
    private var scansByProvider: [Provider: Int] = [:]
    private var activeScans = 0
    private var maximumActiveScans = 0

    func scan(file: URL, provider: Provider, calendar: Calendar) async throws -> ScanOutcome {
        activeScans += 1
        maximumActiveScans = max(maximumActiveScans, activeScans)
        scansByProvider[provider, default: 0] += 1
        await Task.yield()
        activeScans -= 1
        return ScanOutcome(
            committedUsageRecords: 0,
            skippedRecords: 0,
            finalOffset: 0,
            attention: nil
        )
    }

    func reset() {
        scansByProvider.removeAll()
        activeScans = 0
        maximumActiveScans = 0
    }

    func snapshot() -> (
        scansByProvider: [Provider: Int],
        totalScans: Int,
        maximumActiveScans: Int
    ) {
        (
            scansByProvider,
            scansByProvider.values.reduce(0, +),
            maximumActiveScans
        )
    }
}

private final class ChunkedLogicalDiscovery: LogDiscovering, @unchecked Sendable {
    struct Snapshot {
        let rootNames: [String]
        let synchronousArrayCalls: Int
        let enumerationCalls: Int
        let generatedFiles: Int
        let maximumChunkSize: Int
        let maximumActiveConsumers: Int
        let cancellationCount: Int
    }

    private let lock = NSLock()
    private let indexedGate: CallIndexedDiscoveryGate?
    private var counts: [String: Int]
    private var gate: CancellableDiscoveryGate?
    private var synchronousArrayCalls = 0
    private var enumerationCalls = 0
    private var generatedFiles = 0
    private var maximumChunkSize = 0
    private var activeConsumers = 0
    private var maximumActiveConsumers = 0
    private var cancellationCount = 0
    private var rootNames: [String] = []

    init(
        counts: [String: Int],
        indexedGate: CallIndexedDiscoveryGate? = nil
    ) {
        self.counts = counts
        self.indexedGate = indexedGate
    }

    func configure(counts: [String: Int], gate: CancellableDiscoveryGate? = nil) {
        lock.withLock {
            self.counts = counts
            self.gate = gate
        }
    }

    func resetMetrics() {
        lock.withLock {
            synchronousArrayCalls = 0
            enumerationCalls = 0
            generatedFiles = 0
            maximumChunkSize = 0
            activeConsumers = 0
            maximumActiveConsumers = 0
            cancellationCount = 0
            rootNames = []
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                rootNames: rootNames,
                synchronousArrayCalls: synchronousArrayCalls,
                enumerationCalls: enumerationCalls,
                generatedFiles: generatedFiles,
                maximumChunkSize: maximumChunkSize,
                maximumActiveConsumers: maximumActiveConsumers,
                cancellationCount: cancellationCount
            )
        }
    }

    func jsonlFiles(under root: URL) throws -> [URL] {
        let count = lock.withLock { () -> Int in
            synchronousArrayCalls += 1
            return counts[root.lastPathComponent, default: 0]
        }
        return (0..<count).map {
            root.appending(path: "logical-\($0).jsonl").standardizedFileURL
        }
    }

    func enumerateJSONLFiles(
        under root: URL,
        maximumChunkSize: Int,
        consume: @escaping @Sendable ([URL]) async throws -> Void
    ) async throws {
        let configuration = lock.withLock { () -> (
            count: Int,
            gate: CancellableDiscoveryGate?,
            call: Int
        ) in
            enumerationCalls += 1
            rootNames.append(root.lastPathComponent)
            return (
                counts[root.lastPathComponent, default: 0],
                gate,
                enumerationCalls
            )
        }
        do {
            if let indexedGate {
                try await indexedGate.enter(call: configuration.call)
            }
            if let gate = configuration.gate { try await gate.wait() }
            var chunk: [URL] = []
            chunk.reserveCapacity(maximumChunkSize)
            for index in 0..<configuration.count {
                try Task.checkCancellation()
                chunk.append(
                    root.appending(path: "logical-\(index).jsonl").standardizedFileURL
                )
                if chunk.count == maximumChunkSize {
                    try await deliver(chunk, consume: consume)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty { try await deliver(chunk, consume: consume) }
        } catch is CancellationError {
            lock.withLock { cancellationCount += 1 }
            throw CancellationError()
        }
    }

    private func deliver(
        _ chunk: [URL],
        consume: @escaping @Sendable ([URL]) async throws -> Void
    ) async throws {
        lock.withLock {
            generatedFiles += chunk.count
            maximumChunkSize = max(maximumChunkSize, chunk.count)
            activeConsumers += 1
            maximumActiveConsumers = max(maximumActiveConsumers, activeConsumers)
        }
        do {
            try await consume(chunk)
            lock.withLock { activeConsumers -= 1 }
        } catch {
            lock.withLock { activeConsumers -= 1 }
            throw error
        }
    }
}

private actor CallIndexedDiscoveryGate {
    private let blockedCalls: Set<Int>
    private var enteredCalls: Set<Int> = []
    private var releasedCalls: Set<Int> = []
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]

    init(blockedCalls: Set<Int>) {
        self.blockedCalls = blockedCalls
    }

    func enter(call: Int) async throws {
        enteredCalls.insert(call)
        guard blockedCalls.contains(call), !releasedCalls.contains(call) else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if releasedCalls.contains(call) || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuations[call] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(call: call) }
        }
    }

    func hasEntered(call: Int) -> Bool {
        enteredCalls.contains(call)
    }

    func release(call: Int) {
        releasedCalls.insert(call)
        continuations.removeValue(forKey: call)?.resume()
    }

    func releaseAll() {
        releasedCalls.formUnion(blockedCalls)
        let pending = continuations.values
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    private func cancel(call: Int) {
        continuations.removeValue(forKey: call)?.resume(
            throwing: CancellationError()
        )
    }
}

private actor CancellableDiscoveryGate {
    private var entered = false
    private var released = false
    private(set) var wasCancelled = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    var hasEntered: Bool { entered }

    func wait() async throws {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if released { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if released {
                    continuation.resume()
                } else if wasCancelled || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    private func cancel() {
        wasCancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private actor CancellableDrainEntryGate {
    private var entered = false
    private var released = false
    private(set) var wasCancelled = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    var hasEntered: Bool { entered }

    func wait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if released { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released || wasCancelled || Task.isCancelled {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    private func cancel() {
        wasCancelled = true
        continuation?.resume()
        continuation = nil
    }
}

private struct ProviderFailingDiscovery: LogDiscovering {
    let failingRoot: URL

    func jsonlFiles(under root: URL) throws -> [URL] {
        if root.standardizedFileURL.path == failingRoot.standardizedFileURL.path {
            throw RecordingScannerError.injected
        }
        return []
    }
}

private actor ManualIngestionClock: IngestionClock {
    private struct Sleeper {
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private var sleepers: [UUID: Sleeper] = [:]
    private(set) var cancelledSleepCount = 0
    private var sleepStartCounts: [Duration: Int] = [:]
    private var sleepStartWaiters: [(
        Duration,
        Int,
        CheckedContinuation<Void, Never>
    )] = []
    private(set) var requestedDurations: [Duration] = []

    var waiterCount: Int { sleepers.count }
    var debounceRestarted: Bool {
        sleepStartCounts[.milliseconds(750), default: 0] == 2
            && sleepers.values.filter { $0.duration == .milliseconds(750) }.count == 1
            && cancelledSleepCount >= 1
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        sleepStartCounts[duration, default: 0] += 1
        requestedDurations.append(duration)
        let ready = sleepStartWaiters.filter {
            $0.0 == duration && sleepStartCounts[duration, default: 0] >= $0.1
        }
        sleepStartWaiters.removeAll {
            $0.0 == duration && sleepStartCounts[duration, default: 0] >= $0.1
        }
        ready.forEach { $0.2.resume() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = Sleeper(duration: duration, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func advancePastDebounce() {
        resumeAll(for: .milliseconds(750))
    }

    func waitForSleepStartCount(_ count: Int) async {
        await waitForSleepStartCount(count, duration: .milliseconds(750))
    }

    func waitForSleepStartCount(_ count: Int, duration: Duration) async {
        guard sleepStartCounts[duration, default: 0] < count else { return }
        await withCheckedContinuation {
            sleepStartWaiters.append((duration, count, $0))
        }
    }

    func hasRequested(_ duration: Duration) -> Bool {
        requestedDurations.contains(duration)
    }

    func hasStartedSleep(count: Int, duration: Duration) -> Bool {
        sleepStartCounts[duration, default: 0] >= count
    }

    func requestCount(for duration: Duration) -> Int {
        requestedDurations.filter { $0 == duration }.count
    }

    func resumeAll(for duration: Duration) {
        let matching = sleepers.filter { $0.value.duration == duration }
        for (id, sleeper) in matching {
            sleepers[id] = nil
            sleeper.continuation.resume()
        }
    }

    private func cancel(id: UUID) {
        guard let sleeper = sleepers.removeValue(forKey: id) else { return }
        cancelledSleepCount += 1
        sleeper.continuation.resume(throwing: CancellationError())
    }
}
