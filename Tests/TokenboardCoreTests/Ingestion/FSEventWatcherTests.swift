import CoreServices
import Foundation
import XCTest
@testable import TokenboardCore

final class FSEventWatcherTests: XCTestCase {
    func testNativeWatcherDeliversFilesystemChangesWithoutManualRefresh() async throws {
        let root = canonicalTestTemporaryDirectory
            .appending(path: "tokenboard-native-watcher-\(UUID().uuidString)")
            .standardizedFileURL
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let watcher = FSEventWatcher()
        let stream = try watcher.start(roots: [root])
        let changedFile = root.appending(path: "session.jsonl")
        defer {
            watcher.stop()
            try? FileManager.default.removeItem(at: root)
        }

        try Data("{\"type\":\"event\"}\n".utf8).write(to: changedFile)

        let received = await withTaskGroup(of: SourceEventBatch?.self) { group in
            group.addTask {
                for await batch in stream {
                    if batch.paths.contains(changedFile) || batch.paths.contains(root) {
                        return batch
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        XCTAssertNotNil(received, "Native FSEvents should deliver source changes automatically")
    }

    func testReconciliationDeliversExistingFileGrowthWhenNativeEventsStaySilent() async throws {
        let root = canonicalTestTemporaryDirectory
            .appending(path: "tokenboard-silent-native-watcher-\(UUID().uuidString)")
            .standardizedFileURL
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let changedFile = root.appending(path: "session.jsonl")
        try Data("{\"type\":\"session_meta\"}\n".utf8).write(to: changedFile)
        let driver = RecordingFSEventStreamDriver()
        let watcher = FSEventWatcher(
            driver: driver,
            reconciliationInterval: .milliseconds(50)
        )
        let stream = try watcher.start(roots: [root])
        defer {
            watcher.stop()
            try? FileManager.default.removeItem(at: root)
        }

        let file = try FileHandle(forWritingTo: changedFile)
        try file.seekToEnd()
        try file.write(contentsOf: Data("{\"type\":\"event_msg\"}\n".utf8))
        try file.close()

        let received = await withTaskGroup(of: SourceEventBatch?.self) { group in
            group.addTask {
                for await batch in stream where batch.paths.contains(changedFile) {
                    return batch
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        XCTAssertEqual(received?.paths, [changedFile])
        XCTAssertNil(received?.checkpoint)
        XCTAssertEqual(driver.operations.prefix(2), [.schedule, .start(true)])
    }

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
        let stream = try! watcher.start(roots: roots)
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

        let stream = try! watcher.start(roots: roots)

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
        let firstStream = try! watcher.start(roots: [root])
        var firstIterator = firstStream.makeAsyncIterator()
        XCTAssertTrue(driver.emit([
            FSEventDriverEvent(path: root.appending(path: "one.jsonl").path, flags: 0, eventID: 901)
        ]))
        let first = await firstIterator.next()
        XCTAssertEqual(first?.paths, [root.appending(path: "one.jsonl")])
        watcher.acknowledge(first?.checkpoint)

        let secondStream = try! watcher.start(roots: [root])
        withExtendedLifetime(secondStream) {}

        XCTAssertEqual(driver.configurations.map(\.sinceWhen), [900, 901])
        watcher.stop()
    }

    func testUnacknowledgedDeliveryIsReplayedAcrossReconfiguration() async {
        let driver = RecordingFSEventStreamDriver(currentEventID: 40)
        let watcher = FSEventWatcher(driver: driver)
        let root = URL(fileURLWithPath: "/tmp/codex").standardizedFileURL
        let firstStream = try! watcher.start(roots: [root])
        XCTAssertTrue(driver.emit([
            FSEventDriverEvent(path: root.appending(path: "gap.jsonl").path, flags: 0, eventID: 41)
        ]))
        withExtendedLifetime(firstStream) {}

        let secondStream = try! watcher.start(roots: [root])
        withExtendedLifetime(secondStream) {}

        XCTAssertEqual(driver.configurations.map(\.sinceWhen), [40, 40])
        watcher.stop()
    }

    func testRootChangedZeroRetainsHighAcknowledgedCheckpointAcrossReconfiguration() async {
        let driver = RecordingFSEventStreamDriver(currentEventID: 900)
        let watcher = FSEventWatcher(driver: driver)
        let root = URL(fileURLWithPath: "/tmp/claude").standardizedFileURL
        let stream = try! watcher.start(roots: [root])
        var iterator = stream.makeAsyncIterator()
        XCTAssertTrue(driver.emit([
            FSEventDriverEvent(
                path: root.appending(path: "before-root-change.jsonl").path,
                flags: 0,
                eventID: 901
            )
        ]))
        watcher.acknowledge((await iterator.next())?.checkpoint)

        XCTAssertTrue(driver.emit([
            FSEventDriverEvent(
                path: root.path,
                flags: UInt32(kFSEventStreamEventFlagRootChanged),
                eventID: 0
            )
        ]))
        let recovered = await iterator.next()
        XCTAssertEqual(recovered?.paths, [root])
        XCTAssertEqual(recovered?.checkpoint, SourceEventCheckpoint(eventID: 901))
        watcher.acknowledge(recovered?.checkpoint)

        let replacement = try! watcher.start(roots: [root])
        withExtendedLifetime(replacement) {}
        XCTAssertEqual(driver.configurations.map(\.sinceWhen), [900, 901])
        watcher.stop()
    }

    func testLowerNonWrapRecoveryCannotResetHighCheckpoint() async {
        let driver = RecordingFSEventStreamDriver(currentEventID: 800)
        let watcher = FSEventWatcher(driver: driver)
        let root = URL(fileURLWithPath: "/tmp/codex").standardizedFileURL
        let stream = try! watcher.start(roots: [root])
        var iterator = stream.makeAsyncIterator()
        XCTAssertTrue(driver.emit([
            FSEventDriverEvent(
                path: root.appending(path: "before-sentinel.jsonl").path,
                flags: 0,
                eventID: 801
            )
        ]))
        watcher.acknowledge((await iterator.next())?.checkpoint)

        XCTAssertTrue(driver.emit([
            FSEventDriverEvent(
                path: root.path,
                flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs),
                eventID: 1
            )
        ]))
        let recovered = await iterator.next()
        XCTAssertEqual(recovered?.paths, [root])
        XCTAssertEqual(
            recovered?.checkpoint,
            SourceEventCheckpoint(eventID: 1, disposition: .advance)
        )
        watcher.acknowledge(recovered?.checkpoint)

        let replacement = try! watcher.start(roots: [root])
        withExtendedLifetime(replacement) {}
        XCTAssertEqual(driver.configurations.map(\.sinceWhen), [800, 801])
        watcher.stop()
    }

    func testWrappedOverflowSurvivesOneSlotDropAndRebasesBeforeReconfiguration() async {
        let driver = RecordingFSEventStreamDriver(currentEventID: UInt64.max - 10)
        let watcher = FSEventWatcher(driver: driver)
        let roots = [
            URL(fileURLWithPath: "/tmp/claude").standardizedFileURL,
            URL(fileURLWithPath: "/tmp/codex").standardizedFileURL
        ]
        let firstStream = try! watcher.start(roots: roots)
        var firstIterator = firstStream.makeAsyncIterator()
        XCTAssertTrue(driver.emit([
            FSEventDriverEvent(
                path: roots[0].appending(path: "before-wrap.jsonl").path,
                flags: 0,
                eventID: UInt64.max - 9
            )
        ]))
        watcher.acknowledge((await firstIterator.next())?.checkpoint)

        driver.setCurrentEventID(7)
        XCTAssertTrue(driver.emit(FSEventDriverBatch(
            events: [FSEventDriverEvent(
                path: roots[0].path,
                flags: UInt32(
                    kFSEventStreamEventFlagEventIdsWrapped
                        | kFSEventStreamEventFlagKernelDropped
                ),
                eventID: 5
            )],
            overflowed: true,
            highestConsumedEventID: 5,
            terminalEventID: 6
        )))
        driver.setCurrentEventID(9)
        XCTAssertTrue(driver.emit([
            FSEventDriverEvent(
                path: roots[1].appending(path: "after-wrap.jsonl").path,
                flags: 0,
                eventID: 9
            )
        ]))

        let recovered = await firstIterator.next()
        XCTAssertEqual(recovered?.paths, Set(roots))
        XCTAssertEqual(
            recovered?.checkpoint,
            SourceEventCheckpoint(eventID: 9, disposition: .reset)
        )
        watcher.acknowledge(recovered?.checkpoint)

        let replacementStream = try! watcher.start(roots: [roots[1]])
        withExtendedLifetime(replacementStream) {}
        XCTAssertEqual(
            driver.configurations.map(\.sinceWhen),
            [UInt64.max - 10, 9]
        )
        watcher.stop()
    }

    func testWrappedRecoveryUsesCurrentPostWrapIDInsteadOfFlaggedTerminalID() async {
        let driver = RecordingFSEventStreamDriver(currentEventID: UInt64.max - 20)
        let watcher = FSEventWatcher(driver: driver)
        let root = URL(fileURLWithPath: "/tmp/claude").standardizedFileURL
        let stream = try! watcher.start(roots: [root])
        var iterator = stream.makeAsyncIterator()
        driver.setCurrentEventID(7)

        XCTAssertTrue(driver.emit(FSEventDriverBatch(
            events: [FSEventDriverEvent(
                path: root.path,
                flags: UInt32(
                    kFSEventStreamEventFlagRootChanged
                        | kFSEventStreamEventFlagEventIdsWrapped
                ),
                eventID: 0
            )],
            overflowed: false,
            highestConsumedEventID: 0,
            terminalEventID: 0
        )))

        let recovered = await iterator.next()
        XCTAssertEqual(recovered?.paths, [root])
        XCTAssertEqual(
            recovered?.checkpoint,
            SourceEventCheckpoint(eventID: 7, disposition: .reset)
        )
        watcher.acknowledge(recovered?.checkpoint)
        let replacement = try! watcher.start(roots: [root])
        withExtendedLifetime(replacement) {}
        XCTAssertEqual(
            driver.configurations.map(\.sinceWhen),
            [UInt64.max - 20, 7]
        )
        watcher.stop()
    }

    func testPendingWrapWithZeroCurrentReconfiguresSinceNowThenRebasesOnLaterEvent() async {
        let driver = RecordingFSEventStreamDriver(currentEventID: 900)
        let watcher = FSEventWatcher(driver: driver)
        let root = URL(fileURLWithPath: "/tmp/claude").standardizedFileURL
        let initialStream = try! watcher.start(roots: [root])
        var initialIterator = initialStream.makeAsyncIterator()
        XCTAssertTrue(driver.emit([
            FSEventDriverEvent(
                path: root.appending(path: "before-pending-wrap.jsonl").path,
                flags: 0,
                eventID: 901
            )
        ]))
        watcher.acknowledge((await initialIterator.next())?.checkpoint)
        driver.setCurrentEventID(0)
        XCTAssertTrue(driver.emit([
            FSEventDriverEvent(
                path: root.path,
                flags: UInt32(
                    kFSEventStreamEventFlagRootChanged
                        | kFSEventStreamEventFlagEventIdsWrapped
                ),
                eventID: 0
            )
        ]))
        let recovery = await initialIterator.next()
        XCTAssertEqual(recovery?.paths, [root])
        XCTAssertNil(recovery?.checkpoint)
        watcher.acknowledge(recovery?.checkpoint)

        let readsBeforeReconfiguration = driver.currentEventIDReadCount
        let recoveryStream = try! watcher.start(roots: [root])
        var recoveryIterator = recoveryStream.makeAsyncIterator()
        XCTAssertEqual(driver.currentEventIDReadCount, readsBeforeReconfiguration + 1)
        XCTAssertEqual(
            driver.configurations.map(\.sinceWhen),
            [900, UInt64(kFSEventStreamEventIdSinceNow)]
        )

        driver.setCurrentEventID(7)
        XCTAssertTrue(driver.emit([
            FSEventDriverEvent(
                path: root.appending(path: "after-pending-wrap.jsonl").path,
                flags: 0,
                eventID: 7
            )
        ]))
        let postWrap = await recoveryIterator.next()
        XCTAssertEqual(
            postWrap?.checkpoint,
            SourceEventCheckpoint(eventID: 7, disposition: .reset)
        )
        watcher.acknowledge(postWrap?.checkpoint)

        let finalStream = try! watcher.start(roots: [root])
        withExtendedLifetime(finalStream) {}
        XCTAssertEqual(
            driver.configurations.map(\.sinceWhen),
            [900, UInt64(kFSEventStreamEventIdSinceNow), 7]
        )
        watcher.stop()
    }

    func testPendingWrapReconfigurationSamplesNonzeroCurrentOnceAndKeepsResetPending() async {
        let driver = RecordingFSEventStreamDriver(currentEventID: 700)
        let watcher = FSEventWatcher(driver: driver)
        let root = URL(fileURLWithPath: "/tmp/codex").standardizedFileURL
        let initialStream = try! watcher.start(roots: [root])
        var initialIterator = initialStream.makeAsyncIterator()
        XCTAssertTrue(driver.emit([
            FSEventDriverEvent(
                path: root.appending(path: "before-direct-sample.jsonl").path,
                flags: 0,
                eventID: 701
            )
        ]))
        watcher.acknowledge((await initialIterator.next())?.checkpoint)
        driver.setCurrentEventID(0)
        XCTAssertTrue(driver.emit([
            FSEventDriverEvent(
                path: root.path,
                flags: UInt32(kFSEventStreamEventFlagEventIdsWrapped),
                eventID: 0
            )
        ]))
        let recovery = await initialIterator.next()
        XCTAssertNil(recovery?.checkpoint)

        driver.setCurrentEventID(5)
        let readsBeforeReconfiguration = driver.currentEventIDReadCount
        let recoveryStream = try! watcher.start(roots: [root])
        var recoveryIterator = recoveryStream.makeAsyncIterator()
        XCTAssertEqual(driver.currentEventIDReadCount, readsBeforeReconfiguration + 1)
        XCTAssertEqual(driver.configurations.map(\.sinceWhen), [700, 5])

        XCTAssertTrue(driver.emit([
            FSEventDriverEvent(
                path: root.appending(path: "reset-intent-retained.jsonl").path,
                flags: 0,
                eventID: 7
            )
        ]))
        let postWrap = await recoveryIterator.next()
        XCTAssertEqual(
            postWrap?.checkpoint,
            SourceEventCheckpoint(eventID: 7, disposition: .reset)
        )
        watcher.stop()
    }

    func testDeliverySucceedsBeforeCleanupAndIsRejectedAfterRelease() async {
        let driver = RecordingFSEventStreamDriver()
        let watcher = FSEventWatcher(driver: driver)
        let root = URL(fileURLWithPath: "/tmp/claude").standardizedFileURL
        let stream = try! watcher.start(roots: [root])
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
        let stream = try! watcher.start(roots: [root])

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
        let stream = try! watcher.start(roots: [root])

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

        let resumed = try! watcher.start(roots: [root])
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
        let stream = try! watcher.start(roots: roots)
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
        let stream = try! watcher.start(roots: roots)
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

    func testCreateFailureThrowsBeforeReturningStream() {
        let driver = RecordingFSEventStreamDriver(createResult: false)
        let watcher = FSEventWatcher(driver: driver)

        XCTAssertThrowsError(
            try watcher.start(roots: [URL(fileURLWithPath: "/tmp/claude")])
        ) { error in
            XCTAssertEqual(error as? FSEventWatcherError, .couldNotCreateStream)
        }
        XCTAssertEqual(driver.createCount, 1)
        XCTAssertEqual(driver.operations, [])
        XCTAssertFalse(driver.callbackContextIsAlive)
        XCTAssertEqual(driver.callbackReleaseCount, 0)
    }

    func testStartFailureThrowsAndUsesFailureCleanupOrderExactlyOnce() {
        let driver = RecordingFSEventStreamDriver(startResult: false)
        let watcher = FSEventWatcher(driver: driver)

        XCTAssertThrowsError(
            try watcher.start(roots: [URL(fileURLWithPath: "/tmp/claude")])
        ) { error in
            XCTAssertEqual(error as? FSEventWatcherError, .couldNotStartStream)
        }
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
        let stream = try! watcher.start(
            roots: [URL(fileURLWithPath: "/tmp/claude")]
        )
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
    private let createResult: Bool
    private let startResult: Bool
    private var recordedCurrentEventID: UInt64
    private var handle: FSEventStreamHandle?
    private var recordedOperations: [Operation] = []
    private var recordedCallbackLiveness: [Bool] = []
    private var recordedCallbackReleaseCount = 0
    private var recordedOperationCountsAtCallbackRelease: [Int] = []
    private var recordedConfigurations: [FSEventStreamConfiguration] = []
    private var recordedCreateCount = 0
    private var recordedCurrentEventIDReadCount = 0

    init(
        createResult: Bool = true,
        startResult: Bool = true,
        currentEventID: UInt64 = 0
    ) {
        self.createResult = createResult
        self.startResult = startResult
        recordedCurrentEventID = currentEventID
    }

    var configuration: FSEventStreamConfiguration? { lock.withLock { recordedConfigurations.last } }
    var configurations: [FSEventStreamConfiguration] { lock.withLock { recordedConfigurations } }
    var createCount: Int { lock.withLock { recordedCreateCount } }
    var currentEventIDReadCount: Int { lock.withLock { recordedCurrentEventIDReadCount } }
    var operations: [Operation] { lock.withLock { recordedOperations } }
    var callbackLivenessAtOperation: [Bool] { lock.withLock { recordedCallbackLiveness } }
    var callbackReleaseCount: Int { lock.withLock { recordedCallbackReleaseCount } }
    var operationCountsAtCallbackRelease: [Int] {
        lock.withLock { recordedOperationCountsAtCallbackRelease }
    }
    var callbackContextIsAlive: Bool {
        lock.withLock { handle }?.hasLiveCallbackContext ?? false
    }

    func currentEventID() -> UInt64 {
        lock.withLock {
            recordedCurrentEventIDReadCount += 1
            return recordedCurrentEventID
        }
    }

    func setCurrentEventID(_ eventID: UInt64) {
        lock.withLock { recordedCurrentEventID = eventID }
    }

    func create(
        configuration: FSEventStreamConfiguration,
        callback: @escaping @Sendable (FSEventDriverBatch) -> Void
    ) -> FSEventStreamHandle? {
        lock.withLock {
            recordedCreateCount += 1
            recordedConfigurations.append(configuration)
            guard createResult else { return nil }
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
