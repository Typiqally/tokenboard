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
        await waitUntil { await clock.waiterCount == 1 }
        watcher.emit([changedA, changedB])
        await waitUntil { await clock.debounceRestarted }
        await clock.advancePastDebounce()
        await waitUntil { await scanner.scannedURLs.count == 2 }

        let scannedURLs = await scanner.scannedURLs
        let scannedProviders = await scanner.scannedProviders
        let maximumConcurrentScans = await scanner.maximumConcurrentScans
        let requestedDurations = await clock.requestedDurations
        XCTAssertEqual(scannedURLs, [changedA, changedB])
        XCTAssertEqual(scannedProviders, [.claudeCode, .codex])
        XCTAssertEqual(maximumConcurrentScans, 1)
        XCTAssertEqual(requestedDurations, [.milliseconds(750), .milliseconds(750)])
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
        await waitUntil { await clock.waiterCount == 1 }
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
        await waitUntil { await clock.waiterCount == 1 }
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
        let discovery = CountingDiscovery()
        let coordinator = IngestionCoordinator(
            scanner: scanner,
            watcher: FakeSourceEventWatcher(),
            clock: ManualIngestionClock(),
            discovery: discovery,
            calendar: calendar
        )
        let initial = try await coordinator.start(roots: setup.roots)
        try Data().write(to: firstFile)

        let firstRefresh = Task { await coordinator.refreshAll() }
        await scanner.waitForScanCount(1)
        let secondRefresh = Task { await coordinator.refreshAll() }
        await discovery.waitForCallCount(6)
        let stop = Task { await coordinator.stop() }
        await scanner.waitUntilCancelled()
        await scanner.resumeFirstScan()
        await stop.value
        let stoppedResults = await [firstRefresh.value, secondRefresh.value]

        await scanner.reset()
        let restarted = try await coordinator.start(roots: setup.roots)
        XCTAssertEqual(stoppedResults.map(\.runID), [initial.runID, initial.runID])
        XCTAssertEqual(stoppedResults.map(\.sequence), [2, 3])
        XCTAssertNotEqual(restarted.runID, initial.runID)
        XCTAssertEqual(restarted.sequence, 1)
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
        await waitUntil { await clock.waiterCount == 1 }
        await clock.advancePastDebounce()
        await scanner.resumeFirstScan()
        _ = try await startTask.value
        await waitUntil { await scanner.scannedURLs.count == 2 }

        let scannedURLs = await scanner.scannedURLs
        let maximumConcurrentScans = await scanner.maximumConcurrentScans
        XCTAssertEqual(scannedURLs, [first, followUp])
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

private final class CountingDiscovery: LogDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func jsonlFiles(under root: URL) throws -> [URL] {
        let files = try LogDiscovery().jsonlFiles(under: root)
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            callCount += 1
            let ready = waiters.filter { callCount >= $0.0 }.map(\.1)
            waiters.removeAll { callCount >= $0.0 }
            return ready
        }
        ready.forEach { $0.resume() }
        return files
    }

    func waitForCallCount(_ count: Int) async {
        let alreadyReached = lock.withLock { callCount >= count }
        guard !alreadyReached else { return }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                if callCount >= count { return true }
                waiters.append((count, continuation))
                return false
            }
            if shouldResume { continuation.resume() }
        }
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
    private var sleepers: [UUID: CheckedContinuation<Void, Error>] = [:]
    private(set) var cancelledSleepCount = 0
    private var sleepStartCount = 0
    private var sleepStartWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var requestedDurations: [Duration] = []

    var waiterCount: Int { sleepers.count }
    var debounceRestarted: Bool {
        sleepStartCount == 2 && sleepers.count == 1 && cancelledSleepCount == 1
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        sleepStartCount += 1
        requestedDurations.append(duration)
        let ready = sleepStartWaiters.filter { sleepStartCount >= $0.0 }
        sleepStartWaiters.removeAll { sleepStartCount >= $0.0 }
        ready.forEach { $0.1.resume() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func advancePastDebounce() {
        let continuations = sleepers.values
        sleepers.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitForSleepStartCount(_ count: Int) async {
        guard sleepStartCount < count else { return }
        await withCheckedContinuation { sleepStartWaiters.append((count, $0)) }
    }

    private func cancel(id: UUID) {
        guard let continuation = sleepers.removeValue(forKey: id) else { return }
        cancelledSleepCount += 1
        continuation.resume(throwing: CancellationError())
    }
}
