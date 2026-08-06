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

public final class FSEventWatcher: SourceEventWatching, @unchecked Sendable {
    static let maximumChangedPaths = 64

    private struct StreamState {
        let handle: FSEventStreamHandle
        let continuation: AsyncStream<SourceEventBatch>.Continuation
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.tokenboard.source-events")
    private let driver: any FSEventStreamDriving
    private var state: StreamState?
    private var baselineEventID: UInt64?
    private var lastAcknowledgedEventID: UInt64?

    public convenience init() {
        self.init(driver: NativeFSEventStreamDriver())
    }

    init(driver: any FSEventStreamDriving) {
        self.driver = driver
    }

    deinit {
        stop()
    }

    public func events(for roots: [URL]) -> AsyncStream<SourceEventBatch> {
        stop()
        let resolvedRoots = roots.map(\.standardizedFileURL)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            guard !resolvedRoots.isEmpty else {
                continuation.finish()
                return
            }

            let createFlags = UInt32(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagNoDefer
            )
            let sinceWhen = lock.withLock { () -> UInt64 in
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
            guard let handle = driver.create(configuration: configuration, callback: { batch in
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
                    let checkpoint = batch.terminalEventID.map {
                        SourceEventCheckpoint(eventID: $0)
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
                return
            }

            let started = lock.withLock {
                driver.schedule(handle, on: queue)
                guard driver.start(handle) else { return false }
                state = StreamState(handle: handle, continuation: continuation)
                return true
            }
            guard started else {
                driver.invalidate(handle)
                driver.release(handle)
                handle.releaseCallbackContext()
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }
    }

    public func acknowledge(_ checkpoint: SourceEventCheckpoint?) {
        guard let checkpoint else { return }
        lock.withLock {
            if checkpoint.eventID >= (lastAcknowledgedEventID ?? baselineEventID ?? 0) {
                lastAcknowledgedEventID = checkpoint.eventID
            }
        }
    }

    public func stop() {
        let priorState = lock.withLock { () -> StreamState? in
            defer { state = nil }
            return state
        }
        guard let priorState else { return }
        driver.flushSync(priorState.handle)
        driver.stop(priorState.handle)
        driver.invalidate(priorState.handle)
        driver.release(priorState.handle)
        priorState.handle.releaseCallbackContext()
        priorState.continuation.finish()
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
