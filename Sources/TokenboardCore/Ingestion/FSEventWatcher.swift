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
}

final class FSEventStreamHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var callbackContext: FSEventCallbackContext?
    fileprivate var nativeStream: FSEventStreamRef?

    init(
        callback: @escaping @Sendable ([FSEventDriverEvent]) -> Void,
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
    func deliver(_ events: [FSEventDriverEvent]) -> Bool {
        lock.withLock { callbackContext }?.deliver(events) ?? false
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
    private var callback: (@Sendable ([FSEventDriverEvent]) -> Void)?
    private let onRelease: @Sendable () -> Void
    private var activeDeliveries = 0

    init(
        callback: @escaping @Sendable ([FSEventDriverEvent]) -> Void,
        onRelease: @escaping @Sendable () -> Void
    ) {
        self.callback = callback
        self.onRelease = onRelease
    }

    @discardableResult
    func deliver(_ events: [FSEventDriverEvent]) -> Bool {
        condition.lock()
        guard let callback else {
            condition.unlock()
            return false
        }
        activeDeliveries += 1
        condition.unlock()

        callback(events)

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
    func create(
        configuration: FSEventStreamConfiguration,
        callback: @escaping @Sendable ([FSEventDriverEvent]) -> Void
    ) -> FSEventStreamHandle?
    func schedule(_ handle: FSEventStreamHandle, on queue: DispatchQueue)
    func start(_ handle: FSEventStreamHandle) -> Bool
    func stop(_ handle: FSEventStreamHandle)
    func invalidate(_ handle: FSEventStreamHandle)
    func release(_ handle: FSEventStreamHandle)
}

private struct NativeFSEventStreamDriver: FSEventStreamDriving {
    func create(
        configuration: FSEventStreamConfiguration,
        callback: @escaping @Sendable ([FSEventDriverEvent]) -> Void
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
        let nativeCallback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let callbackContext = Unmanaged<FSEventCallbackContext>
                .fromOpaque(info)
                .takeUnretainedValue()
            let pathValues = Unmanaged<CFArray>
                .fromOpaque(paths)
                .takeUnretainedValue() as NSArray
            var events: [FSEventDriverEvent] = []
            events.reserveCapacity(count)
            for index in 0..<count {
                guard let path = pathValues[index] as? String else { continue }
                events.append(FSEventDriverEvent(path: path, flags: UInt32(flags[index])))
            }
            if !events.isEmpty {
                callbackContext.deliver(events)
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
    private struct StreamState {
        let handle: FSEventStreamHandle
        let continuation: AsyncStream<Set<URL>>.Continuation
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.tokenboard.source-events")
    private let driver: any FSEventStreamDriving
    private var state: StreamState?

    public convenience init() {
        self.init(driver: NativeFSEventStreamDriver())
    }

    init(driver: any FSEventStreamDriving) {
        self.driver = driver
    }

    deinit {
        stop()
    }

    public func events(for roots: [URL]) -> AsyncStream<Set<URL>> {
        stop()
        let resolvedRoots = roots.map(\.standardizedFileURL)
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
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
            let configuration = FSEventStreamConfiguration(
                roots: resolvedRoots.map(\.path),
                sinceWhen: UInt64(kFSEventStreamEventIdSinceNow),
                latency: 0.5,
                flags: createFlags
            )
            guard let handle = driver.create(configuration: configuration, callback: { events in
                let changed = Self.changedURLs(from: events, roots: resolvedRoots)
                if !changed.isEmpty {
                    continuation.yield(changed)
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

    public func stop() {
        let priorState = lock.withLock { () -> StreamState? in
            defer { state = nil }
            return state
        }
        guard let priorState else { return }
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
            } else {
                changed.insert(eventURL)
            }
        }
        return changed
    }
}
