import Foundation
import XCTest
@testable import TokenboardCore

final class JSONLReaderTests: XCTestCase {
    func testDoesNotAdvancePastPartialFinalLine() throws {
        let url = canonicalTestTemporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("first\npartial".utf8).write(to: url)

        let result = try JSONLReader().batch(from: url, startingAt: 0, maxLines: 500)

        XCTAssertEqual(result.lines.map { String(decoding: $0.data, as: UTF8.self) }, ["first"])
        XCTAssertEqual(result.committedOffset, 6)
        try FileHandle(forWritingTo: url).withClose { handle in
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("-line\n".utf8))
        }

        let resumed = try JSONLReader().batch(from: url, startingAt: 6, maxLines: 500)

        XCTAssertEqual(resumed.lines.map { String(decoding: $0.data, as: UTF8.self) }, ["partial-line"])
    }

    func testStopsAtRequestedCompleteLineCountWithByteAccurateOffsets() throws {
        let url = canonicalTestTemporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((String(repeating: "x\n", count: 501) + "partial").utf8).write(to: url)

        let first = try JSONLReader().batch(from: url, startingAt: 0, maxLines: 500)
        let second = try JSONLReader().batch(from: url, startingAt: first.committedOffset, maxLines: 500)

        XCTAssertEqual(first.lines.count, 500)
        XCTAssertEqual(first.lines.first?.startOffset, 0)
        XCTAssertEqual(first.lines.last?.endOffset, 1_000)
        XCTAssertEqual(first.committedOffset, 1_000)
        XCTAssertEqual(first.reachedEndOfFile, false)
        XCTAssertEqual(second.lines.count, 1)
        XCTAssertEqual(second.lines.first?.startOffset, 1_000)
        XCTAssertEqual(second.lines.first?.endOffset, 1_002)
        XCTAssertEqual(second.committedOffset, 1_002)
        XCTAssertEqual(second.reachedEndOfFile, true)
    }

    func testRejectsInvalidBoundsWithoutInferringTruncation() throws {
        let url = canonicalTestTemporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("line\n".utf8).write(to: url)

        do {
            _ = try JSONLReader().batch(from: url, startingAt: -1, maxLines: 1)
            XCTAssertTrue(false, "expected a negative-offset error")
        } catch let error as JSONLReaderError {
            XCTAssertEqual(error, .invalidStartingOffset)
        }
        do {
            _ = try JSONLReader().batch(from: url, startingAt: 0, maxLines: 0)
            XCTAssertTrue(false, "expected an invalid-line-count error")
        } catch let error as JSONLReaderError {
            XCTAssertEqual(error, .invalidMaximumLineCount)
        }
        do {
            _ = try JSONLReader().batch(from: url, startingAt: 6, maxLines: 1)
            XCTAssertTrue(false, "expected an offset-beyond-EOF error")
        } catch let error as JSONLReaderError {
            XCTAssertEqual(error, .startingOffsetBeyondEndOfFile)
        }
    }

    func testEmitsEmptyNewlineTerminatedRecords() throws {
        let url = canonicalTestTemporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("\n".utf8).write(to: url)

        let result = try JSONLReader().batch(from: url, startingAt: 0, maxLines: 1)

        XCTAssertEqual(result.lines, [JSONLLine(data: Data(), startOffset: 0, endOffset: 1)])
        XCTAssertEqual(result.committedOffset, 1)
    }

    func testStopsBeforeOversizedRecordWithoutReadingLaterLines() throws {
        let url = canonicalTestTemporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("ok\n12345\nlater\n".utf8).write(to: url)

        let result = try JSONLReader(maximumRecordBytes: 4).batch(
            from: url,
            startingAt: 0,
            maxLines: 500
        )

        XCTAssertEqual(result.lines.map { String(decoding: $0.data, as: UTF8.self) }, ["ok"])
        XCTAssertEqual(result.committedOffset, 3)
        XCTAssertEqual(result.oversizedRecordOffset, 3)
        XCTAssertFalse(result.reachedEndOfFile)
    }

    func testExactRecordLimitIsAcceptedAndOversizedPartialIsBounded() throws {
        let exact = canonicalTestTemporaryDirectory.appending(path: UUID().uuidString)
        let partial = canonicalTestTemporaryDirectory.appending(path: UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: exact)
            try? FileManager.default.removeItem(at: partial)
        }
        try Data("1234\n".utf8).write(to: exact)
        try Data("12345".utf8).write(to: partial)
        let reader = JSONLReader(maximumRecordBytes: 4)

        XCTAssertEqual(
            try reader.batch(from: exact, startingAt: 0, maxLines: 1).lines.first?.data,
            Data("1234".utf8)
        )
        let oversized = try reader.batch(from: partial, startingAt: 0, maxLines: 1)
        XCTAssertEqual(oversized.lines, [])
        XCTAssertEqual(oversized.committedOffset, 0)
        XCTAssertEqual(oversized.oversizedRecordOffset, 0)
    }

    func testLineEndingRefusesToAllocateBeyondRecordLimit() throws {
        let url = canonicalTestTemporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("12345\n".utf8).write(to: url)

        XCTAssertNil(try JSONLReader(maximumRecordBytes: 4).lineEnding(at: 6, in: url))
    }
}

private extension FileHandle {
    func withClose<T>(_ body: (FileHandle) throws -> T) rethrows -> T {
        defer { try? close() }
        return try body(self)
    }
}
