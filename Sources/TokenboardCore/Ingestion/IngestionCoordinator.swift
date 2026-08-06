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
}

public actor IngestionCoordinator {
    private struct ScanCandidate: Sendable {
        let url: URL
        let provider: Provider
    }

    public nonisolated let usesPeriodicRefresh = false

    private let scanner: any IngestionScanning
    private let watcher: any SourceEventWatching
    private let clock: any IngestionClock
    private let discovery: LogDiscovery
    private let calendar: Calendar
    private var roots: [Provider: URL] = [:]
    private var eventTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var pendingEventPaths: Set<URL> = []
    private var pendingScans: [URL: ScanCandidate] = [:]
    private var scanWaiters: [CheckedContinuation<Void, Never>] = []
    private var debounceGeneration = 0

    public init(
        scanner: any IngestionScanning,
        watcher: any SourceEventWatching = FSEventWatcher(),
        clock: any IngestionClock = ContinuousIngestionClock(),
        discovery: LogDiscovery = LogDiscovery(),
        calendar: Calendar = .current
    ) {
        self.scanner = scanner
        self.watcher = watcher
        self.clock = clock
        self.discovery = discovery
        self.calendar = calendar
    }

    public func start(roots suppliedRoots: [Provider: URL]) async throws {
        for provider in Provider.allCases where suppliedRoots[provider] == nil {
            throw IngestionCoordinatorError.missingRoot(provider)
        }
        await stop()
        roots = suppliedRoots.mapValues(\.standardizedFileURL)
        let orderedRoots = Provider.allCases.compactMap { roots[$0] }
        let events = watcher.events(for: orderedRoots)
        eventTask = Task { [weak self] in
            for await paths in events {
                guard !Task.isCancelled else { break }
                await self?.receive(paths: paths)
            }
        }
        await refreshAll()
    }

    public func refreshAll() async {
        var candidates: [ScanCandidate] = []
        for provider in Provider.allCases {
            guard let root = roots[provider] else { continue }
            guard let files = try? discovery.jsonlFiles(under: root) else { continue }
            candidates.append(contentsOf: files.map { ScanCandidate(url: $0, provider: provider) })
        }
        await enqueue(candidates, waitUntilDrained: true)
    }

    public func stop() async {
        watcher.stop()
        eventTask?.cancel()
        debounceTask?.cancel()
        scanTask?.cancel()
        let tasks = [eventTask, debounceTask, scanTask].compactMap { $0 }
        eventTask = nil
        debounceTask = nil
        scanTask = nil
        pendingEventPaths.removeAll()
        pendingScans.removeAll()
        roots.removeAll()
        debounceGeneration += 1
        for task in tasks {
            await task.value
        }
        resumeScanWaiters()
    }

    private func receive(paths: Set<URL>) {
        guard roots.count == Provider.allCases.count else { return }
        pendingEventPaths.formUnion(paths.map(\.standardizedFileURL))
        debounceGeneration += 1
        let generation = debounceGeneration
        debounceTask?.cancel()
        debounceTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: .milliseconds(750))
                guard !Task.isCancelled else { return }
                await self?.debounceElapsed(generation: generation)
            } catch {
                return
            }
        }
    }

    private func debounceElapsed(generation: Int) async {
        guard generation == debounceGeneration else { return }
        let paths = pendingEventPaths
        pendingEventPaths.removeAll()
        debounceTask = nil
        var candidates: [ScanCandidate] = []
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
                candidates.append(ScanCandidate(url: path, provider: provider))
            } else if values?.isDirectory == true,
                      let files = try? discovery.jsonlFiles(under: path) {
                candidates.append(contentsOf: files.map {
                    ScanCandidate(url: $0, provider: provider)
                })
            } else if path == root,
                      let files = try? discovery.jsonlFiles(under: root) {
                candidates.append(contentsOf: files.map {
                    ScanCandidate(url: $0, provider: provider)
                })
            }
        }
        await enqueue(candidates, waitUntilDrained: false)
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

    private func enqueue(_ candidates: [ScanCandidate], waitUntilDrained: Bool) async {
        for candidate in candidates {
            pendingScans[candidate.url] = candidate
        }
        startScanLoopIfNeeded()
        if waitUntilDrained, scanTask != nil {
            await withCheckedContinuation { continuation in
                scanWaiters.append(continuation)
            }
        }
    }

    private func startScanLoopIfNeeded() {
        guard scanTask == nil, !pendingScans.isEmpty else { return }
        scanTask = Task { [weak self] in
            await self?.drainScans()
        }
    }

    private func drainScans() async {
        while !Task.isCancelled, !pendingScans.isEmpty {
            let batch = pendingScans.values.sorted { $0.url.path < $1.url.path }
            pendingScans.removeAll()
            for candidate in batch {
                guard !Task.isCancelled else { break }
                _ = try? await scanner.scan(
                    file: candidate.url,
                    provider: candidate.provider,
                    calendar: calendar
                )
            }
        }
        scanTask = nil
        if !pendingScans.isEmpty {
            startScanLoopIfNeeded()
        } else {
            resumeScanWaiters()
        }
    }

    private func resumeScanWaiters() {
        let waiters = scanWaiters
        scanWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
