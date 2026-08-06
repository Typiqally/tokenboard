import CoreServices
import Foundation

public final class FSEventWatcher: SourceEventWatching, @unchecked Sendable {
    private struct StreamState {
        let stream: FSEventStreamRef
        let callbackInfo: UnsafeMutableRawPointer
        let continuation: AsyncStream<Set<URL>>.Continuation
    }

    private final class CallbackBox: @unchecked Sendable {
        let roots: [URL]
        let continuation: AsyncStream<Set<URL>>.Continuation

        init(roots: [URL], continuation: AsyncStream<Set<URL>>.Continuation) {
            self.roots = roots
            self.continuation = continuation
        }

        func receive(
            count: Int,
            pathsPointer: UnsafeMutableRawPointer,
            flags: UnsafePointer<FSEventStreamEventFlags>
        ) {
            let array = Unmanaged<CFArray>.fromOpaque(pathsPointer).takeUnretainedValue() as NSArray
            var changed: Set<URL> = []
            for index in 0..<count {
                let eventFlags = flags[index]
                let ignored = eventFlags & (
                    FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
                        | FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
                )
                guard ignored == 0, let path = array[index] as? String else { continue }
                let eventURL = URL(fileURLWithPath: path).standardizedFileURL
                if eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                    let matchingRoots = roots.filter {
                        eventURL == $0 || eventURL.pathComponents.starts(with: $0.pathComponents)
                    }
                    changed.formUnion(matchingRoots.isEmpty ? roots : matchingRoots)
                } else {
                    changed.insert(eventURL)
                }
            }
            if !changed.isEmpty {
                continuation.yield(changed)
            }
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.tokenboard.source-events")
    private var state: StreamState?

    public init() {}

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

            let box = CallbackBox(roots: resolvedRoots, continuation: continuation)
            let callbackInfo = Unmanaged.passRetained(box).toOpaque()
            var context = FSEventStreamContext(
                version: 0,
                info: callbackInfo,
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue().receive(
                    count: count,
                    pathsPointer: paths,
                    flags: flags
                )
            }
            let createFlags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagNoDefer
            )
            guard let stream = FSEventStreamCreate(
                nil,
                callback,
                &context,
                resolvedRoots.map(\.path) as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.5,
                createFlags
            ) else {
                Unmanaged<CallbackBox>.fromOpaque(callbackInfo).release()
                continuation.finish()
                return
            }

            let started = lock.withLock {
                FSEventStreamSetDispatchQueue(stream, queue)
                guard FSEventStreamStart(stream) else { return false }
                state = StreamState(
                    stream: stream,
                    callbackInfo: callbackInfo,
                    continuation: continuation
                )
                return true
            }
            guard started else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                Unmanaged<CallbackBox>.fromOpaque(callbackInfo).release()
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
        FSEventStreamStop(priorState.stream)
        FSEventStreamInvalidate(priorState.stream)
        FSEventStreamRelease(priorState.stream)
        Unmanaged<CallbackBox>.fromOpaque(priorState.callbackInfo).release()
        priorState.continuation.finish()
    }
}
