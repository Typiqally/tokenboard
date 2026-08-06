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

public struct IngestionBatchResult: Equatable, Sendable {
    public let runID: UInt64
    public let sequence: UInt64
    public let scope: IngestionBatchScope
    public let requiresInventoryRefresh: Bool
    public let providers: [Provider: ProviderIngestionResult]

    public init(
        runID: UInt64,
        sequence: UInt64,
        scope: IngestionBatchScope,
        requiresInventoryRefresh: Bool = false,
        providers: [Provider: ProviderIngestionResult]
    ) {
        self.runID = runID
        self.sequence = sequence
        self.scope = scope
        self.requiresInventoryRefresh = requiresInventoryRefresh
        self.providers = providers
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
        let roots = canonicalize(suppliedRoots)
        guard let claudeRoot = roots[.claudeCode],
              let codexRoot = roots[.codex],
              !contains(claudeRoot, codexRoot),
              !contains(codexRoot, claudeRoot) else {
            throw IngestionCoordinatorError.overlappingRoots
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
    static let maximumEventLatency = Duration.seconds(2)
    private static let eventDebounceDelay = Duration.milliseconds(750)

    private enum Severity: Int {
        case success
        case attention
        case failure
    }

    private struct ScanCandidate: Sendable {
        let url: URL
        let provider: Provider
    }

    private struct ProviderProgress {
        var discoveredFiles = 0
        var scannedFiles = 0
        var severity = Severity.success

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
    }

    private struct PreparedBatch {
        let runID: UInt64
        var candidates: [URL: ScanCandidate]
        var progress: [Provider: ProviderProgress]
    }

    private struct QueuedBatch {
        var batch: PreparedBatch
        let scope: IngestionBatchScope
        var continuations: [CheckedContinuation<IngestionBatchResult, Never>]
    }

    public nonisolated let usesPeriodicRefresh = false

    private let scanner: any IngestionScanning
    private let watcher: any SourceEventWatching
    private let clock: any IngestionClock
    private let discovery: any LogDiscovering
    private let calendar: Calendar
    private var roots: [Provider: URL] = [:]
    private var eventTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var maximumLatencyTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var stopBarrier: Task<Void, Never>?
    private var pendingEventPaths: Set<URL> = []
    private var pendingEventRootProviders: Set<Provider> = []
    private var followUpDirtyProviders: Set<Provider> = []
    private var pendingBatches: [QueuedBatch] = []
    private var activeBatchScope: IngestionBatchScope?
    private var activeBatchRunID: UInt64?
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
        let (stream, continuation) = AsyncStream<IngestionBatchResult>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.scanner = scanner
        self.watcher = watcher
        self.clock = clock
        self.discovery = discovery
        self.calendar = calendar
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
        startGeneration &+= 1
        let startID = startGeneration
        let canonicalRoots = try IngestionRootValidator.validate(suppliedRoots)

        await stopWithBarrier()
        guard startGeneration == startID else { throw CancellationError() }
        stopBarrier = nil
        runGeneration &+= 1
        let runID = runGeneration
        nextSequence = 0
        activeRunID = runID
        roots = canonicalRoots
        let orderedRoots = Provider.allCases.compactMap { roots[$0] }
        let events = watcher.events(for: orderedRoots)
        eventTask = Task { [weak self] in
            for await paths in events {
                guard !Task.isCancelled else { break }
                await self?.receive(paths: paths, runID: runID)
            }
        }
        let result = await refreshAll()
        guard startGeneration == startID,
              activeRunID == runID else { throw CancellationError() }
        return result
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
        return await enqueueInventoryAndWait(runID: runID)
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
        let tasks = [
            eventTask,
            debounceTask,
            maximumLatencyTask,
            drainTask
        ].compactMap { $0 }
        eventTask = nil
        debounceTask = nil
        maximumLatencyTask = nil
        drainTask = nil
        pendingEventPaths.removeAll()
        pendingEventRootProviders.removeAll()
        followUpDirtyProviders.removeAll()
        roots.removeAll()
        debounceGeneration &+= 1
        eventWindowGeneration &+= 1
        for task in tasks {
            await task.value
        }
        failRemainingBatches()
    }

    private func receive(paths: Set<URL>, runID: UInt64) {
        guard activeRunID == runID,
              roots.count == Provider.allCases.count else { return }
        mergePendingEventPaths(paths)
        debounceGeneration &+= 1
        let generation = debounceGeneration
        debounceTask?.cancel()
        debounceTask = Task { [weak self, clock] in
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
            maximumLatencyTask = Task { [weak self, clock] in
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
        if activeBatchScope == .incremental
            || pendingBatches.contains(where: { $0.scope == .incremental }) {
            markFollowUpDirtyProviders(for: paths)
            return
        }
        var batch = PreparedBatch(runID: runID, candidates: [:], progress: [:])
        for path in paths.sorted(by: { $0.path < $1.path }) {
            guard let (provider, root) = providerAndRoot(containing: path) else { continue }
            guard hasNoSymbolicLinkBelowRoot(path, root: root) else { continue }
            let values = try? path.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            if values?.isSymbolicLink == true {
                continue
            }
            if values?.isRegularFile == true, path.pathExtension.lowercased() == "jsonl" {
                add(files: [path], provider: provider, into: &batch)
            } else if values?.isDirectory == true || path == root {
                discover(root: path, provider: provider, into: &batch)
            }
        }
        guard !batch.progress.isEmpty else { return }
        enqueueEventBatch(batch)
    }

    private func markFollowUpDirtyProviders(for paths: Set<URL>) {
        for path in paths {
            if let (provider, _) = providerAndRoot(containing: path) {
                followUpDirtyProviders.insert(provider)
            }
        }
    }

    private func discover(
        root: URL,
        provider: Provider,
        into batch: inout PreparedBatch
    ) {
        do {
            add(files: try discovery.jsonlFiles(under: root), provider: provider, into: &batch)
        } catch {
            var progress = batch.progress[provider] ?? ProviderProgress()
            progress.severity = .failure
            batch.progress[provider] = progress
        }
    }

    private func add(
        files: [URL],
        provider: Provider,
        into batch: inout PreparedBatch
    ) {
        let standardized = Set(files.map(\.standardizedFileURL))
        var progress = batch.progress[provider] ?? ProviderProgress()
        let newFiles = standardized.filter { batch.candidates[$0] == nil }
        progress.discoveredFiles += newFiles.count
        batch.progress[provider] = progress
        for url in newFiles {
            batch.candidates[url] = ScanCandidate(url: url, provider: provider)
        }
    }

    private func enqueueInventoryAndWait(runID: UInt64) async -> IngestionBatchResult {
        await withCheckedContinuation { continuation in
            if activeBatchScope == .inventory,
               activeBatchRunID == runID {
                activeInventoryContinuations.append(continuation)
                return
            }
            if let index = pendingBatches.firstIndex(where: {
                $0.scope == .inventory && $0.batch.runID == runID
            }) {
                pendingBatches[index].continuations.append(continuation)
                return
            }
            var batch = PreparedBatch(runID: runID, candidates: [:], progress: [:])
            for provider in Provider.allCases {
                guard let root = roots[provider] else {
                    batch.progress[provider] = ProviderProgress(severity: .failure)
                    continue
                }
                discover(root: root, provider: provider, into: &batch)
            }
            pendingBatches.append(QueuedBatch(
                batch: batch,
                scope: .inventory,
                continuations: [continuation]
            ))
            startDrainIfNeeded()
        }
    }

    private func enqueueEventBatch(_ batch: PreparedBatch) {
        pendingBatches.append(QueuedBatch(
            batch: batch,
            scope: .incremental,
            continuations: []
        ))
        startDrainIfNeeded()
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil, !pendingBatches.isEmpty else { return }
        drainTask = Task { [weak self] in
            await self?.drainBatches()
        }
    }

    private func drainBatches() async {
        while !pendingBatches.isEmpty {
            var queued = pendingBatches.removeFirst()
            activeBatchScope = queued.scope
            activeBatchRunID = queued.batch.runID
            activeInventoryContinuations = queued.continuations
            let candidates = queued.batch.candidates.values.sorted { $0.url.path < $1.url.path }
            for candidate in candidates {
                guard !Task.isCancelled else {
                    markAllProvidersFailed(in: &queued.batch)
                    break
                }
                var progress = queued.batch.progress[candidate.provider] ?? ProviderProgress()
                progress.scannedFiles += 1
                do {
                    let outcome = try await scanner.scan(
                        file: candidate.url,
                        provider: candidate.provider,
                        calendar: calendar
                    )
                    if outcome.attention != nil,
                       progress.severity.rawValue < Severity.attention.rawValue {
                        progress.severity = .attention
                    }
                } catch {
                    progress.severity = .failure
                }
                queued.batch.progress[candidate.provider] = progress
            }
            nextSequence &+= 1
            let result = IngestionBatchResult(
                runID: queued.batch.runID,
                sequence: nextSequence,
                scope: queued.scope,
                providers: queued.batch.progress.mapValues(\.result)
            )
            let inventoryContinuations = activeInventoryContinuations
            activeInventoryContinuations.removeAll()
            activeBatchScope = nil
            activeBatchRunID = nil
            inventoryContinuations.forEach { $0.resume(returning: result) }
            if queued.scope == .incremental,
               activeRunID == queued.batch.runID,
               case .dropped = resultContinuation.yield(result) {
                nextSequence &+= 1
                resultContinuation.yield(IngestionBatchResult(
                    runID: queued.batch.runID,
                    sequence: nextSequence,
                    scope: .incremental,
                    requiresInventoryRefresh: true,
                    providers: [:]
                ))
            }
            if queued.scope == .incremental {
                enqueueFollowUpEventIfNeeded(runID: queued.batch.runID)
            }
        }
        drainTask = nil
    }

    private func enqueueFollowUpEventIfNeeded(runID: UInt64) {
        guard activeRunID == runID,
              !followUpDirtyProviders.isEmpty,
              !pendingBatches.contains(where: { $0.scope == .incremental }) else {
            return
        }
        let providers = followUpDirtyProviders
        followUpDirtyProviders.removeAll()
        var batch = PreparedBatch(runID: runID, candidates: [:], progress: [:])
        for provider in Provider.allCases where providers.contains(provider) {
            guard let root = roots[provider] else {
                batch.progress[provider] = ProviderProgress(severity: .failure)
                continue
            }
            discover(root: root, provider: provider, into: &batch)
        }
        guard !batch.progress.isEmpty else { return }
        enqueueEventBatch(batch)
    }

    private func markFailure(for provider: Provider, in batch: inout PreparedBatch) {
        var progress = batch.progress[provider] ?? ProviderProgress()
        progress.severity = .failure
        batch.progress[provider] = progress
    }

    private func markAllProvidersFailed(in batch: inout PreparedBatch) {
        for provider in Array(batch.progress.keys) {
            markFailure(for: provider, in: &batch)
        }
    }

    private func failRemainingBatches() {
        let batches = pendingBatches
        pendingBatches.removeAll()
        for queued in batches {
            nextSequence &+= 1
            let providers = queued.batch.progress.mapValues { progress in
                ProviderIngestionResult.failure(
                    discoveredFiles: progress.discoveredFiles,
                    scannedFiles: progress.scannedFiles
                )
            }
            let result = IngestionBatchResult(
                runID: queued.batch.runID,
                sequence: nextSequence,
                scope: queued.scope,
                providers: providers
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

    private func hasNoSymbolicLinkBelowRoot(_ url: URL, root: URL) -> Bool {
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
