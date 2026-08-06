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
    private let callback: @Sendable ([FSEventDriverEvent]) -> Void
    fileprivate var nativeStream: FSEventStreamRef?
    fileprivate var callbackInfo: UnsafeMutableRawPointer?

    init(callback: @escaping @Sendable ([FSEventDriverEvent]) -> Void) {
        self.callback = callback
    }

    func deliver(_ events: [FSEventDriverEvent]) {
        callback(events)
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

private final class NativeFSEventCallbackBox: @unchecked Sendable {
    let callback: @Sendable ([FSEventDriverEvent]) -> Void

    init(callback: @escaping @Sendable ([FSEventDriverEvent]) -> Void) {
        self.callback = callback
    }

    func receive(
        count: Int,
        pathsPointer: UnsafeMutableRawPointer,
        flags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        let paths = Unmanaged<CFArray>.fromOpaque(pathsPointer).takeUnretainedValue() as NSArray
        var events: [FSEventDriverEvent] = []
        events.reserveCapacity(count)
        for index in 0..<count {
            guard let path = paths[index] as? String else { continue }
            events.append(FSEventDriverEvent(path: path, flags: UInt32(flags[index])))
        }
        if !events.isEmpty {
            callback(events)
        }
    }
}

private struct NativeFSEventStreamDriver: FSEventStreamDriving {
    func create(
        configuration: FSEventStreamConfiguration,
        callback: @escaping @Sendable ([FSEventDriverEvent]) -> Void
    ) -> FSEventStreamHandle? {
        let callbackBox = NativeFSEventCallbackBox(callback: callback)
        let callbackInfo = Unmanaged.passRetained(callbackBox).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: callbackInfo,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let nativeCallback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            Unmanaged<NativeFSEventCallbackBox>.fromOpaque(info).takeUnretainedValue().receive(
                count: count,
                pathsPointer: paths,
                flags: flags
            )
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
            Unmanaged<NativeFSEventCallbackBox>.fromOpaque(callbackInfo).release()
            return nil
        }
        let handle = FSEventStreamHandle(callback: callback)
        handle.nativeStream = stream
        handle.callbackInfo = callbackInfo
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
        if let callbackInfo = handle.callbackInfo {
            Unmanaged<NativeFSEventCallbackBox>.fromOpaque(callbackInfo).release()
            handle.callbackInfo = nil
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
