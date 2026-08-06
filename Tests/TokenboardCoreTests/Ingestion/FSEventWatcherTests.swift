import CoreServices
import Foundation
import XCTest
@testable import TokenboardCore

final class FSEventWatcherTests: XCTestCase {
    func testLazyNativeConversionReadsAndRetainsOnlyBoundedPrefixOnOverflow() {
        let source = LazyNativeEventSource(logicalCount: 1_000_000)

        let batch = NativeFSEventBatchConverter.convert(
            count: source.logicalCount,
            maximumEvents: FSEventWatcher.maximumChangedPaths,
            pathAt: source.path(at:),
            flagsAt: source.flags(at:),
            eventIDAt: source.eventID(at:)
        )

        XCTAssertTrue(batch.overflowed)
        XCTAssertEqual(batch.events.count, 64)
        XCTAssertEqual(batch.events.first?.path, "/tmp/claude/session-0.jsonl")
        XCTAssertEqual(batch.events.last?.path, "/tmp/codex/session-63.jsonl")
        XCTAssertEqual(batch.highestConsumedEventID, 10_064)
        XCTAssertEqual(source.pathReads, Array(0...64))
        XCTAssertEqual(source.flagReads, Array(0...64))
        XCTAssertEqual(source.eventIDReads, Array(0...64) + [999_999])
    }

    func testOverflowCarriesTerminalCheckpointWithoutReadingUnboundedPathsOrFlags() {
        let source = LazyNativeEventSource(logicalCount: 1_000_000)

        let batch = NativeFSEventBatchConverter.convert(
            count: source.logicalCount,
            maximumEvents: FSEventWatcher.maximumChangedPaths,
            pathAt: source.path(at:),
            flagsAt: source.flags(at:),
            eventIDAt: source.eventID(at:)
        )

        XCTAssertEqual(batch.terminalEventID, 1_009_999)
        XCTAssertEqual(source.pathReads, Array(0...64))
        XCTAssertEqual(source.flagReads, Array(0...64))
        XCTAssertEqual(source.eventIDReads, Array(0...64) + [999_999])
    }

    func testLazyNativeConversionPreservesExactCapUnicodeFlagsAndEventIDs() {
        let source = LazyNativeEventSource(
            logicalCount: FSEventWatcher.maximumChangedPaths,
            unicodeIndex: 17,
            rootChangedIndex: 63
        )

        let batch = NativeFSEventBatchConverter.convert(
            count: source.logicalCount,
            maximumEvents: FSEventWatcher.maximumChangedPaths,
            pathAt: source.path(at:),
            flagsAt: source.flags(at:),
            eventIDAt: source.eventID(at:)
        )

        XCTAssertFalse(batch.overflowed)
        XCTAssertEqual(batch.events.count, 64)
        XCTAssertEqual(batch.events[17].path, "/tmp/codex/日本語-é-17.jsonl")
        XCTAssertEqual(
            batch.events[63].flags,
            UInt32(kFSEventStreamEventFlagRootChanged)
        )
        XCTAssertEqual(batch.events[63].eventID, 10_063)
        XCTAssertEqual(batch.highestConsumedEventID, 10_063)
        XCTAssertEqual(source.pathReads, Array(0..<64))
        XCTAssertEqual(source.flagReads, Array(0..<64))
        XCTAssertEqual(source.eventIDReads, Array(0..<64))
    }

    func testLazyNativeCapPlusRootChangeOverflowsToBothWatchedRoots() async {
        let driver = RecordingFSEventStreamDriver()
        let watcher = FSEventWatcher(driver: driver)
        let roots = [
            URL(fileURLWithPath: "/tmp/claude").standardizedFileURL,
            URL(fileURLWithPath: "/tmp/codex").standardizedFileURL
        ]
        let stream = watcher.events(for: roots)
        let source = LazyNativeEventSource(
            logicalCount: FSEventWatcher.maximumChangedPaths + 1,
            rootChangedIndex: FSEventWatcher.maximumChangedPaths
        )
        let batch = NativeFSEventBatchConverter.convert(
            count: source.logicalCount,
            maximumEvents: FSEventWatcher.maximumChangedPaths,
            pathAt: source.path(at:),
            flagsAt: source.flags(at:),
            eventIDAt: source.eventID(at:)
        )

        XCTAssertTrue(driver.emit(batch))

        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        XCTAssertEqual(received?.paths, Set(roots))
        XCTAssertEqual(batch.events.count, 64)
        XCTAssertEqual(batch.highestConsumedEventID, 10_064)
        XCTAssertEqual(source.pathReads.count, 65)
        XCTAssertEqual(source.flagReads.count, 65)
        XCTAssertEqual(source.eventIDReads.count, 65)
        watcher.stop()
    }

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
        XCTAssertEqual(driver.configuration?.sinceWhen, 0)
        XCTAssertEqual(driver.configuration?.latency, 0.5)
        XCTAssertEqual(driver.operations, [.schedule, .start(true)])
        XCTAssertTrue(driver.callbackContextIsAlive)

        watcher.stop()
        watcher.stop()

        XCTAssertEqual(
            driver.operations,
            [.schedule, .start(true), .flushSync, .stop, .invalidate, .release]
        )
        XCTAssertEqual(driver.callbackLivenessAtOperation, [true, true, true, true, true, true])
        XCTAssertFalse(driver.callbackContextIsAlive)
        XCTAssertEqual(driver.callbackReleaseCount, 1)
        XCTAssertEqual(driver.operationCountsAtCallbackRelease, [6])
        withExtendedLifetime(stream) {}
    }

    func testReconfigurationStartsAtLastAcknowledgedContiguousCheckpoint() async {
        let driver = RecordingFSEventStreamDriver(currentEventID: 900)
        let watcher = FSEventWatcher(driver: driver)
        let root = URL(fileURLWithPath: "/tmp/claude").standardizedFileURL
        let firstStream = watcher.events(for: [root])
        var firstIterator = firstStream.makeAsyncIterator()
        XCTAssertTrue(driver.emit([
            FSEventDriverEvent(path: root.appending(path: "one.jsonl").path, flags: 0, eventID: 901)
        ]))
        let first = await firstIterator.next()
        XCTAssertEqual(first?.paths, [root.appending(path: "one.jsonl")])
        watcher.acknowledge(first?.checkpoint)

        let secondStream = watcher.events(for: [root])
        withExtendedLifetime(secondStream) {}

        XCTAssertEqual(driver.configurations.map(\.sinceWhen), [900, 901])
        watcher.stop()
    }

    func testUnacknowledgedDeliveryIsReplayedAcrossReconfiguration() async {
        let driver = RecordingFSEventStreamDriver(currentEventID: 40)
        let watcher = FSEventWatcher(driver: driver)
        let root = URL(fileURLWithPath: "/tmp/codex").standardizedFileURL
        let firstStream = watcher.events(for: [root])
        XCTAssertTrue(driver.emit([
            FSEventDriverEvent(path: root.appending(path: "gap.jsonl").path, flags: 0, eventID: 41)
        ]))
        withExtendedLifetime(firstStream) {}

        let secondStream = watcher.events(for: [root])
        withExtendedLifetime(secondStream) {}

        XCTAssertEqual(driver.configurations.map(\.sinceWhen), [40, 40])
        watcher.stop()
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
        XCTAssertEqual(received?.paths, [root])

        watcher.stop()

        XCTAssertFalse(driver.callbackContextIsAlive)
        XCTAssertEqual(driver.callbackReleaseCount, 1)
        XCTAssertEqual(driver.operationCountsAtCallbackRelease, [6])
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
        XCTAssertEqual(received?.paths, Set([root]))
        watcher.stop()
    }

    func testDroppedBufferedDeliveryRetainsTerminalCheckpointThroughRootRecovery() async {
        let driver = RecordingFSEventStreamDriver(currentEventID: 100)
        let watcher = FSEventWatcher(driver: driver)
        let root = URL(fileURLWithPath: "/tmp/claude").standardizedFileURL
        let stream = watcher.events(for: [root])

        XCTAssertTrue(driver.emit([
            FSEventDriverEvent(
                path: root.appending(path: "first.jsonl").path,
                flags: 0,
                eventID: 101
            )
        ]))
        XCTAssertTrue(driver.emit([
            FSEventDriverEvent(
                path: root.appending(path: "second.jsonl").path,
                flags: 0,
                eventID: 102
            )
        ]))

        var iterator = stream.makeAsyncIterator()
        let recovered = await iterator.next()
        XCTAssertEqual(recovered?.paths, [root])
        XCTAssertEqual(recovered?.checkpoint, SourceEventCheckpoint(eventID: 102))
        watcher.acknowledge(recovered?.checkpoint)

        let resumed = watcher.events(for: [root])
        withExtendedLifetime(resumed) {}
        XCTAssertEqual(driver.configurations.map(\.sinceWhen), [100, 102])
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
        XCTAssertEqual(received?.paths, Set(roots))
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
        XCTAssertEqual(received?.paths, Set(roots))
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
            [.schedule, .start(true), .flushSync, .stop, .invalidate, .release]
        )
        XCTAssertEqual(driver.callbackLivenessAtOperation, [true, true, true, true, true, true])
        XCTAssertFalse(driver.callbackContextIsAlive)
        XCTAssertEqual(driver.callbackReleaseCount, 1)
        XCTAssertEqual(driver.operationCountsAtCallbackRelease, [6])
    }
}

private final class LazyNativeEventSource {
    let logicalCount: Int
    private let unicodeIndex: Int?
    private let rootChangedIndex: Int?
    private(set) var pathReads: [Int] = []
    private(set) var flagReads: [Int] = []
    private(set) var eventIDReads: [Int] = []

    init(
        logicalCount: Int,
        unicodeIndex: Int? = nil,
        rootChangedIndex: Int? = nil
    ) {
        self.logicalCount = logicalCount
        self.unicodeIndex = unicodeIndex
        self.rootChangedIndex = rootChangedIndex
    }

    func path(at index: Int) -> String? {
        pathReads.append(index)
        let root = index.isMultiple(of: 2) ? "/tmp/claude" : "/tmp/codex"
        if index == unicodeIndex {
            return "\(root)/日本語-é-\(index).jsonl"
        }
        if index == rootChangedIndex { return root }
        return "\(root)/session-\(index).jsonl"
    }

    func flags(at index: Int) -> UInt32 {
        flagReads.append(index)
        return index == rootChangedIndex
            ? UInt32(kFSEventStreamEventFlagRootChanged)
            : 0
    }

    func eventID(at index: Int) -> UInt64 {
        eventIDReads.append(index)
        return UInt64(10_000 + index)
    }
}

private final class RecordingFSEventStreamDriver: FSEventStreamDriving, @unchecked Sendable {
    enum Operation: Equatable {
        case schedule
        case start(Bool)
        case flushSync
        case stop
        case invalidate
        case release
    }

    private let lock = NSLock()
    private let startResult: Bool
    private let recordedCurrentEventID: UInt64
    private var handle: FSEventStreamHandle?
    private var recordedOperations: [Operation] = []
    private var recordedCallbackLiveness: [Bool] = []
    private var recordedCallbackReleaseCount = 0
    private var recordedOperationCountsAtCallbackRelease: [Int] = []
    private var recordedConfigurations: [FSEventStreamConfiguration] = []
    private var recordedCreateCount = 0

    init(startResult: Bool = true, currentEventID: UInt64 = 0) {
        self.startResult = startResult
        recordedCurrentEventID = currentEventID
    }

    var configuration: FSEventStreamConfiguration? { lock.withLock { recordedConfigurations.last } }
    var configurations: [FSEventStreamConfiguration] { lock.withLock { recordedConfigurations } }
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

    func currentEventID() -> UInt64 { recordedCurrentEventID }

    func create(
        configuration: FSEventStreamConfiguration,
        callback: @escaping @Sendable (FSEventDriverBatch) -> Void
    ) -> FSEventStreamHandle? {
        lock.withLock {
            recordedCreateCount += 1
            recordedConfigurations.append(configuration)
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

    func flushSync(_ handle: FSEventStreamHandle) {
        record(.flushSync, handle: handle)
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
        emit(FSEventDriverBatch(
            events: events,
            overflowed: false,
            highestConsumedEventID: events.map(\.eventID).max(),
            terminalEventID: events.last?.eventID
        ))
    }

    func emit(_ batch: FSEventDriverBatch) -> Bool {
        lock.withLock { handle }?.deliver(batch) ?? false
    }

    private func record(_ operation: Operation, handle: FSEventStreamHandle) {
        let callbackIsAlive = handle.hasLiveCallbackContext
        lock.withLock {
            recordedOperations.append(operation)
            recordedCallbackLiveness.append(callbackIsAlive)
        }
    }
}
