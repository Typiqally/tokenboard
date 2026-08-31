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
    private static let productionReconciliationInterval = DispatchTimeInterval.seconds(5)

    private struct ReconciledFileState: Equatable, Sendable {
        let size: Int
        let modificationDate: Date?
    }

    private final class ReconciliationSnapshot: @unchecked Sendable {
        var files: [URL: ReconciledFileState]

        init(files: [URL: ReconciledFileState]) {
            self.files = files
        }
    }

    private struct StreamState {
        let handle: FSEventStreamHandle
        let continuation: AsyncStream<SourceEventBatch>.Continuation
        let reconciliationSource: (any DispatchSourceTimer)?
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.tokenboard.source-events")
    private let driver: any FSEventStreamDriving
    private let reconciliationInterval: DispatchTimeInterval?
    private var state: StreamState?
    private var baselineEventID: UInt64?
    private var lastAcknowledgedEventID: UInt64?
    private var checkpointResetPending = false

    public convenience init() {
        self.init(
            driver: NativeFSEventStreamDriver(),
            reconciliationInterval: Self.productionReconciliationInterval
        )
    }

    convenience init(driver: any FSEventStreamDriving) {
        self.init(driver: driver, reconciliationInterval: nil)
    }

    init(
        driver: any FSEventStreamDriving,
        reconciliationInterval: DispatchTimeInterval?
    ) {
        self.driver = driver
        self.reconciliationInterval = reconciliationInterval
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
        let reconciliationSnapshot = reconciliationInterval.map { _ in
            ReconciliationSnapshot(files: Self.reconciledFiles(under: resolvedRoots))
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

        let reconciliationSource = reconciliationInterval.flatMap { interval in
            reconciliationSnapshot.map { snapshot in
                let source = DispatchSource.makeTimerSource(queue: queue)
                source.schedule(
                    deadline: .now() + interval,
                    repeating: interval,
                    leeway: .milliseconds(100)
                )
                source.setEventHandler { [weak self] in
                    self?.reconcileChanges(
                        roots: resolvedRoots,
                        snapshot: snapshot,
                        handle: handle,
                        continuation: continuation
                    )
                }
                return source
            }
        }

        let started = lock.withLock {
            driver.schedule(handle, on: queue)
            guard driver.start(handle) else { return false }
            state = StreamState(
                handle: handle,
                continuation: continuation,
                reconciliationSource: reconciliationSource
            )
            reconciliationSource?.activate()
            return true
        }
        guard started else {
            reconciliationSource?.cancel()
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
        priorState.reconciliationSource?.cancel()
        driver.flushSync(priorState.handle)
        driver.stop(priorState.handle)
        driver.invalidate(priorState.handle)
        driver.release(priorState.handle)
        priorState.handle.releaseCallbackContext()
        priorState.continuation.finish()
    }

    private func reconcileChanges(
        roots: [URL],
        snapshot: ReconciliationSnapshot,
        handle: FSEventStreamHandle,
        continuation: AsyncStream<SourceEventBatch>.Continuation
    ) {
        guard lock.withLock({ state?.handle === handle }) else { return }
        let nextFiles = Self.reconciledFiles(under: roots)
        guard lock.withLock({ state?.handle === handle }) else { return }
        let changed = Self.changedReconciledURLs(
            from: snapshot.files,
            to: nextFiles,
            roots: roots
        )
        snapshot.files = nextFiles
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

    private static func reconciledFiles(
        under roots: [URL]
    ) -> [URL: ReconciledFileState] {
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        var files: [URL: ReconciledFileState] = [:]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension.lowercased() == "jsonl",
                      let values = try? url.resourceValues(forKeys: resourceKeys),
                      values.isSymbolicLink != true,
                      values.isRegularFile == true else {
                    continue
                }
                files[url.standardizedFileURL] = ReconciledFileState(
                    size: values.fileSize ?? 0,
                    modificationDate: values.contentModificationDate
                )
            }
        }
        return files
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
