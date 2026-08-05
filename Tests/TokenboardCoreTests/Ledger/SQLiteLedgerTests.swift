import Foundation
import XCTest
@testable import TokenboardCore

final class SQLiteLedgerTests: XCTestCase {
    private func makeLedger() throws -> SQLiteLedger {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLiteLedger(
            databaseURL: directory.appending(path: "ledger.sqlite"),
            backupDirectory: directory.appending(path: "Backups")
        )
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        value.firstWeekday = 2
        return value
    }

    func testCommitAggregatesSameDayAndStoresCheckpointAtomically() async throws {
        let ledger = try makeLedger()
        try await ledger.migrate()
        let timestamp = ISO8601DateFormatter().date(from: "2026-08-05T10:00:00Z")!
        let usage = try NormalizedUsage(
            provider: .codex,
            observedModelID: "gpt-test",
            timestamp: timestamp,
            metrics: [.inputUncached: 100, .output: 20, .detailReasoningOutput: 5],
            stableSourceID: "session-a",
            stableUsageID: "turn-a"
        )
        let checkpoint = SourceCheckpoint(
            fingerprint: "fingerprint-a", provider: .codex, parserVersion: 1,
            byteOffset: 120, fileSize: 120, modificationTime: timestamp,
            lastUsageIdentityHash: nil, lastCommittedLineHash: "line-hash",
            cumulativeMetrics: [.inputUncached: 100, .output: 20],
            adapterState: ["current_model": "gpt-test"]
        )

        try await ledger.commit([usage, usage], skipped: [], checkpoint: checkpoint, calendar: calendar)

        let rows = try await ledger.usageRows(in: nil, calendar: calendar)
        XCTAssertEqual(rows.first(where: { $0.metric == .inputUncached })?.quantity, 200)
        XCTAssertEqual(rows.first(where: { $0.metric == .detailReasoningOutput })?.aggregation, .informationalSubset)
        let storedCheckpoint = try await ledger.checkpoint(for: "fingerprint-a")
        XCTAssertEqual(storedCheckpoint, checkpoint)
    }

    func testMissingSourceNeverDeletesCommittedRows() async throws {
        let ledger = try makeLedger()
        try await ledger.migrate()
        let firstRead = try await ledger.usageRows(in: nil, calendar: calendar)
        let secondRead = try await ledger.usageRows(in: nil, calendar: calendar)
        XCTAssertEqual(firstRead, [])
        XCTAssertEqual(secondRead, [])
    }

    func testInvalidCheckpointRollsBackUsageAndSkippedRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appending(path: "ledger.sqlite")
        let ledger = try SQLiteLedger(databaseURL: databaseURL, backupDirectory: directory.appending(path: "Backups"))
        try await ledger.migrate()
        let timestamp = ISO8601DateFormatter().date(from: "2026-08-05T10:00:00Z")!
        let usage = try NormalizedUsage(
            provider: .codex, observedModelID: "gpt-test", timestamp: timestamp,
            metrics: [.inputUncached: 100], stableSourceID: "session-a", stableUsageID: "turn-a"
        )
        let skipped = SkippedRecord(
            sourceFingerprint: "fingerprint-a", byteOffset: 12, recordHash: "record-hash",
            parserVersion: 1, reason: "malformed"
        )
        let invalidCheckpoint = SourceCheckpoint(
            fingerprint: "fingerprint-a", provider: .codex, parserVersion: 1,
            byteOffset: -1, fileSize: 120, modificationTime: timestamp,
            lastUsageIdentityHash: nil, cumulativeMetrics: [:]
        )

        do {
            try await ledger.commit([usage], skipped: [skipped], checkpoint: invalidCheckpoint, calendar: self.calendar)
            XCTFail("Expected invalid checkpoint to fail its SQLite constraint")
        } catch let failure as SQLiteFailure {
            XCTAssertEqual(failure.code, 19)
        } catch {
            XCTFail("Expected SQLiteFailure, received \(error)")
        }

        let rows = try await ledger.usageRows(in: nil, calendar: calendar)
        let checkpoint = try await ledger.checkpoint(for: "fingerprint-a")
        XCTAssertEqual(rows, [])
        XCTAssertNil(checkpoint)
        let connection = try SQLiteConnection(url: databaseURL)
        XCTAssertEqual(try connection.queryStrings("SELECT record_hash FROM skipped_records;"), [])
    }
}
