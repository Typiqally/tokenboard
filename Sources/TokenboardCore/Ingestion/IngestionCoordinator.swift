import Foundation

public protocol IngestionScanning: Sendable {
    func scan(file: URL, provider: Provider, calendar: Calendar) async throws -> ScanOutcome
}

extension IncrementalScanner: IngestionScanning {}

public protocol IngestionClock: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ContinuousIngestionClock: IngestionClock {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

public enum IngestionCoordinatorError: Error, Equatable {
    case missingRoot(Provider)
    case overlappingRoots
    case replacementRootMismatch(Provider)
    case revokedRootStillPresent(Provider)
}

public enum ProviderIngestionResult: Equatable, Sendable {
    case success(discoveredFiles: Int, scannedFiles: Int)
    case attention(discoveredFiles: Int, scannedFiles: Int)
    case failure(discoveredFiles: Int, scannedFiles: Int)
}

public enum IngestionBatchScope: Equatable, Sendable {
    case inventory
    case incremental
}

public struct ProviderIngestionDiagnostics: Equatable, Sendable {
    public let skippedRecordCount: Int
    public let attention: Set<ScanOutcome.Attention>

    public init(
        skippedRecordCount: Int,
        attention: Set<ScanOutcome.Attention>
    ) {
        self.skippedRecordCount = max(0, skippedRecordCount)
        self.attention = attention
    }
}

public struct IngestionBatchResult: Equatable, Sendable {
    public let runID: UInt64
    public let sequence: UInt64
    public let scope: IngestionBatchScope
    public let requiresInventoryRefresh: Bool
    public let providers: [Provider: ProviderIngestionResult]
    public let diagnostics: [Provider: ProviderIngestionDiagnostics]

    public init(
        runID: UInt64,
        sequence: UInt64,
        scope: IngestionBatchScope,
        requiresInventoryRefresh: Bool = false,
        providers: [Provider: ProviderIngestionResult],
        diagnostics: [Provider: ProviderIngestionDiagnostics] = [:]
    ) {
        self.runID = runID
        self.sequence = sequence
        self.scope = scope
        self.requiresInventoryRefresh = requiresInventoryRefresh
        self.providers = providers
        self.diagnostics = diagnostics
    }
}

public enum IngestionRootValidator {
    public static func canonicalize(_ suppliedRoots: [Provider: URL]) -> [Provider: URL] {
        suppliedRoots.mapValues {
            let resolved = $0.standardizedFileURL.resolvingSymlinksInPath()
            return URL(fileURLWithPath: resolved.path).standardizedFileURL
        }
    }

    public static func validate(_ suppliedRoots: [Provider: URL]) throws -> [Provider: URL] {
        for provider in Provider.allCases where suppliedRoots[provider] == nil {
            throw IngestionCoordinatorError.missingRoot(provider)
        }
        return try validateMonitoringRoots(suppliedRoots)
    }

    public static func validateMonitoringRoots(
        _ suppliedRoots: [Provider: URL]
    ) throws -> [Provider: URL] {
        let roots = canonicalize(suppliedRoots)
        if let claudeRoot = roots[.claudeCode], let codexRoot = roots[.codex] {
            guard !contains(claudeRoot, codexRoot),
                  !contains(codexRoot, claudeRoot) else {
                throw IngestionCoordinatorError.overlappingRoots
            }
        }
        return roots
    }

    private static func contains(_ root: URL, _ candidate: URL) -> Bool {
        candidate.pathComponents.starts(with: root.pathComponents)
    }
}

struct IngestionCoordinatorDiagnostics: Equatable, Sendable {
    let pendingEventPathCount: Int
    let eventPathsCollapsedToRoots: Bool
    let pendingBatchCount: Int
    let pendingInventoryBatchCount: Int
    let pendingEventBatchCount: Int
    let followUpDirtyProviderCount: Int
    let inventoryWaiterCount: Int
    let isDraining: Bool
}

public actor IngestionCoordinator {
    static let maximumPendingEventPaths = 64
    static let maximumDiscoveryChunkSize = 64
    static let maximumEventLatency = Duration.seconds(2)
    private static let eventDebounceDelay = Duration.milliseconds(750)

    private enum Severity: Int, Sendable {
        case success
        case attention
        case failure
    }

    private struct WorkInput: Sendable {
        let url: URL
        let root: URL
        let provider: Provider
    }

    private struct ProviderProgress: Sendable {
        var discoveredFiles = 0
        var scannedFiles = 0
        var severity = Severity.success
        var skippedRecordCount = 0
        var attention: Set<ScanOutcome.Attention> = []

        var result: ProviderIngestionResult {
            switch severity {
            case .success:
                .success(discoveredFiles: discoveredFiles, scannedFiles: scannedFiles)
            case .attention:
                .attention(discoveredFiles: discoveredFiles, scannedFiles: scannedFiles)
            case .failure:
                .failure(discoveredFiles: discoveredFiles, scannedFiles: scannedFiles)
            }
        }

        var diagnostics: ProviderIngestionDiagnostics {
            ProviderIngestionDiagnostics(
                skippedRecordCount: skippedRecordCount,
                attention: attention
            )
        }
    }

    private struct BatchExecution: Sendable {
        var progress: [Provider: ProviderProgress]
        var wasCancelled: Bool
    }

    private struct QueuedBatch {
        let runID: UInt64
        let scope: IngestionBatchScope
        let inventoryProviders: Set<Provider>?
        let inputs: [WorkInput]
        let failedProviders: Set<Provider>
        var continuations: [CheckedContinuation<IngestionBatchResult, Never>]
    }

    public nonisolated let usesPeriodicRefresh = false

    private let scanner: any IngestionScanning
    private let watcher: any SourceEventWatching
    private let clock: any IngestionClock
    private let discovery: any LogDiscovering
    private let calendar: Calendar
    private let drainEntryHook: (@Sendable () async -> Void)?
    private let eventTimerCompletionHook: (@Sendable () -> Void)?
    private var roots: [Provider: URL] = [:]
    private var eventTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var maximumLatencyTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var activeWorkTask: Task<BatchExecution, Never>?
    private var stopBarrier: Task<Void, Never>?
    private var pendingEventPaths: Set<URL> = []
    private var pendingEventRootProviders: Set<Provider> = []
    private var followUpDirtyProviders: Set<Provider> = []
    private var pendingBatches: [QueuedBatch] = []
    private var activeBatchScope: IngestionBatchScope?
    private var activeBatchRunID: UInt64?
    private var activeInventoryProviders: Set<Provider>?
    private var activeBatchInputs: [WorkInput] = []
    private var activeInventoryContinuations: [
        CheckedContinuation<IngestionBatchResult, Never>
    ] = []
    private var debounceGeneration: UInt64 = 0
    private var eventWindowGeneration: UInt64 = 0
    private var runGeneration: UInt64 = 0
    private var nextSequence: UInt64 = 0
    private var startGeneration: UInt64 = 0
    private var activeRunID: UInt64?
    private let resultStream: AsyncStream<IngestionBatchResult>
    private let resultContinuation: AsyncStream<IngestionBatchResult>.Continuation

    public init(
        scanner: any IngestionScanning,
        watcher: any SourceEventWatching = FSEventWatcher(),
        clock: any IngestionClock = ContinuousIngestionClock(),
        discovery: any LogDiscovering = LogDiscovery(),
        calendar: Calendar = .current
    ) {
        self.init(
            scanner: scanner,
            watcher: watcher,
            clock: clock,
            discovery: discovery,
            calendar: calendar,
            drainEntryHook: nil,
            eventTimerCompletionHook: nil
        )
    }

    init(
        scanner: any IngestionScanning,
        watcher: any SourceEventWatching,
        clock: any IngestionClock,
        discovery: any LogDiscovering,
        calendar: Calendar,
        drainEntryHook: (@Sendable () async -> Void)?,
        eventTimerCompletionHook: (@Sendable () -> Void)? = nil
    ) {
        let (stream, continuation) = AsyncStream<IngestionBatchResult>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.scanner = scanner
        self.watcher = watcher
        self.clock = clock
        self.discovery = discovery
        self.calendar = calendar
        self.drainEntryHook = drainEntryHook
        self.eventTimerCompletionHook = eventTimerCompletionHook
        resultStream = stream
        resultContinuation = continuation
    }

    public func results() -> AsyncStream<IngestionBatchResult> {
        resultStream
    }

    func diagnostics() -> IngestionCoordinatorDiagnostics {
        let pendingInventory = pendingBatches.filter { $0.scope == .inventory }
        return IngestionCoordinatorDiagnostics(
            pendingEventPathCount: pendingEventPaths.count
                + pendingEventRootProviders.count,
            eventPathsCollapsedToRoots: !roots.isEmpty
                && pendingEventRootProviders == Set(roots.keys),
            pendingBatchCount: pendingBatches.count,
            pendingInventoryBatchCount: pendingInventory.count,
            pendingEventBatchCount: pendingBatches.filter {
                $0.scope == .incremental
            }.count,
            followUpDirtyProviderCount: followUpDirtyProviders.count,
            inventoryWaiterCount: activeInventoryContinuations.count
                + pendingInventory.reduce(0) { $0 + $1.continuations.count },
            isDraining: drainTask != nil
        )
    }

    public func start(roots suppliedRoots: [Provider: URL]) async throws -> IngestionBatchResult {
        let canonicalRoots = try IngestionRootValidator.validate(suppliedRoots)
        return try await startMonitoring(canonicalRoots: canonicalRoots)
    }

    public func startMonitoring(
        roots suppliedRoots: [Provider: URL]
    ) async throws -> IngestionBatchResult {
        let canonicalRoots = try IngestionRootValidator.validateMonitoringRoots(suppliedRoots)
        guard !canonicalRoots.isEmpty else {
            throw IngestionCoordinatorError.missingRoot(.claudeCode)
        }
        return try await startMonitoring(canonicalRoots: canonicalRoots)
    }

    private func startMonitoring(
        canonicalRoots: [Provider: URL]
    ) async throws -> IngestionBatchResult {
        startGeneration &+= 1
        let startID = startGeneration
        let runID = try await activateMonitoring(
            roots: canonicalRoots,
            startID: startID
        )
        let result = await enqueueInventoryAndWait(
            runID: runID,
            providers: Set(canonicalRoots.keys)
        )
        guard startGeneration == startID,
              activeRunID == runID else { throw CancellationError() }
        return result
    }

    public func replaceSource(
        _ provider: Provider,
        with root: URL,
        roots suppliedRoots: [Provider: URL]
    ) async throws -> IngestionBatchResult {
        startGeneration &+= 1
        let startID = startGeneration
        let canonicalRoots = try IngestionRootValidator.validateMonitoringRoots(suppliedRoots)
        let canonicalReplacement = IngestionRootValidator.canonicalize([provider: root])[provider]
        guard canonicalRoots[provider] == canonicalReplacement else {
            throw IngestionCoordinatorError.replacementRootMismatch(provider)
        }
        let runID = try await activateMonitoring(
            roots: canonicalRoots,
            startID: startID
        )
        let result = await enqueueInventoryAndWait(
            runID: runID,
            providers: [provider]
        )
        guard startGeneration == startID,
              activeRunID == runID else { throw CancellationError() }
        return result
    }

    @discardableResult
    public func revokeSource(
        _ provider: Provider,
        remainingRoots suppliedRoots: [Provider: URL]
    ) async throws -> UInt64? {
        startGeneration &+= 1
        let startID = startGeneration
        let canonicalRoots = try IngestionRootValidator.validateMonitoringRoots(suppliedRoots)
        guard canonicalRoots[provider] == nil else {
            throw IngestionCoordinatorError.revokedRootStillPresent(provider)
        }
        guard !canonicalRoots.isEmpty else {
            await stopWithBarrier()
            guard startGeneration == startID else { throw CancellationError() }
            stopBarrier = nil
            return nil
        }
        return try await activateMonitoring(
            roots: canonicalRoots,
            startID: startID
        )
    }

    private func activateMonitoring(
        roots canonicalRoots: [Provider: URL],
        startID: UInt64
    ) async throws -> UInt64 {
        let priorEventTask = eventTask
        watcher.stop()
        eventTask = nil
        await priorEventTask?.value
        guard startGeneration == startID else { throw CancellationError() }
        let retainedEventPaths = retainedEventPaths(whenTransitioningTo: canonicalRoots)
        await stopWithBarrier()
        guard startGeneration == startID else { throw CancellationError() }
        stopBarrier = nil
        let orderedRoots = Provider.allCases.compactMap { canonicalRoots[$0] }
        let events = try watcher.start(roots: orderedRoots)
        guard startGeneration == startID else {
            watcher.stop()
            throw CancellationError()
        }
        runGeneration &+= 1
        let runID = runGeneration
        nextSequence = 0
        activeRunID = runID
        roots = canonicalRoots
        eventTask = Task { [weak self] in
            for await batch in events {
                guard !Task.isCancelled else { break }
                await self?.receive(batch: batch, runID: runID)
            }
        }
        if !retainedEventPaths.isEmpty {
            _ = await enqueueEventAndWait(
                runID: runID,
                paths: retainedEventPaths
            )
        }
        return runID
    }

    public func refreshAll() async -> IngestionBatchResult {
        guard let runID = activeRunID else {
            return IngestionBatchResult(
                runID: runGeneration,
                sequence: 0,
                scope: .inventory,
                providers: Dictionary(uniqueKeysWithValues: Provider.allCases.map {
                    ($0, .failure(discoveredFiles: 0, scannedFiles: 0))
                })
            )
        }
        return await enqueueInventoryAndWait(
            runID: runID,
            providers: Set(roots.keys)
        )
    }

    public func stop() async {
        startGeneration &+= 1
        await stopWithBarrier()
    }

    private func stopWithBarrier() async {
        if let stopBarrier {
            await stopBarrier.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.stopRuntime()
        }
        stopBarrier = task
        await task.value
    }

    private func stopRuntime() async {
        runGeneration &+= 1
        activeRunID = nil
        watcher.stop()
        eventTask?.cancel()
        debounceTask?.cancel()
        maximumLatencyTask?.cancel()
        drainTask?.cancel()
        activeWorkTask?.cancel()
        let tasks = [
            eventTask,
            debounceTask,
            maximumLatencyTask,
            drainTask
        ].compactMap { $0 }
        let workTask = activeWorkTask
        eventTask = nil
        debounceTask = nil
        maximumLatencyTask = nil
        pendingEventPaths.removeAll()
        pendingEventRootProviders.removeAll()
        followUpDirtyProviders.removeAll()
        debounceGeneration &+= 1
        eventWindowGeneration &+= 1
        _ = await workTask?.value
        for task in tasks {
            await task.value
        }
        activeWorkTask = nil
        drainTask = nil
        activeInventoryProviders = nil
        activeBatchInputs.removeAll()
        failRemainingBatches()
        roots.removeAll()
    }

    private func receive(batch: SourceEventBatch, runID: UInt64) {
        guard activeRunID == runID, !roots.isEmpty else { return }
        mergePendingEventPaths(batch.paths)
        watcher.acknowledge(batch.checkpoint)
        debounceGeneration &+= 1
        let generation = debounceGeneration
        debounceTask?.cancel()
        let eventTimerCompletionHook = self.eventTimerCompletionHook
        debounceTask = Task { [weak self, clock, eventTimerCompletionHook] in
            defer { eventTimerCompletionHook?() }
            do {
                try await clock.sleep(for: Self.eventDebounceDelay)
                guard !Task.isCancelled else { return }
                await self?.quietDebounceElapsed(
                    generation: generation,
                    runID: runID
                )
            } catch {
                return
            }
        }
        if maximumLatencyTask == nil {
            eventWindowGeneration &+= 1
            let window = eventWindowGeneration
            maximumLatencyTask = Task { [weak self, clock, eventTimerCompletionHook] in
                defer { eventTimerCompletionHook?() }
                do {
                    try await clock.sleep(for: Self.maximumEventLatency)
                    guard !Task.isCancelled else { return }
                    await self?.maximumLatencyElapsed(
                        window: window,
                        runID: runID
                    )
                } catch {
                    return
                }
            }
        }
    }

    private func retainedEventPaths(
        whenTransitioningTo newRoots: [Provider: URL]
    ) -> Set<URL> {
        let retainedProviders = Set(roots.compactMap { provider, root in
            newRoots[provider] == root ? provider : nil
        })
        guard !retainedProviders.isEmpty else { return [] }
        var retained = Set(pendingEventPaths.filter {
            guard let provider = providerAndRoot(containing: $0)?.0 else { return false }
            return retainedProviders.contains(provider)
        })
        for provider in pendingEventRootProviders.intersection(retainedProviders) {
            if let root = roots[provider] { retained.insert(root) }
        }
        for provider in followUpDirtyProviders.intersection(retainedProviders) {
            if let root = roots[provider] { retained.insert(root) }
        }
        let queuedInputs = pendingBatches
            .filter { $0.scope == .incremental }
            .flatMap(\.inputs)
        let inFlightInputs = activeBatchScope == .incremental ? activeBatchInputs : []
        for input in queuedInputs + inFlightInputs where retainedProviders.contains(input.provider) {
            retained.insert(input.url)
        }
        if retained.count > Self.maximumPendingEventPaths {
            return Set(retainedProviders.compactMap { roots[$0] })
        }
        return retained
    }

    private func mergePendingEventPaths(_ paths: Set<URL>) {
        guard pendingEventRootProviders != Set(roots.keys) else { return }
        for path in paths {
            let standardized = path.standardizedFileURL
            guard let (provider, root) = providerAndRoot(containing: standardized) else {
                continue
            }
            if standardized == root {
                pendingEventRootProviders.insert(provider)
                pendingEventPaths = pendingEventPaths.filter {
                    providerAndRoot(containing: $0)?.0 != provider
                }
                continue
            }
            guard !pendingEventRootProviders.contains(provider) else { continue }
            if !pendingEventPaths.contains(standardized),
               pendingEventPaths.count + pendingEventRootProviders.count
                == Self.maximumPendingEventPaths {
                pendingEventPaths.removeAll()
                pendingEventRootProviders = Set(roots.keys)
                return
            }
            pendingEventPaths.insert(standardized)
        }
    }

    private func quietDebounceElapsed(generation: UInt64, runID: UInt64) {
        guard generation == debounceGeneration,
              activeRunID == runID else { return }
        drainPendingEventSignals(runID: runID)
    }

    private func maximumLatencyElapsed(window: UInt64, runID: UInt64) {
        guard window == eventWindowGeneration,
              activeRunID == runID else { return }
        drainPendingEventSignals(runID: runID)
    }

    private func drainPendingEventSignals(runID: UInt64) {
        debounceTask?.cancel()
        maximumLatencyTask?.cancel()
        debounceTask = nil
        maximumLatencyTask = nil
        debounceGeneration &+= 1
        eventWindowGeneration &+= 1
        let paths = pendingEventPaths.union(
            pendingEventRootProviders.compactMap { roots[$0] }
        )
        pendingEventPaths.removeAll()
        pendingEventRootProviders.removeAll()
        guard !paths.isEmpty else { return }
        if activeBatchScope != nil || !pendingBatches.isEmpty {
            markFollowUpDirtyProviders(for: paths)
            return
        }
        let inputs = paths.sorted(by: { $0.path < $1.path }).compactMap { path in
            providerAndRoot(containing: path).map { provider, root in
                WorkInput(url: path, root: root, provider: provider)
            }
        }
        guard !inputs.isEmpty else { return }
        enqueueEventBatch(runID: runID, inputs: inputs)
    }

    private func markFollowUpDirtyProviders(for paths: Set<URL>) {
        for path in paths {
            if let (provider, _) = providerAndRoot(containing: path) {
                followUpDirtyProviders.insert(provider)
            }
        }
    }

    private func enqueueInventoryAndWait(
        runID: UInt64,
        providers: Set<Provider>
    ) async -> IngestionBatchResult {
        await withCheckedContinuation { continuation in
            if activeBatchScope == .inventory,
               activeBatchRunID == runID,
               activeInventoryProviders == providers {
                activeInventoryContinuations.append(continuation)
                return
            }
            if let index = pendingBatches.firstIndex(where: {
                $0.scope == .inventory
                    && $0.runID == runID
                    && $0.inventoryProviders == providers
            }) {
                pendingBatches[index].continuations.append(continuation)
                return
            }
            let inputs = Provider.allCases.compactMap { provider -> WorkInput? in
                guard providers.contains(provider) else { return nil }
                return roots[provider].map {
                    WorkInput(url: $0, root: $0, provider: provider)
                }
            }
            let failedProviders = providers.subtracting(
                inputs.map(\.provider)
            )
            pendingBatches.append(QueuedBatch(
                runID: runID,
                scope: .inventory,
                inventoryProviders: providers,
                inputs: inputs,
                failedProviders: failedProviders,
                continuations: [continuation]
            ))
            startDrainIfNeeded()
        }
    }

    private func enqueueEventBatch(
        runID: UInt64,
        inputs: [WorkInput],
        failedProviders: Set<Provider> = []
    ) {
        pendingBatches.append(QueuedBatch(
            runID: runID,
            scope: .incremental,
            inventoryProviders: nil,
            inputs: inputs,
            failedProviders: failedProviders,
            continuations: []
        ))
        startDrainIfNeeded()
    }

    private func enqueueEventAndWait(
        runID: UInt64,
        paths: Set<URL>
    ) async -> IngestionBatchResult {
        let inputs = paths.sorted(by: { $0.path < $1.path }).compactMap { path in
            providerAndRoot(containing: path).map { provider, root in
                WorkInput(url: path, root: root, provider: provider)
            }
        }
        return await withCheckedContinuation { continuation in
            guard !inputs.isEmpty else {
                continuation.resume(returning: IngestionBatchResult(
                    runID: runID,
                    sequence: nextSequence,
                    scope: .incremental,
                    providers: [:]
                ))
                return
            }
            pendingBatches.append(QueuedBatch(
                runID: runID,
                scope: .incremental,
                inventoryProviders: nil,
                inputs: inputs,
                failedProviders: [],
                continuations: [continuation]
            ))
            startDrainIfNeeded()
        }
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil, !pendingBatches.isEmpty else { return }
        let drainEntryHook = self.drainEntryHook
        let expectedRunGeneration = runGeneration
        drainTask = Task { [weak self, drainEntryHook] in
            if let drainEntryHook { await drainEntryHook() }
            await self?.drainBatches(expectedRunGeneration: expectedRunGeneration)
        }
    }

    private func drainBatches(expectedRunGeneration: UInt64) async {
        guard canDrain(expectedRunGeneration: expectedRunGeneration) else {
            drainTask = nil
            return
        }
        while canDrain(expectedRunGeneration: expectedRunGeneration),
              let currentRunID = activeRunID,
              pendingBatches.first?.runID == currentRunID {
            guard canDrain(expectedRunGeneration: expectedRunGeneration) else {
                break
            }
            let queued = pendingBatches.removeFirst()
            activeBatchScope = queued.scope
            activeBatchRunID = queued.runID
            activeInventoryProviders = queued.inventoryProviders
            activeBatchInputs = queued.inputs
            activeInventoryContinuations = queued.continuations
            let scanner = self.scanner
            let discovery = self.discovery
            let calendar = self.calendar
            guard canDrain(expectedRunGeneration: expectedRunGeneration),
                  activeRunID == queued.runID else {
                pendingBatches.insert(queued, at: 0)
                activeInventoryContinuations.removeAll()
                activeBatchScope = nil
                activeBatchRunID = nil
                activeInventoryProviders = nil
                activeBatchInputs.removeAll()
                break
            }
            let workTask = Task.detached(priority: .utility) {
                await Self.executeBatch(
                    inputs: queued.inputs,
                    failedProviders: queued.failedProviders,
                    scanner: scanner,
                    discovery: discovery,
                    calendar: calendar
                )
            }
            activeWorkTask = workTask
            let execution = await workTask.value
            activeWorkTask = nil
            let inventoryContinuations = activeInventoryContinuations
            activeInventoryContinuations.removeAll()
            activeBatchScope = nil
            activeBatchRunID = nil
            activeInventoryProviders = nil
            activeBatchInputs.removeAll()
            if queued.scope == .inventory || !execution.progress.isEmpty {
                nextSequence &+= 1
                let result = IngestionBatchResult(
                    runID: queued.runID,
                    sequence: nextSequence,
                    scope: queued.scope,
                    providers: execution.progress.mapValues(\.result),
                    diagnostics: execution.progress.mapValues(\.diagnostics)
                )
                inventoryContinuations.forEach { $0.resume(returning: result) }
                if queued.scope == .incremental,
                   activeRunID == queued.runID,
                   case .dropped = resultContinuation.yield(result) {
                    nextSequence &+= 1
                    resultContinuation.yield(IngestionBatchResult(
                        runID: queued.runID,
                        sequence: nextSequence,
                        scope: .incremental,
                        requiresInventoryRefresh: true,
                        providers: [:]
                    ))
                }
            } else {
                let result = IngestionBatchResult(
                    runID: queued.runID,
                    sequence: nextSequence,
                    scope: queued.scope,
                    providers: [:]
                )
                inventoryContinuations.forEach { $0.resume(returning: result) }
            }
            enqueueFollowUpEventIfNeeded(runID: queued.runID)
            if Task.isCancelled || execution.wasCancelled { break }
        }
        drainTask = nil
    }

    private func canDrain(expectedRunGeneration: UInt64) -> Bool {
        !Task.isCancelled
            && runGeneration == expectedRunGeneration
            && activeRunID != nil
    }

    private func enqueueFollowUpEventIfNeeded(runID: UInt64) {
        guard activeRunID == runID else { return }
        absorbPendingEventSignalsIntoFollowUp()
        guard !followUpDirtyProviders.isEmpty,
              pendingBatches.isEmpty else {
            return
        }
        let providers = followUpDirtyProviders
        followUpDirtyProviders.removeAll()
        let inputs = Provider.allCases.compactMap { provider -> WorkInput? in
            guard providers.contains(provider), let root = roots[provider] else {
                return nil
            }
            return WorkInput(url: root, root: root, provider: provider)
        }
        let failedProviders = providers.subtracting(inputs.map(\.provider))
        guard !inputs.isEmpty || !failedProviders.isEmpty else { return }
        enqueueEventBatch(
            runID: runID,
            inputs: inputs,
            failedProviders: failedProviders
        )
    }

    private func absorbPendingEventSignalsIntoFollowUp() {
        debounceTask?.cancel()
        maximumLatencyTask?.cancel()
        debounceTask = nil
        maximumLatencyTask = nil
        debounceGeneration &+= 1
        eventWindowGeneration &+= 1
        let paths = pendingEventPaths.union(
            pendingEventRootProviders.compactMap { roots[$0] }
        )
        pendingEventPaths.removeAll()
        pendingEventRootProviders.removeAll()
        markFollowUpDirtyProviders(for: paths)
    }

    private nonisolated static func executeBatch(
        inputs: [WorkInput],
        failedProviders: Set<Provider>,
        scanner: any IngestionScanning,
        discovery: any LogDiscovering,
        calendar: Calendar
    ) async -> BatchExecution {
        let accumulator = ProgressAccumulator(failedProviders: failedProviders)
        do {
            let classified = try classify(inputs: inputs)
            for input in classified.recursive {
                try Task.checkCancellation()
                accumulator.ensure(provider: input.provider)
                do {
                    try await discovery.enumerateJSONLFiles(
                        under: input.url,
                        maximumChunkSize: maximumDiscoveryChunkSize
                    ) { files in
                        let uniqueFiles = Array(Set(files.map(\.standardizedFileURL)))
                            .sorted { $0.path < $1.path }
                        accumulator.addDiscovered(
                            uniqueFiles.count,
                            provider: input.provider
                        )
                        try await scan(
                            files: uniqueFiles,
                            provider: input.provider,
                            scanner: scanner,
                            calendar: calendar,
                            accumulator: accumulator
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    accumulator.markFailure(provider: input.provider)
                }
            }
            for input in classified.direct {
                try Task.checkCancellation()
                accumulator.ensure(provider: input.provider)
                accumulator.addDiscovered(1, provider: input.provider)
                try await scan(
                    files: [input.url],
                    provider: input.provider,
                    scanner: scanner,
                    calendar: calendar,
                    accumulator: accumulator
                )
            }
            return BatchExecution(progress: accumulator.snapshot(), wasCancelled: false)
        } catch is CancellationError {
            for provider in Set(inputs.map(\.provider)).union(failedProviders) {
                accumulator.markFailure(provider: provider)
            }
            return BatchExecution(progress: accumulator.snapshot(), wasCancelled: true)
        } catch {
            for provider in Set(inputs.map(\.provider)).union(failedProviders) {
                accumulator.markFailure(provider: provider)
            }
            return BatchExecution(progress: accumulator.snapshot(), wasCancelled: false)
        }
    }

    private nonisolated static func classify(
        inputs: [WorkInput]
    ) throws -> (recursive: [WorkInput], direct: [WorkInput]) {
        var recursive: [WorkInput] = []
        var direct: [WorkInput] = []
        for input in inputs {
            try Task.checkCancellation()
            guard hasNoSymbolicLinkBelowRoot(input.url, root: input.root) else {
                continue
            }
            if input.url == input.root {
                recursive.append(input)
                continue
            }
            let values = try? input.url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            guard values?.isSymbolicLink != true else { continue }
            if values?.isRegularFile == true,
               input.url.pathExtension.lowercased() == "jsonl" {
                direct.append(input)
            } else if values?.isDirectory == true {
                recursive.append(input)
            }
        }
        recursive = recursive.filter { candidate in
            !recursive.contains { other in
                other.provider == candidate.provider
                    && other.url != candidate.url
                    && candidate.url.pathComponents.starts(with: other.url.pathComponents)
            }
        }
        direct = direct.filter { candidate in
            !recursive.contains { directory in
                directory.provider == candidate.provider
                    && candidate.url.pathComponents.starts(with: directory.url.pathComponents)
            }
        }
        let order: (WorkInput, WorkInput) -> Bool = { lhs, rhs in
            if lhs.provider.rawValue != rhs.provider.rawValue {
                return lhs.provider.rawValue < rhs.provider.rawValue
            }
            return lhs.url.path < rhs.url.path
        }
        return (recursive.sorted(by: order), direct.sorted(by: order))
    }

    private nonisolated static func scan(
        files: [URL],
        provider: Provider,
        scanner: any IngestionScanning,
        calendar: Calendar,
        accumulator: ProgressAccumulator
    ) async throws {
        for file in files {
            try Task.checkCancellation()
            do {
                let outcome = try await scanner.scan(
                    file: file,
                    provider: provider,
                    calendar: calendar
                )
                accumulator.recordScan(
                    provider: provider,
                    outcome: outcome
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                accumulator.recordScanFailure(provider: provider)
            }
        }
    }

    private final class ProgressAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var progress: [Provider: ProviderProgress] = [:]

        init(failedProviders: Set<Provider>) {
            for provider in failedProviders {
                progress[provider] = ProviderProgress(severity: .failure)
            }
        }

        func ensure(provider: Provider) {
            lock.withLock {
                if progress[provider] == nil {
                    progress[provider] = ProviderProgress()
                }
            }
        }

        func addDiscovered(_ count: Int, provider: Provider) {
            lock.withLock {
                var value = progress[provider] ?? ProviderProgress()
                value.discoveredFiles += count
                progress[provider] = value
            }
        }

        func recordScan(provider: Provider, outcome: ScanOutcome) {
            lock.withLock {
                var value = progress[provider] ?? ProviderProgress()
                value.scannedFiles += 1
                value.skippedRecordCount += outcome.skippedRecords
                if let attention = outcome.attention {
                    value.attention.insert(attention)
                }
                if (outcome.attention != nil || outcome.skippedRecords > 0),
                   value.severity.rawValue < Severity.attention.rawValue {
                    value.severity = .attention
                }
                progress[provider] = value
            }
        }

        func recordScanFailure(provider: Provider) {
            lock.withLock {
                var value = progress[provider] ?? ProviderProgress()
                value.scannedFiles += 1
                value.severity = .failure
                progress[provider] = value
            }
        }

        func markFailure(provider: Provider) {
            lock.withLock {
                var value = progress[provider] ?? ProviderProgress()
                value.severity = .failure
                progress[provider] = value
            }
        }

        func snapshot() -> [Provider: ProviderProgress] {
            lock.withLock { progress }
        }
    }

    private func failRemainingBatches() {
        let batches = pendingBatches
        pendingBatches.removeAll()
        for queued in batches {
            nextSequence &+= 1
            let providers = Set(queued.inputs.map(\.provider))
                .union(queued.failedProviders)
            let failures = Dictionary(uniqueKeysWithValues: providers.map {
                ($0, ProviderIngestionResult.failure(discoveredFiles: 0, scannedFiles: 0))
            })
            let result = IngestionBatchResult(
                runID: queued.runID,
                sequence: nextSequence,
                scope: queued.scope,
                providers: failures
            )
            queued.continuations.forEach { $0.resume(returning: result) }
        }
    }

    private func providerAndRoot(containing url: URL) -> (Provider, URL)? {
        let standardized = url.standardizedFileURL
        return roots
            .filter { standardized.pathComponents.starts(with: $0.value.pathComponents) }
            .max { $0.value.pathComponents.count < $1.value.pathComponents.count }
            .map { ($0.key, $0.value) }
    }

    private nonisolated static func hasNoSymbolicLinkBelowRoot(
        _ url: URL,
        root: URL
    ) -> Bool {
        let rootComponents = root.pathComponents
        let components = url.pathComponents
        guard components.starts(with: rootComponents) else { return false }
        var current = root
        for component in components.dropFirst(rootComponents.count) {
            current.append(path: component)
            guard let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true else {
                return false
            }
        }
        return true
    }
}
