import CoreServices
import Foundation

struct FSEventStreamConfiguration: Equatable, Sendable {
    let roots: [String]
    let sinceWhen: UInt64
    let latency: TimeInterval
    let flags: UInt32
}

struct FSEventDriverEvent: Equatable, Sendable {
    let path: String
    let flags: UInt32
    let eventID: UInt64

    init(path: String, flags: UInt32, eventID: UInt64 = 0) {
        self.path = path
        self.flags = flags
        self.eventID = eventID
    }
}

struct FSEventDriverBatch: Equatable, Sendable {
    let events: [FSEventDriverEvent]
    let overflowed: Bool
    let highestConsumedEventID: UInt64?
    let terminalEventID: UInt64?
}

enum NativeFSEventBatchConverter {
    static func convert(
        count: Int,
        maximumEvents: Int,
        pathAt: (Int) -> String?,
        flagsAt: (Int) -> UInt32,
        eventIDAt: (Int) -> UInt64
    ) -> FSEventDriverBatch {
        let boundedMaximum = max(0, maximumEvents)
        let accessorLimit = boundedMaximum == Int.max
            ? count
            : min(count, boundedMaximum + 1)
        var events: [FSEventDriverEvent] = []
        events.reserveCapacity(boundedMaximum)
        var highestConsumedEventID: UInt64?
        for index in 0..<accessorLimit {
            let path = pathAt(index)
            let flags = flagsAt(index)
            let eventID = eventIDAt(index)
            highestConsumedEventID = max(highestConsumedEventID ?? eventID, eventID)
            if index < boundedMaximum, let path {
                events.append(FSEventDriverEvent(
                    path: path,
                    flags: flags,
                    eventID: eventID
                ))
            }
        }
        let terminalEventID: UInt64?
        if count > accessorLimit {
            terminalEventID = eventIDAt(count - 1)
        } else {
            terminalEventID = highestConsumedEventID
        }
        return FSEventDriverBatch(
            events: events,
            overflowed: count > boundedMaximum,
            highestConsumedEventID: highestConsumedEventID,
            terminalEventID: terminalEventID
        )
    }
}

final class FSEventStreamHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var callbackContext: FSEventCallbackContext?
    fileprivate var nativeStream: FSEventStreamRef?

    init(
        callback: @escaping @Sendable (FSEventDriverBatch) -> Void,
        onCallbackRelease: @escaping @Sendable () -> Void = {}
    ) {
        callbackContext = FSEventCallbackContext(
            callback: callback,
            onRelease: onCallbackRelease
        )
    }

    var hasLiveCallbackContext: Bool {
        lock.withLock { callbackContext != nil }
    }

    @discardableResult
    func deliver(_ batch: FSEventDriverBatch) -> Bool {
        lock.withLock { callbackContext }?.deliver(batch) ?? false
    }

    fileprivate var callbackInfo: UnsafeMutableRawPointer? {
        lock.withLock { callbackContext }.map { Unmanaged.passUnretained($0).toOpaque() }
    }

    fileprivate func releaseCallbackContext() {
        let context = lock.withLock { () -> FSEventCallbackContext? in
            defer { callbackContext = nil }
            return callbackContext
        }
        context?.release()
    }
}

private final class FSEventCallbackContext: @unchecked Sendable {
    private let condition = NSCondition()
    private var callback: (@Sendable (FSEventDriverBatch) -> Void)?
    private let onRelease: @Sendable () -> Void
    private var activeDeliveries = 0

    init(
        callback: @escaping @Sendable (FSEventDriverBatch) -> Void,
        onRelease: @escaping @Sendable () -> Void
    ) {
        self.callback = callback
        self.onRelease = onRelease
    }

    @discardableResult
    func deliver(_ batch: FSEventDriverBatch) -> Bool {
        condition.lock()
        guard let callback else {
            condition.unlock()
            return false
        }
        activeDeliveries += 1
        condition.unlock()

        callback(batch)

        condition.lock()
        activeDeliveries -= 1
        if activeDeliveries == 0 {
            condition.broadcast()
        }
        condition.unlock()
        return true
    }

    func release() {
        condition.lock()
        guard callback != nil else {
            condition.unlock()
            return
        }
        callback = nil
        while activeDeliveries > 0 {
            condition.wait()
        }
        condition.unlock()
        onRelease()
    }
}

protocol FSEventStreamDriving: Sendable {
    func currentEventID() -> UInt64
    func create(
        configuration: FSEventStreamConfiguration,
        callback: @escaping @Sendable (FSEventDriverBatch) -> Void
    ) -> FSEventStreamHandle?
    func schedule(_ handle: FSEventStreamHandle, on queue: DispatchQueue)
    func start(_ handle: FSEventStreamHandle) -> Bool
    func flushSync(_ handle: FSEventStreamHandle)
    func stop(_ handle: FSEventStreamHandle)
    func invalidate(_ handle: FSEventStreamHandle)
    func release(_ handle: FSEventStreamHandle)
}

private struct NativeFSEventStreamDriver: FSEventStreamDriving {
    func currentEventID() -> UInt64 {
        UInt64(FSEventsGetCurrentEventId())
    }

    func create(
        configuration: FSEventStreamConfiguration,
        callback: @escaping @Sendable (FSEventDriverBatch) -> Void
    ) -> FSEventStreamHandle? {
        let handle = FSEventStreamHandle(callback: callback)
        guard let callbackInfo = handle.callbackInfo else { return nil }
        var context = FSEventStreamContext(
            version: 0,
            info: callbackInfo,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let nativeCallback: FSEventStreamCallback = { _, info, count, paths, flags, eventIDs in
            guard let info else { return }
            let callbackContext = Unmanaged<FSEventCallbackContext>
                .fromOpaque(info)
                .takeUnretainedValue()
            let pathValues = Unmanaged<CFArray>
                .fromOpaque(paths)
                .takeUnretainedValue()
            let batch = NativeFSEventBatchConverter.convert(
                count: count,
                maximumEvents: FSEventWatcher.maximumChangedPaths,
                pathAt: { index in
                    guard let value = CFArrayGetValueAtIndex(pathValues, index) else {
                        return nil
                    }
                    return Unmanaged<CFString>
                        .fromOpaque(value)
                        .takeUnretainedValue() as String
                },
                flagsAt: { UInt32(flags[$0]) },
                eventIDAt: { UInt64(eventIDs[$0]) }
            )
            if !batch.events.isEmpty || batch.overflowed {
                callbackContext.deliver(batch)
            }
        }
        guard let stream = FSEventStreamCreate(
            nil,
            nativeCallback,
            &context,
            configuration.roots as CFArray,
            FSEventStreamEventId(configuration.sinceWhen),
            configuration.latency,
            FSEventStreamCreateFlags(configuration.flags)
        ) else {
            handle.releaseCallbackContext()
            return nil
        }
        handle.nativeStream = stream
        return handle
    }

    func schedule(_ handle: FSEventStreamHandle, on queue: DispatchQueue) {
        guard let stream = handle.nativeStream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
    }

    func start(_ handle: FSEventStreamHandle) -> Bool {
        guard let stream = handle.nativeStream else { return false }
        return FSEventStreamStart(stream)
    }

    func flushSync(_ handle: FSEventStreamHandle) {
        guard let stream = handle.nativeStream else { return }
        FSEventStreamFlushSync(stream)
    }

    func stop(_ handle: FSEventStreamHandle) {
        guard let stream = handle.nativeStream else { return }
        FSEventStreamStop(stream)
    }

    func invalidate(_ handle: FSEventStreamHandle) {
        guard let stream = handle.nativeStream else { return }
        FSEventStreamInvalidate(stream)
    }

    func release(_ handle: FSEventStreamHandle) {
        if let stream = handle.nativeStream {
            FSEventStreamRelease(stream)
            handle.nativeStream = nil
        }
    }
}

public enum FSEventWatcherError: Error, Equatable, Sendable {
    case emptyRoots
    case couldNotCreateStream
    case couldNotStartStream
}

public final class FSEventWatcher: SourceEventWatching, @unchecked Sendable {
    static let maximumChangedPaths = 64
    static let productionRecentReconciliationInterval = DispatchTimeInterval.seconds(5)
    static let productionFullReconciliationInterval = DispatchTimeInterval.seconds(15 * 60)
    static let maximumRecentReconciliationFiles = 64
    private static let reconciledFileResourceKeys: Set<URLResourceKey> = [
        .contentModificationDateKey,
        .fileSizeKey,
        .isRegularFileKey,
        .isSymbolicLinkKey
    ]

    struct ReconciledFileState: Equatable, Sendable {
        let size: Int
        let modificationDate: Date?
    }

    struct ReconciliationFileSystem: Sendable {
        let inventory: @Sendable ([URL]) -> [URL: ReconciledFileState]
        let metadata: @Sendable (Set<URL>) -> [(URL, ReconciledFileState?)]

        static let live = ReconciliationFileSystem(
            inventory: { FSEventWatcher.reconciledFiles(under: $0) },
            metadata: { FSEventWatcher.reconciledStates(for: $0) }
        )
    }

    private final class ReconciliationSnapshot: @unchecked Sendable {
        private let lock = NSLock()
        private let maximumRecentFileCount: Int
        private let roots: [URL]
        private var files: [URL: ReconciledFileState]
        private var recentFiles: [URL]

        init(
            files: [URL: ReconciledFileState],
            roots: [URL],
            maximumRecentFileCount: Int
        ) {
            self.maximumRecentFileCount = maximumRecentFileCount
            self.roots = roots
            self.files = files
            recentFiles = FSEventWatcher.mostRecentFiles(
                in: files,
                roots: roots,
                limit: maximumRecentFileCount
            )
        }

        func recentFileURLs() -> [URL] {
            lock.withLock { recentFiles }
        }

        func recordNativeChanges(_ states: [(URL, ReconciledFileState?)]) {
            lock.withLock {
                var shouldRefillRecentFiles = false
                for (url, state) in states {
                    guard let state else {
                        removeFile(at: url)
                        shouldRefillRecentFiles = recentFiles.contains(url)
                            || shouldRefillRecentFiles
                        recentFiles.removeAll { $0 == url }
                        continue
                    }
                    files[url] = state
                    promote(url)
                }
                if shouldRefillRecentFiles {
                    refillRecentFiles()
                }
            }
        }

        func applyRecentStates(
            _ states: [(URL, ReconciledFileState?)],
            roots: [URL]
        ) -> Set<URL> {
            lock.withLock {
                var changed: Set<URL> = []
                var removedFile = false
                var shouldRefillRecentFiles = false
                for (url, state) in states {
                    guard let state else {
                        if removeFile(at: url) {
                            removedFile = true
                        }
                        shouldRefillRecentFiles = recentFiles.contains(url)
                            || shouldRefillRecentFiles
                        recentFiles.removeAll { $0 == url }
                        continue
                    }
                    let previousState = files[url]
                    if previousState != state {
                        changed.insert(url)
                        promote(url)
                    }
                    files[url] = state
                }
                if shouldRefillRecentFiles {
                    refillRecentFiles()
                }
                return removedFile ? Set(roots) : changed
            }
        }

        func replaceAll(
            with nextFiles: [URL: ReconciledFileState],
            roots: [URL]
        ) -> Set<URL> {
            lock.withLock {
                let changed = FSEventWatcher.changedReconciledURLs(
                    from: files,
                    to: nextFiles,
                    roots: roots
                )
                files = nextFiles
                refillRecentFiles()
                return changed
            }
        }

        private func promote(_ url: URL) {
            recentFiles.removeAll { $0 == url }
            recentFiles.insert(url, at: 0)
            guard recentFiles.count > maximumRecentFileCount else { return }

            var counts: [Int: Int] = [:]
            for recentFile in recentFiles {
                guard let rootIndex = FSEventWatcher.rootIndex(
                    containing: recentFile,
                    roots: roots
                ) else { continue }
                counts[rootIndex, default: 0] += 1
            }
            let activeRootIndices = Set(counts.keys)
            let minimumPerRoot = activeRootIndices.isEmpty
                ? 0
                : maximumRecentFileCount / activeRootIndices.count
            let promotedRoot = FSEventWatcher.rootIndex(containing: url, roots: roots)
            let rootToTrim = promotedRoot.flatMap { index in
                (counts[index, default: 0] > minimumPerRoot) ? index : nil
            } ?? counts
                .filter { $0.value > minimumPerRoot }
                .max { lhs, rhs in lhs.value < rhs.value }?
                .key
            if let rootToTrim,
               let removalIndex = recentFiles.lastIndex(where: {
                   FSEventWatcher.rootIndex(containing: $0, roots: roots) == rootToTrim
               }) {
                recentFiles.remove(at: removalIndex)
            } else {
                recentFiles.removeLast()
            }
        }

        @discardableResult
        private func removeFile(at url: URL) -> Bool {
            files.removeValue(forKey: url) != nil
        }

        private func refillRecentFiles() {
            recentFiles = FSEventWatcher.mostRecentFiles(
                in: files,
                roots: roots,
                limit: maximumRecentFileCount
            )
        }
    }

    private struct StreamState {
        let handle: FSEventStreamHandle
        let continuation: AsyncStream<SourceEventBatch>.Continuation
        let reconciliationSources: [any DispatchSourceTimer]
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "com.tokenboard.source-events",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )
    private let driver: any FSEventStreamDriving
    private let recentReconciliationInterval: DispatchTimeInterval?
    private let fullReconciliationInterval: DispatchTimeInterval?
    private let maximumRecentFileCount: Int
    private let reconciliationFileSystem: ReconciliationFileSystem
    private var state: StreamState?
    private var baselineEventID: UInt64?
    private var lastAcknowledgedEventID: UInt64?
    private var checkpointResetPending = false

    public convenience init() {
        self.init(
            driver: NativeFSEventStreamDriver(),
            recentReconciliationInterval: Self.productionRecentReconciliationInterval,
            fullReconciliationInterval: Self.productionFullReconciliationInterval,
            maximumRecentFileCount: Self.maximumRecentReconciliationFiles,
            reconciliationFileSystem: .live
        )
    }

    convenience init(driver: any FSEventStreamDriving) {
        self.init(
            driver: driver,
            recentReconciliationInterval: nil,
            fullReconciliationInterval: nil,
            maximumRecentFileCount: Self.maximumRecentReconciliationFiles,
            reconciliationFileSystem: .live
        )
    }

    convenience init(
        driver: any FSEventStreamDriving,
        reconciliationInterval: DispatchTimeInterval?
    ) {
        self.init(
            driver: driver,
            recentReconciliationInterval: nil,
            fullReconciliationInterval: reconciliationInterval,
            maximumRecentFileCount: Self.maximumRecentReconciliationFiles,
            reconciliationFileSystem: .live
        )
    }

    init(
        driver: any FSEventStreamDriving,
        recentReconciliationInterval: DispatchTimeInterval?,
        fullReconciliationInterval: DispatchTimeInterval?,
        maximumRecentFileCount: Int,
        reconciliationFileSystem: ReconciliationFileSystem = .live
    ) {
        precondition(maximumRecentFileCount > 0)
        self.driver = driver
        self.recentReconciliationInterval = recentReconciliationInterval
        self.fullReconciliationInterval = fullReconciliationInterval
        self.maximumRecentFileCount = maximumRecentFileCount
        self.reconciliationFileSystem = reconciliationFileSystem
    }

    deinit {
        stop()
    }

    public func start(roots: [URL]) throws -> AsyncStream<SourceEventBatch> {
        stop()
        let resolvedRoots = roots.map(\.standardizedFileURL)
        guard !resolvedRoots.isEmpty else { throw FSEventWatcherError.emptyRoots }
        let (stream, continuation) = AsyncStream<SourceEventBatch>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let createFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        let sinceWhen = lock.withLock { () -> UInt64 in
            if checkpointResetPending {
                let current = driver.currentEventID()
                return current > 0
                    ? current
                    : UInt64(kFSEventStreamEventIdSinceNow)
            }
            if let lastAcknowledgedEventID { return lastAcknowledgedEventID }
            if let baselineEventID { return baselineEventID }
            let current = driver.currentEventID()
            baselineEventID = current
            return current
        }
        let configuration = FSEventStreamConfiguration(
            roots: resolvedRoots.map(\.path),
            sinceWhen: sinceWhen,
            latency: 0.5,
            flags: createFlags
        )
        let reconciliationSnapshot: ReconciliationSnapshot? = if recentReconciliationInterval != nil
            || fullReconciliationInterval != nil {
            ReconciliationSnapshot(
                files: reconciliationFileSystem.inventory(resolvedRoots),
                roots: resolvedRoots,
                maximumRecentFileCount: maximumRecentFileCount
            )
        } else {
            nil
        }
        guard let handle = driver.create(configuration: configuration, callback: { [weak self] batch in
            guard let self else { return }
            let eventIDsWrapped = batch.events.contains { event in
                event.flags & UInt32(kFSEventStreamEventFlagEventIdsWrapped) != 0
            }
            let requiresRootRecovery = batch.overflowed || batch.events.contains { event in
                event.flags & UInt32(
                    kFSEventStreamEventFlagMustScanSubDirs
                        | kFSEventStreamEventFlagUserDropped
                        | kFSEventStreamEventFlagKernelDropped
                        | kFSEventStreamEventFlagEventIdsWrapped
                ) != 0
            }
            let changed = requiresRootRecovery
                ? Set(resolvedRoots)
                : Self.changedURLs(from: batch.events, roots: resolvedRoots)
            if !changed.isEmpty {
                reconciliationSnapshot?.recordNativeChanges(
                    reconciliationFileSystem.metadata(changed)
                )
                let terminalEventID = eventIDsWrapped
                    ? driver.currentEventID()
                    : batch.terminalEventID
                let checkpoint = terminalEventID.flatMap {
                    self.checkpoint(
                        eventID: $0,
                        eventIDsWrapped: eventIDsWrapped
                    )
                }
                let delivery = SourceEventBatch(
                    paths: changed,
                    checkpoint: checkpoint
                )
                if case .dropped = continuation.yield(delivery) {
                    continuation.yield(SourceEventBatch(
                        paths: Set(resolvedRoots),
                        checkpoint: checkpoint
                    ))
                }
            }
        }) else {
            continuation.finish()
            throw FSEventWatcherError.couldNotCreateStream
        }

        let started = lock.withLock {
            driver.schedule(handle, on: queue)
            guard driver.start(handle) else { return false }
            var reconciliationSources: [any DispatchSourceTimer] = []
            if let snapshot = reconciliationSnapshot,
               let interval = recentReconciliationInterval {
                let source = makeTimer(interval: interval)
                source.setEventHandler { [weak self] in
                    self?.reconcileRecentChanges(
                        roots: resolvedRoots,
                        snapshot: snapshot,
                        handle: handle,
                        continuation: continuation
                    )
                }
                reconciliationSources.append(source)
            }
            if let snapshot = reconciliationSnapshot,
               let interval = fullReconciliationInterval {
                let source = makeTimer(interval: interval)
                source.setEventHandler { [weak self] in
                    self?.reconcileAllChanges(
                        roots: resolvedRoots,
                        snapshot: snapshot,
                        handle: handle,
                        continuation: continuation
                    )
                }
                reconciliationSources.append(source)
            }
            state = StreamState(
                handle: handle,
                continuation: continuation,
                reconciliationSources: reconciliationSources
            )
            reconciliationSources.forEach { $0.activate() }
            return true
        }
        guard started else {
            driver.invalidate(handle)
            driver.release(handle)
            handle.releaseCallbackContext()
            continuation.finish()
            throw FSEventWatcherError.couldNotStartStream
        }
        continuation.onTermination = { [weak self] _ in
            self?.stop()
        }
        return stream
    }

    public func acknowledge(_ checkpoint: SourceEventCheckpoint?) {
        guard let checkpoint else { return }
        lock.withLock {
            switch checkpoint.disposition {
            case .advance:
                guard checkpoint.eventID >= (lastAcknowledgedEventID ?? baselineEventID ?? 0) else {
                    return
                }
                lastAcknowledgedEventID = checkpoint.eventID
            case .reset:
                baselineEventID = checkpoint.eventID
                lastAcknowledgedEventID = checkpoint.eventID
                checkpointResetPending = false
            }
        }
    }

    public func stop() {
        let priorState = lock.withLock { () -> StreamState? in
            defer { state = nil }
            return state
        }
        guard let priorState else { return }
        priorState.reconciliationSources.forEach { $0.cancel() }
        driver.flushSync(priorState.handle)
        driver.stop(priorState.handle)
        driver.invalidate(priorState.handle)
        driver.release(priorState.handle)
        priorState.handle.releaseCallbackContext()
        priorState.continuation.finish()
    }

    private func makeTimer(interval: DispatchTimeInterval) -> any DispatchSourceTimer {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(100)
        )
        return source
    }

    private func reconcileRecentChanges(
        roots: [URL],
        snapshot: ReconciliationSnapshot,
        handle: FSEventStreamHandle,
        continuation: AsyncStream<SourceEventBatch>.Continuation
    ) {
        guard lock.withLock({ state?.handle === handle }) else { return }
        let states = reconciliationFileSystem.metadata(Set(snapshot.recentFileURLs()))
        guard lock.withLock({ state?.handle === handle }) else { return }
        let changed = snapshot.applyRecentStates(states, roots: roots)
        yieldReconciledChanges(
            changed,
            roots: roots,
            continuation: continuation
        )
    }

    private func reconcileAllChanges(
        roots: [URL],
        snapshot: ReconciliationSnapshot,
        handle: FSEventStreamHandle,
        continuation: AsyncStream<SourceEventBatch>.Continuation
    ) {
        guard lock.withLock({ state?.handle === handle }) else { return }
        let nextFiles = reconciliationFileSystem.inventory(roots)
        guard lock.withLock({ state?.handle === handle }) else { return }
        let changed = snapshot.replaceAll(with: nextFiles, roots: roots)
        yieldReconciledChanges(
            changed,
            roots: roots,
            continuation: continuation
        )
    }

    private func yieldReconciledChanges(
        _ changed: Set<URL>,
        roots: [URL],
        continuation: AsyncStream<SourceEventBatch>.Continuation
    ) {
        guard !changed.isEmpty else { return }
        if case .dropped = continuation.yield(SourceEventBatch(
            paths: changed,
            checkpoint: nil
        )) {
            continuation.yield(SourceEventBatch(
                paths: Set(roots),
                checkpoint: nil
            ))
        }
    }

    private static func reconciledStates(
        for urls: Set<URL>
    ) -> [(URL, ReconciledFileState?)] {
        urls.compactMap { url in
            guard url.pathExtension.lowercased() == "jsonl" else { return nil }
            return (url.standardizedFileURL, reconciledFileState(at: url))
        }
    }

    private static func reconciledFileState(at url: URL) -> ReconciledFileState? {
        guard let values = try? url.resourceValues(forKeys: reconciledFileResourceKeys),
              values.isSymbolicLink != true,
              values.isRegularFile == true else {
            return nil
        }
        return ReconciledFileState(
            size: values.fileSize ?? 0,
            modificationDate: values.contentModificationDate
        )
    }

    private static func reconciledFiles(
        under roots: [URL]
    ) -> [URL: ReconciledFileState] {
        var files: [URL: ReconciledFileState] = [:]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(reconciledFileResourceKeys),
                options: [],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension.lowercased() == "jsonl",
                      let state = reconciledFileState(at: url) else {
                    continue
                }
                files[url.standardizedFileURL] = state
            }
        }
        return files
    }

    private static func mostRecentFiles(
        in files: [URL: ReconciledFileState],
        roots: [URL],
        limit: Int
    ) -> [URL] {
        let sortedFiles = files.sorted { lhs, rhs in
            let lhsDate = lhs.value.modificationDate ?? .distantPast
            let rhsDate = rhs.value.modificationDate ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.key.path < rhs.key.path
        }
        guard limit > 0 else { return [] }

        var filesByRoot = Array(repeating: [URL](), count: roots.count)
        for (url, _) in sortedFiles {
            guard let rootIndex = rootIndex(containing: url, roots: roots) else { continue }
            filesByRoot[rootIndex].append(url)
        }
        let nonemptyRootIndices = filesByRoot.indices.filter {
            !filesByRoot[$0].isEmpty
        }
        guard !nonemptyRootIndices.isEmpty else {
            return sortedFiles.prefix(limit).map(\.key)
        }

        let minimumPerRoot = limit / nonemptyRootIndices.count
        let remainder = limit % nonemptyRootIndices.count
        var selected: [URL] = []
        var selectedSet: Set<URL> = []
        for (position, rootIndex) in nonemptyRootIndices.enumerated() {
            let allocation = minimumPerRoot + (position < remainder ? 1 : 0)
            for url in filesByRoot[rootIndex].prefix(allocation) {
                selected.append(url)
                selectedSet.insert(url)
            }
        }
        if selected.count < limit {
            for (url, _) in sortedFiles where !selectedSet.contains(url) {
                selected.append(url)
                if selected.count == limit { break }
            }
        }
        return selected
    }

    private static func rootIndex(containing url: URL, roots: [URL]) -> Int? {
        roots.indices
            .filter { url.pathComponents.starts(with: roots[$0].pathComponents) }
            .max { roots[$0].pathComponents.count < roots[$1].pathComponents.count }
    }

    private static func changedReconciledURLs(
        from previous: [URL: ReconciledFileState],
        to current: [URL: ReconciledFileState],
        roots: [URL]
    ) -> Set<URL> {
        if previous.keys.contains(where: { current[$0] == nil }) {
            return Set(roots)
        }
        var changed: Set<URL> = []
        for (url, state) in current where previous[url] != state {
            changed.insert(url)
            if changed.count > maximumChangedPaths {
                return Set(roots)
            }
        }
        return changed
    }

    private func checkpoint(
        eventID: UInt64,
        eventIDsWrapped: Bool
    ) -> SourceEventCheckpoint? {
        lock.withLock {
            let prior = lastAcknowledgedEventID ?? baselineEventID
            if eventIDsWrapped {
                checkpointResetPending = true
            }
            if checkpointResetPending {
                guard eventID > 0 else { return nil }
                return SourceEventCheckpoint(eventID: eventID, disposition: .reset)
            }
            guard eventID > 0 else {
                guard let prior, prior > 0 else { return nil }
                return SourceEventCheckpoint(eventID: prior)
            }
            return SourceEventCheckpoint(
                eventID: eventID,
                disposition: .advance
            )
        }
    }

    private static func changedURLs(
        from events: [FSEventDriverEvent],
        roots: [URL]
    ) -> Set<URL> {
        var changed: Set<URL> = []
        for event in events {
            let ignored = event.flags & UInt32(
                kFSEventStreamEventFlagHistoryDone | kFSEventStreamEventFlagEventIdsWrapped
            )
            guard ignored == 0 else { continue }
            let eventURL = URL(fileURLWithPath: event.path).standardizedFileURL
            if event.flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                let matchingRoots = roots.filter {
                    eventURL == $0 || eventURL.pathComponents.starts(with: $0.pathComponents)
                }
                changed.formUnion(matchingRoots.isEmpty ? roots : matchingRoots)
                if changed.count > maximumChangedPaths { return Set(roots) }
            } else {
                if !changed.contains(eventURL),
                   changed.count == maximumChangedPaths {
                    return Set(roots)
                }
                changed.insert(eventURL)
            }
        }
        return changed
    }
}
