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

public struct IngestionBatchResult: Equatable, Sendable {
    public let runID: UInt64
    public let providers: [Provider: ProviderIngestionResult]

    public init(runID: UInt64, providers: [Provider: ProviderIngestionResult]) {
        self.runID = runID
        self.providers = providers
    }
}

public actor IngestionCoordinator {
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
        let isEventBatch: Bool
        let continuation: CheckedContinuation<IngestionBatchResult, Never>?
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
    private var drainTask: Task<Void, Never>?
    private var pendingEventPaths: Set<URL> = []
    private var pendingBatches: [QueuedBatch] = []
    private var debounceGeneration: UInt64 = 0
    private var runGeneration: UInt64 = 0
    private var startGeneration: UInt64 = 0
    private var activeRunID: UInt64?
    private var eventBatchHandler: (@Sendable (IngestionBatchResult) -> Void)?

    public init(
        scanner: any IngestionScanning,
        watcher: any SourceEventWatching = FSEventWatcher(),
        clock: any IngestionClock = ContinuousIngestionClock(),
        discovery: any LogDiscovering = LogDiscovery(),
        calendar: Calendar = .current
    ) {
        self.scanner = scanner
        self.watcher = watcher
        self.clock = clock
        self.discovery = discovery
        self.calendar = calendar
    }

    public func setEventBatchHandler(
        _ handler: (@Sendable (IngestionBatchResult) -> Void)?
    ) {
        eventBatchHandler = handler
    }

    public func start(roots suppliedRoots: [Provider: URL]) async throws -> IngestionBatchResult {
        startGeneration &+= 1
        let startID = startGeneration
        for provider in Provider.allCases where suppliedRoots[provider] == nil {
            throw IngestionCoordinatorError.missingRoot(provider)
        }
        let canonicalRoots = suppliedRoots.mapValues {
            let resolved = $0.standardizedFileURL.resolvingSymlinksInPath()
            return URL(fileURLWithPath: resolved.path).standardizedFileURL
        }
        guard let claudeRoot = canonicalRoots[.claudeCode],
              let codexRoot = canonicalRoots[.codex],
              !Self.contains(claudeRoot, codexRoot),
              !Self.contains(codexRoot, claudeRoot) else {
            throw IngestionCoordinatorError.overlappingRoots
        }

        await stopRuntime()
        guard startGeneration == startID else { throw CancellationError() }
        runGeneration &+= 1
        let runID = runGeneration
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
                providers: Dictionary(uniqueKeysWithValues: Provider.allCases.map {
                    ($0, .failure(discoveredFiles: 0, scannedFiles: 0))
                })
            )
        }
        var batch = PreparedBatch(runID: runID, candidates: [:], progress: [:])
        for provider in Provider.allCases {
            guard let root = roots[provider] else {
                batch.progress[provider] = ProviderProgress(severity: .failure)
                continue
            }
            discover(root: root, provider: provider, into: &batch)
        }
        return await enqueueAndWait(batch)
    }

    public func stop() async {
        startGeneration &+= 1
        await stopRuntime()
    }

    private func stopRuntime() async {
        runGeneration &+= 1
        activeRunID = nil
        watcher.stop()
        eventTask?.cancel()
        debounceTask?.cancel()
        drainTask?.cancel()
        let tasks = [eventTask, debounceTask, drainTask].compactMap { $0 }
        eventTask = nil
        debounceTask = nil
        drainTask = nil
        pendingEventPaths.removeAll()
        roots.removeAll()
        debounceGeneration &+= 1
        for task in tasks {
            await task.value
        }
        failRemainingBatches()
    }

    private func receive(paths: Set<URL>, runID: UInt64) {
        guard activeRunID == runID,
              roots.count == Provider.allCases.count else { return }
        pendingEventPaths.formUnion(paths.map(\.standardizedFileURL))
        debounceGeneration &+= 1
        let generation = debounceGeneration
        debounceTask?.cancel()
        debounceTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: .milliseconds(750))
                guard !Task.isCancelled else { return }
                await self?.debounceElapsed(generation: generation, runID: runID)
            } catch {
                return
            }
        }
    }

    private func debounceElapsed(generation: UInt64, runID: UInt64) {
        guard generation == debounceGeneration,
              activeRunID == runID else { return }
        let paths = pendingEventPaths
        pendingEventPaths.removeAll()
        debounceTask = nil
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

    private func enqueueAndWait(_ batch: PreparedBatch) async -> IngestionBatchResult {
        await withCheckedContinuation { continuation in
            pendingBatches.append(QueuedBatch(
                batch: batch,
                isEventBatch: false,
                continuation: continuation
            ))
            startDrainIfNeeded()
        }
    }

    private func enqueueEventBatch(_ batch: PreparedBatch) {
        pendingBatches.append(QueuedBatch(
            batch: batch,
            isEventBatch: true,
            continuation: nil
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
            let candidates = queued.batch.candidates.values.sorted { $0.url.path < $1.url.path }
            for candidate in candidates {
                guard !Task.isCancelled else {
                    markFailure(for: candidate.provider, in: &queued.batch)
                    continue
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
            let result = IngestionBatchResult(
                runID: queued.batch.runID,
                providers: queued.batch.progress.mapValues(\.result)
            )
            queued.continuation?.resume(returning: result)
            if queued.isEventBatch, activeRunID == queued.batch.runID {
                eventBatchHandler?(result)
            }
        }
        drainTask = nil
    }

    private func markFailure(for provider: Provider, in batch: inout PreparedBatch) {
        var progress = batch.progress[provider] ?? ProviderProgress()
        progress.severity = .failure
        batch.progress[provider] = progress
    }

    private func failRemainingBatches() {
        let batches = pendingBatches
        pendingBatches.removeAll()
        for queued in batches {
            let providers = queued.batch.progress.mapValues { progress in
                ProviderIngestionResult.failure(
                    discoveredFiles: progress.discoveredFiles,
                    scannedFiles: progress.scannedFiles
                )
            }
            queued.continuation?.resume(returning: IngestionBatchResult(
                runID: queued.batch.runID,
                providers: providers
            ))
        }
    }

    private func providerAndRoot(containing url: URL) -> (Provider, URL)? {
        let standardized = url.standardizedFileURL
        return roots
            .filter { standardized.pathComponents.starts(with: $0.value.pathComponents) }
            .max { $0.value.pathComponents.count < $1.value.pathComponents.count }
            .map { ($0.key, $0.value) }
    }

    private static func contains(_ root: URL, _ candidate: URL) -> Bool {
        candidate.pathComponents.starts(with: root.pathComponents)
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
