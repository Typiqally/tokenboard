import CoreServices
import Foundation
import XCTest
@testable import TokenboardCore

final class FSEventWatcherTests: XCTestCase {
    func testCreatesOneStreamWithExactConfigurationAndOrderedCleanup() {
        let driver = RecordingFSEventStreamDriver()
        let watcher = FSEventWatcher(driver: driver)
        let roots = [URL(fileURLWithPath: "/tmp/claude"), URL(fileURLWithPath: "/tmp/codex")]

        let stream = watcher.events(for: roots)

        let expectedFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        XCTAssertEqual(driver.createCount, 1)
        XCTAssertEqual(driver.configuration?.roots, roots.map(\.path))
        XCTAssertEqual(driver.configuration?.flags, expectedFlags)
        XCTAssertEqual(driver.configuration?.sinceWhen, UInt64(kFSEventStreamEventIdSinceNow))
        XCTAssertEqual(driver.configuration?.latency, 0.5)
        XCTAssertEqual(driver.operations, [.schedule, .start(true)])
        XCTAssertTrue(driver.callbackContextIsAlive)

        watcher.stop()
        watcher.stop()

        XCTAssertEqual(
            driver.operations,
            [.schedule, .start(true), .stop, .invalidate, .release]
        )
        XCTAssertEqual(driver.callbackLivenessAtOperation, [true, true, true, true, true])
        XCTAssertFalse(driver.callbackContextIsAlive)
        XCTAssertEqual(driver.callbackReleaseCount, 1)
        XCTAssertEqual(driver.operationCountsAtCallbackRelease, [5])
        withExtendedLifetime(stream) {}
    }

    func testDeliverySucceedsBeforeCleanupAndIsRejectedAfterRelease() async {
        let driver = RecordingFSEventStreamDriver()
        let watcher = FSEventWatcher(driver: driver)
        let root = URL(fileURLWithPath: "/tmp/claude").standardizedFileURL
        let stream = watcher.events(for: [root])
        var iterator = stream.makeAsyncIterator()

        let delivered = driver.emit([
            FSEventDriverEvent(
                path: root.appending(path: "renamed").path,
                flags: UInt32(kFSEventStreamEventFlagRootChanged)
            )
        ])

        XCTAssertTrue(delivered)
        let received = await iterator.next()
        XCTAssertEqual(received, [root])

        watcher.stop()

        XCTAssertFalse(driver.callbackContextIsAlive)
        XCTAssertEqual(driver.callbackReleaseCount, 1)
        XCTAssertEqual(driver.operationCountsAtCallbackRelease, [5])
        XCTAssertFalse(driver.emit([FSEventDriverEvent(path: root.path, flags: 0)]))
    }

    func testBufferedDeliveryFallsBackToBoundedRootRescanWhenConsumerFallsBehind() async {
        let driver = RecordingFSEventStreamDriver()
        let watcher = FSEventWatcher(driver: driver)
        let root = URL(fileURLWithPath: "/tmp/claude").standardizedFileURL
        let first = root.appending(path: "first.jsonl")
        let second = root.appending(path: "second.jsonl")
        let stream = watcher.events(for: [root])

        XCTAssertTrue(driver.emit([FSEventDriverEvent(path: first.path, flags: 0)]))
        XCTAssertTrue(driver.emit([FSEventDriverEvent(path: second.path, flags: 0)]))

        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        XCTAssertEqual(received, Set([root]))
        watcher.stop()
    }

    func testSingleCallbackAbovePathCapCollapsesToWatchedRoots() async {
        let driver = RecordingFSEventStreamDriver()
        let watcher = FSEventWatcher(driver: driver)
        let roots = [
            URL(fileURLWithPath: "/tmp/claude").standardizedFileURL,
            URL(fileURLWithPath: "/tmp/codex").standardizedFileURL
        ]
        let stream = watcher.events(for: roots)
        let events = (0..<1_000).map { index in
            FSEventDriverEvent(
                path: roots[index % roots.count]
                    .appending(path: "session-\(index).jsonl").path,
                flags: 0
            )
        }

        XCTAssertTrue(driver.emit(events))

        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        XCTAssertEqual(received, Set(roots))
        watcher.stop()
    }

    func testRootSignalAtPathCapCollapsesToAllWatchedRoots() async {
        let driver = RecordingFSEventStreamDriver()
        let watcher = FSEventWatcher(driver: driver)
        let roots = [
            URL(fileURLWithPath: "/tmp/claude").standardizedFileURL,
            URL(fileURLWithPath: "/tmp/codex").standardizedFileURL
        ]
        let stream = watcher.events(for: roots)
        var events = (0..<64).map { index in
            FSEventDriverEvent(
                path: roots[index % roots.count]
                    .appending(path: "session-\(index).jsonl").path,
                flags: 0
            )
        }
        events.append(FSEventDriverEvent(
            path: roots[0].path,
            flags: UInt32(kFSEventStreamEventFlagRootChanged)
        ))

        XCTAssertTrue(driver.emit(events))

        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        XCTAssertEqual(received, Set(roots))
        watcher.stop()
    }

    func testStartFailureUsesFailureCleanupOrderAndReleasesCallbackOnce() async {
        let driver = RecordingFSEventStreamDriver(startResult: false)
        let watcher = FSEventWatcher(driver: driver)
        let stream = watcher.events(for: [URL(fileURLWithPath: "/tmp/claude")])
        var iterator = stream.makeAsyncIterator()

        let received = await iterator.next()
        XCTAssertEqual(received, nil)
        XCTAssertEqual(driver.operations, [.schedule, .start(false), .invalidate, .release])
        XCTAssertEqual(driver.callbackLivenessAtOperation, [true, true, true, true])
        XCTAssertFalse(driver.operations.contains(.stop))
        XCTAssertFalse(driver.callbackContextIsAlive)
        XCTAssertEqual(driver.callbackReleaseCount, 1)
        XCTAssertEqual(driver.operationCountsAtCallbackRelease, [4])
        XCTAssertFalse(driver.emit([FSEventDriverEvent(path: "/tmp/claude", flags: 0)]))

        watcher.stop()
        XCTAssertEqual(driver.operations, [.schedule, .start(false), .invalidate, .release])
        XCTAssertEqual(driver.callbackReleaseCount, 1)
    }

    func testStreamTerminationCleansUpOnceWithoutReordering() async {
        let driver = RecordingFSEventStreamDriver()
        let watcher = FSEventWatcher(driver: driver)
        let stream = watcher.events(for: [URL(fileURLWithPath: "/tmp/claude")])
        let consumer = Task {
            for await _ in stream {}
        }

        consumer.cancel()
        await consumer.value
        watcher.stop()

        XCTAssertEqual(
            driver.operations,
            [.schedule, .start(true), .stop, .invalidate, .release]
        )
        XCTAssertEqual(driver.callbackLivenessAtOperation, [true, true, true, true, true])
        XCTAssertFalse(driver.callbackContextIsAlive)
        XCTAssertEqual(driver.callbackReleaseCount, 1)
        XCTAssertEqual(driver.operationCountsAtCallbackRelease, [5])
    }
}

private final class RecordingFSEventStreamDriver: FSEventStreamDriving, @unchecked Sendable {
    enum Operation: Equatable {
        case schedule
        case start(Bool)
        case stop
        case invalidate
        case release
    }

    private let lock = NSLock()
    private let startResult: Bool
    private var handle: FSEventStreamHandle?
    private var recordedOperations: [Operation] = []
    private var recordedCallbackLiveness: [Bool] = []
    private var recordedCallbackReleaseCount = 0
    private var recordedOperationCountsAtCallbackRelease: [Int] = []
    private var recordedConfiguration: FSEventStreamConfiguration?
    private var recordedCreateCount = 0

    init(startResult: Bool = true) {
        self.startResult = startResult
    }

    var configuration: FSEventStreamConfiguration? { lock.withLock { recordedConfiguration } }
    var createCount: Int { lock.withLock { recordedCreateCount } }
    var operations: [Operation] { lock.withLock { recordedOperations } }
    var callbackLivenessAtOperation: [Bool] { lock.withLock { recordedCallbackLiveness } }
    var callbackReleaseCount: Int { lock.withLock { recordedCallbackReleaseCount } }
    var operationCountsAtCallbackRelease: [Int] {
        lock.withLock { recordedOperationCountsAtCallbackRelease }
    }
    var callbackContextIsAlive: Bool {
        lock.withLock { handle }?.hasLiveCallbackContext ?? false
    }

    func create(
        configuration: FSEventStreamConfiguration,
        callback: @escaping @Sendable ([FSEventDriverEvent]) -> Void
    ) -> FSEventStreamHandle? {
        lock.withLock {
            recordedCreateCount += 1
            recordedConfiguration = configuration
            let handle = FSEventStreamHandle(callback: callback, onCallbackRelease: { [weak self] in
                guard let self else { return }
                self.lock.withLock {
                    self.recordedCallbackReleaseCount += 1
                    self.recordedOperationCountsAtCallbackRelease.append(self.recordedOperations.count)
                }
            })
            self.handle = handle
            return handle
        }
    }

    func schedule(_ handle: FSEventStreamHandle, on queue: DispatchQueue) {
        record(.schedule, handle: handle)
    }

    func start(_ handle: FSEventStreamHandle) -> Bool {
        record(.start(startResult), handle: handle)
        return startResult
    }

    func stop(_ handle: FSEventStreamHandle) {
        record(.stop, handle: handle)
    }

    func invalidate(_ handle: FSEventStreamHandle) {
        record(.invalidate, handle: handle)
    }

    func release(_ handle: FSEventStreamHandle) {
        record(.release, handle: handle)
    }

    func emit(_ events: [FSEventDriverEvent]) -> Bool {
        lock.withLock { handle }?.deliver(events) ?? false
    }

    private func record(_ operation: Operation, handle: FSEventStreamHandle) {
        let callbackIsAlive = handle.hasLiveCallbackContext
        lock.withLock {
            recordedOperations.append(operation)
            recordedCallbackLiveness.append(callbackIsAlive)
        }
    }
}
