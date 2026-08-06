import Foundation
import XCTest
@testable import TokenboardCore

final class IngestionCoordinatorTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
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
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: clock,
            discovery: discovery,
            calendar: calendar
        )
        let initial = try await coordinator.start(roots: setup.roots)
        let gate = CancellableDiscoveryGate()
        discovery.configure(
            counts: ["claude": 10_000, "codex": 10_000],
            gate: gate
        )
        discovery.resetMetrics()
        await scanner.reset()

        let stoppedRunWasStreamed = TimedAsyncFlag()
        let firstStreamedResult = Task { () -> IngestionBatchResult? in
            let stream = await coordinator.results()
            for await result in stream {
                if result.runID == initial.runID {
                    await stoppedRunWasStreamed.set()
                }
                return result
            }
            return nil
        }
        watcher.emit([setup.claudeRoot, setup.codexRoot])
        await clock.waitForSleepStartCount(1)
        await clock.advancePastDebounce()
        await gate.waitUntilEntered()
        var refreshes: [Task<IngestionBatchResult, Never>] = []
        for _ in 0..<32 {
            refreshes.append(Task { await coordinator.refreshAll() })
        }
        await waitUntil {
            await coordinator.diagnostics().inventoryWaiterCount == 32
        }
        let stopFinished = TimedAsyncFlag()
        let stop = Task {
            await coordinator.stop()
            await stopFinished.set()
        }
        let stoppedBeforeRelease = await stopFinished.wait(for: .milliseconds(200))
        if !stoppedBeforeRelease { await gate.release() }
        await stop.value
        var stoppedResults: [IngestionBatchResult] = []
        for refresh in refreshes { stoppedResults.append(await refresh.value) }

        let stoppedDiscovery = discovery.snapshot()
        let stoppedScans = await scanner.snapshot()
        let discoveryWasCancelled = await gate.wasCancelled
        let stoppedResultDelivered = await stoppedRunWasStreamed.wait(
            for: .milliseconds(50)
        )
        XCTAssertTrue(stoppedBeforeRelease)
        XCTAssertTrue(discoveryWasCancelled)
        XCTAssertFalse(stoppedResultDelivered)
        XCTAssertEqual(stoppedDiscovery.synchronousArrayCalls, 0)
        XCTAssertEqual(stoppedDiscovery.generatedFiles, 0)
        XCTAssertEqual(stoppedScans.totalScans, 0)
        XCTAssertEqual(Set(stoppedResults.map(\.runID)), [initial.runID])
        XCTAssertEqual(Set(stoppedResults.map(\.sequence)), [3])

        discovery.configure(counts: [:], gate: nil)
        discovery.resetMetrics()
        let restarted = try await coordinator.start(roots: setup.roots)
        XCTAssertNotEqual(restarted.runID, initial.runID)
        XCTAssertEqual(restarted.sequence, 1)
        let later = setup.codexRoot.appending(path: "later.jsonl")
        try Data().write(to: later)
        watcher.emit([later])
        await clock.waitForSleepStartCount(2)
        await clock.advancePastDebounce()
        let laterResult = await firstStreamedResult.value
        XCTAssertEqual(laterResult?.runID, restarted.runID)
        XCTAssertEqual(laterResult?.sequence, 2)
        XCTAssertEqual(
            laterResult?.providers[.codex],
            .success(discoveredFiles: 1, scannedFiles: 1)
        )
        await coordinator.stop()
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
        let firstStreamedResult = Task { () -> IngestionBatchResult? in
            for await result in stream { return result }
            return nil
        }

        let start = Task { try await coordinator.start(roots: setup.roots) }
        await drainEntry.waitUntilEntered()
        var refreshes: [Task<IngestionBatchResult, Never>] = []
        for _ in 0..<16 {
            refreshes.append(Task { await coordinator.refreshAll() })
        }
        await waitUntil {
            await coordinator.diagnostics().inventoryWaiterCount == 17
        }

        await coordinator.stop()
        await drainEntry.release()
        do {
            _ = try await start.value
            XCTFail("stopped start should be cancelled")
        } catch is CancellationError {
            // Expected: stop invalidated the start after settling its inventory waiter.
        }
        var stoppedResults: [IngestionBatchResult] = []
        for refresh in refreshes { stoppedResults.append(await refresh.value) }

        let stoppedDiscovery = discovery.snapshot()
        let stoppedScans = await scanner.snapshot()
        let drainWasCancelled = await drainEntry.wasCancelled
        XCTAssertTrue(drainWasCancelled)
        XCTAssertEqual(stoppedDiscovery.enumerationCalls, 0)
        XCTAssertEqual(stoppedDiscovery.generatedFiles, 0)
        XCTAssertEqual(stoppedScans.totalScans, 0)
        XCTAssertEqual(stoppedResults.count, 16)
        XCTAssertEqual(Set(stoppedResults.map(\.runID)).count, 1)
        XCTAssertEqual(Set(stoppedResults.map(\.sequence)), [1])
        let stoppedDiagnostics = await coordinator.diagnostics()
        XCTAssertEqual(stoppedDiagnostics.inventoryWaiterCount, 0)
        XCTAssertEqual(stoppedDiagnostics.pendingBatchCount, 0)

        discovery.resetMetrics()
        await scanner.reset()
        let restarted = try await coordinator.start(roots: setup.roots)
        XCTAssertNotEqual(restarted.runID, stoppedResults[0].runID)
        let later = setup.codexRoot.appending(path: "later-after-entry-stop.jsonl")
        try Data().write(to: later)
        watcher.emit([later])
        await clock.waitForSleepStartCount(1)
        await clock.advancePastDebounce()
        let laterResult = await firstStreamedResult.value
        XCTAssertEqual(laterResult?.runID, restarted.runID)
        XCTAssertEqual(laterResult?.sequence, 2)
        XCTAssertEqual(
            laterResult?.providers[.codex],
            ProviderIngestionResult.success(discoveredFiles: 1, scannedFiles: 1)
        )
        await coordinator.stop()
    }

    func testEventsDuringChunkedRootDiscoveryCollapseToOneTwoProviderFollowUp() async throws {
        let setup = try makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let watcher = FakeSourceEventWatcher()
        let clock = ManualIngestionClock()
        let discovery = ChunkedLogicalDiscovery(counts: [:])
        let scanner = ChunkCountingScanner()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: watcher,
            clock: clock,
            discovery: discovery,
            calendar: calendar
        )
        _ = try await coordinator.start(roots: setup.roots)
        let gate = CancellableDiscoveryGate()
        discovery.configure(
            counts: ["claude": 130, "codex": 129],
            gate: gate
        )
        discovery.resetMetrics()
        await scanner.reset()
        let stream = await coordinator.results()
        let received = Task { () -> [IngestionBatchResult] in
            var values: [IngestionBatchResult] = []
            for await result in stream {
                values.append(result)
                if values.count == 2 { return values }
            }
            return values
        }

        watcher.emit([setup.claudeRoot, setup.codexRoot])
        await clock.waitForSleepStartCount(1)
        await clock.advancePastDebounce()
        await gate.waitUntilEntered()
        for index in 0..<12 {
            let root = index.isMultiple(of: 2) ? setup.claudeRoot : setup.codexRoot
            watcher.emit([root.appending(path: "burst-\(index).jsonl")])
            await clock.waitForSleepStartCount(index + 2)
            await clock.advancePastDebounce()
        }
        let duringDiscovery = await coordinator.diagnostics()
        XCTAssertEqual(duringDiscovery.followUpDirtyProviderCount, 2)
        XCTAssertEqual(duringDiscovery.pendingEventBatchCount, 0)

        await gate.release()
        let values = await received.value
        await waitUntil {
            let diagnostics = await coordinator.diagnostics()
            return !diagnostics.isDraining && diagnostics.pendingBatchCount == 0
        }

        let discoverySnapshot = discovery.snapshot()
        let scannerSnapshot = await scanner.snapshot()
        XCTAssertEqual(values.count, 2)
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
        await coordinator.stop()
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
        let consumer = Task {
            for await result in stream { await recorder.append(result) }
        }

        let start = Task { try await coordinator.start(roots: setup.roots) }
        await gate.waitUntilEntered()
        let early = setup.claudeRoot.appending(path: "early.jsonl")
        try Data().write(to: early)
        watcher.emit([early])
        await clock.waitForSleepStartCount(1)
        await clock.advancePastDebounce()
        for index in 0..<3 {
            let root = index.isMultiple(of: 2) ? setup.codexRoot : setup.claudeRoot
            watcher.emit([root.appending(path: "later-\(index).jsonl")])
            await clock.waitForSleepStartCount(index + 2)
            await clock.advancePastDebounce()
        }
        watcher.emit([setup.claudeRoot, setup.codexRoot])
        await clock.waitForSleepStartCount(5)
        await clock.advancePastDebounce()

        let whileInventoryIsGated = await coordinator.diagnostics()
        XCTAssertEqual(whileInventoryIsGated.pendingEventBatchCount, 0)
        XCTAssertEqual(whileInventoryIsGated.followUpDirtyProviderCount, 2)
        XCTAssertTrue(whileInventoryIsGated.pendingBatchCount <= 1)

        await gate.release()
        let initial = try await start.value
        await waitUntil {
            let diagnostics = await coordinator.diagnostics()
            return !diagnostics.isDraining && diagnostics.pendingBatchCount == 0
        }
        await waitUntil { await recorder.count == 1 }
        let values = await recorder.snapshot()
        consumer.cancel()
        _ = await consumer.value

        let discoverySnapshot = discovery.snapshot()
        let scannerSnapshot = await scanner.snapshot()
        XCTAssertEqual(values.count, 1)
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
        await coordinator.stop()
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
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
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
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
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
}

private actor TimedAsyncFlag {
    private var current = false

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

private final class FakeSourceEventWatcher: SourceEventWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Set<URL>>.Continuation?
    private(set) var requestedRoots: [URL] = []
    private(set) var eventsRequestCount = 0

    func events(for roots: [URL]) -> AsyncStream<Set<URL>> {
        lock.withLock {
            requestedRoots = roots
            eventsRequestCount += 1
        }
        return AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func emit(_ paths: Set<URL>) {
        lock.withLock { continuation }?.yield(paths)
    }

    func stop() {
        let continuation = lock.withLock { () -> AsyncStream<Set<URL>>.Continuation? in
            defer { self.continuation = nil }
            return self.continuation
        }
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
        let synchronousArrayCalls: Int
        let enumerationCalls: Int
        let generatedFiles: Int
        let maximumChunkSize: Int
        let maximumActiveConsumers: Int
        let cancellationCount: Int
    }

    private let lock = NSLock()
    private var counts: [String: Int]
    private var gate: CancellableDiscoveryGate?
    private var synchronousArrayCalls = 0
    private var enumerationCalls = 0
    private var generatedFiles = 0
    private var maximumChunkSize = 0
    private var activeConsumers = 0
    private var maximumActiveConsumers = 0
    private var cancellationCount = 0

    init(counts: [String: Int]) {
        self.counts = counts
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
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
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
        let configuration = lock.withLock { () -> (Int, CancellableDiscoveryGate?) in
            enumerationCalls += 1
            return (counts[root.lastPathComponent, default: 0], gate)
        }
        do {
            if let gate = configuration.1 { try await gate.wait() }
            var chunk: [URL] = []
            chunk.reserveCapacity(maximumChunkSize)
            for index in 0..<configuration.0 {
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

private actor CancellableDiscoveryGate {
    private var entered = false
    private var released = false
    private(set) var wasCancelled = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

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
        if root.standardizedFileURL == failingRoot.standardizedFileURL {
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
