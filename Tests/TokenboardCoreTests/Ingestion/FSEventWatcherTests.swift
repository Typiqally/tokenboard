import CoreServices
import Foundation
import XCTest
@testable import TokenboardCore

final class FSEventWatcherTests: XCTestCase {
    func testCreatesOneStreamWithExactNativeConfigurationAndReleasesItOnce() {
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
        XCTAssertEqual(driver.scheduleCount, 1)
        XCTAssertEqual(driver.startCount, 1)
        XCTAssertEqual(driver.hasLiveHandle, true)

        watcher.stop()
        watcher.stop()

        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(driver.invalidateCount, 1)
        XCTAssertEqual(driver.releaseCount, 1)
        XCTAssertEqual(driver.hasLiveHandle, false)
        withExtendedLifetime(stream) {}
    }

    func testRootChangedEventYieldsTheWatchedRoot() async {
        let driver = RecordingFSEventStreamDriver()
        let watcher = FSEventWatcher(driver: driver)
        let root = URL(fileURLWithPath: "/tmp/claude").standardizedFileURL
        let stream = watcher.events(for: [root])
        var iterator = stream.makeAsyncIterator()

        driver.emit([
            FSEventDriverEvent(
                path: root.appending(path: "renamed").path,
                flags: UInt32(kFSEventStreamEventFlagRootChanged)
            )
        ])

        let received = await iterator.next()
        XCTAssertEqual(received, [root])
        watcher.stop()
    }

    func testStartFailureInvalidatesAndReleasesWithoutStopping() async {
        let driver = RecordingFSEventStreamDriver(startResult: false)
        let watcher = FSEventWatcher(driver: driver)
        let stream = watcher.events(for: [URL(fileURLWithPath: "/tmp/claude")])
        var iterator = stream.makeAsyncIterator()

        let received = await iterator.next()
        XCTAssertEqual(received, nil)
        XCTAssertEqual(driver.stopCount, 0)
        XCTAssertEqual(driver.invalidateCount, 1)
        XCTAssertEqual(driver.releaseCount, 1)
        XCTAssertEqual(driver.hasLiveHandle, false)

        watcher.stop()
        XCTAssertEqual(driver.invalidateCount, 1)
        XCTAssertEqual(driver.releaseCount, 1)
    }
}

private final class RecordingFSEventStreamDriver: FSEventStreamDriving, @unchecked Sendable {
    private let lock = NSLock()
    private let startResult: Bool
    private weak var handle: FSEventStreamHandle?
    private(set) var configuration: FSEventStreamConfiguration?
    private(set) var createCount = 0
    private(set) var scheduleCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var invalidateCount = 0
    private(set) var releaseCount = 0

    init(startResult: Bool = true) {
        self.startResult = startResult
    }

    var hasLiveHandle: Bool { lock.withLock { handle != nil } }

    func create(
        configuration: FSEventStreamConfiguration,
        callback: @escaping @Sendable ([FSEventDriverEvent]) -> Void
    ) -> FSEventStreamHandle? {
        lock.withLock {
            createCount += 1
            self.configuration = configuration
            let handle = FSEventStreamHandle(callback: callback)
            self.handle = handle
            return handle
        }
    }

    func schedule(_ handle: FSEventStreamHandle, on queue: DispatchQueue) {
        lock.withLock { scheduleCount += 1 }
    }

    func start(_ handle: FSEventStreamHandle) -> Bool {
        lock.withLock {
            startCount += 1
            return startResult
        }
    }

    func stop(_ handle: FSEventStreamHandle) {
        lock.withLock { stopCount += 1 }
    }

    func invalidate(_ handle: FSEventStreamHandle) {
        lock.withLock { invalidateCount += 1 }
    }

    func release(_ handle: FSEventStreamHandle) {
        lock.withLock { releaseCount += 1 }
    }

    func emit(_ events: [FSEventDriverEvent]) {
        lock.withLock { handle }?.deliver(events)
    }
}
