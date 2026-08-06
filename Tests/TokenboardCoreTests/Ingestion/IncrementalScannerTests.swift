import Foundation
import XCTest
@testable import TokenboardCore

final class IncrementalScannerTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return value
    }

    func testRepeatedAndRecreatedClaudeRecordsAreIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "source.jsonl")
        let ledger = try SQLiteLedger(
            databaseURL: directory.appending(path: "ledger.sqlite"),
            backupDirectory: directory.appending(path: "Backups")
        )
        try await ledger.migrate()
        let scanner = IncrementalScanner(ledger: ledger)
        let duplicateBytes = Data("\(claudeLine(requestID: "request-a", messageID: "message-a"))\n\(claudeLine(requestID: "request-a", messageID: "message-a"))\n".utf8)
        try duplicateBytes.write(to: file)

        let first = try await scanner.scan(file: file, provider: .claudeCode, calendar: calendar)
        let second = try await scanner.scan(file: file, provider: .claudeCode, calendar: calendar)
        try FileManager.default.removeItem(at: file)
        try duplicateBytes.write(to: file)
        let recreated = try await scanner.scan(file: file, provider: .claudeCode, calendar: calendar)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(claudeLine(requestID: "request-b", messageID: "message-b"))\n".utf8))
        try handle.close()
        let appended = try await scanner.scan(file: file, provider: .claudeCode, calendar: calendar)
        let rows = try await ledger.usageRows(in: nil, calendar: calendar)

        XCTAssertEqual(first.committedUsageRecords, 1)
        XCTAssertEqual(second.committedUsageRecords, 0)
        XCTAssertEqual(recreated.committedUsageRecords, 0)
        XCTAssertEqual(appended.committedUsageRecords, 1)
        XCTAssertEqual(rows.filter { $0.metric.countsTowardTokenTotal }.reduce(0) { $0 + $1.quantity }, 380)
    }

    func testTruncationDoesNotChangeCommittedRows() async throws {
        let setup = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let original = "\(claudeLine(requestID: "request-a", messageID: "message-a"))\n"
        try Data(original.utf8).write(to: setup.file)
        _ = try await setup.scanner.scan(file: setup.file, provider: .claudeCode, calendar: calendar)
        let before = try await setup.ledger.usageRows(in: nil, calendar: calendar)
        try Data((#"{"type":"user","sessionId":"session-a"}"# + "\n").utf8).write(to: setup.file)

        let outcome = try await setup.scanner.scan(file: setup.file, provider: .claudeCode, calendar: calendar)
        let after = try await setup.ledger.usageRows(in: nil, calendar: calendar)

        XCTAssertEqual(outcome.attention, .truncated)
        XCTAssertEqual(after, before)
    }

    func testPartialFinalLineIsCommittedOnlyAfterNewline() async throws {
        let setup = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let metadata = #"{"type":"user","sessionId":"session-a"}"#
        let usage = claudeLine(requestID: "request-a", messageID: "message-a")
        try Data("\(metadata)\n\(usage)".utf8).write(to: setup.file)

        let partial = try await setup.scanner.scan(file: setup.file, provider: .claudeCode, calendar: calendar)
        let handle = try FileHandle(forWritingTo: setup.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        let completed = try await setup.scanner.scan(file: setup.file, provider: .claudeCode, calendar: calendar)

        XCTAssertEqual(partial.committedUsageRecords, 0)
        XCTAssertEqual(completed.committedUsageRecords, 1)
    }

    func testCodexRecordsWithoutStableUsageIdentityRemainCountable() async throws {
        let setup = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let token = #"{"timestamp":"2026-08-05T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":3,"cached_input_tokens":1,"output_tokens":2,"total_tokens":5}}}}"#
        try Data("\(codexPreamble(model: "gpt-test"))\n\(token)\n".utf8).write(to: setup.file)

        let outcome = try await setup.scanner.scan(file: setup.file, provider: .codex, calendar: calendar)
        let rows = try await setup.ledger.usageRows(in: nil, calendar: calendar)

        XCTAssertEqual(outcome.committedUsageRecords, 1)
        XCTAssertEqual(rows.filter { $0.metric.countsTowardTokenTotal }.reduce(0) { $0 + $1.quantity }, 5)
    }

    func testCodexCumulativeResetDoesNotReplaceIncrementalUsageWithDerivedDelta() async throws {
        let setup = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let first = #"{"timestamp":"2026-08-05T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":5,"cached_input_tokens":1,"output_tokens":2,"total_tokens":7},"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"cache_write_input_tokens":10,"output_tokens":40,"reasoning_output_tokens":4,"total_tokens":140}}}}"#
        let reset = #"{"timestamp":"2026-08-05T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"total_tokens":2},"total_token_usage":{"input_tokens":2,"cached_input_tokens":1,"cache_write_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":3}}}}"#
        try Data("\(codexPreamble(model: "gpt-test"))\n\(first)\n\(reset)\n".utf8).write(to: setup.file)

        let outcome = try await setup.scanner.scan(file: setup.file, provider: .codex, calendar: calendar)
        let rows = try await setup.ledger.usageRows(in: nil, calendar: calendar)
        let fingerprint = try await setup.ledger.sourceFingerprint(provider: .codex, stableID: "session-a")
        let checkpoint = try await setup.ledger.checkpoint(for: fingerprint)

        XCTAssertEqual(outcome.committedUsageRecords, 2)
        XCTAssertEqual(rows.filter { $0.metric.countsTowardTokenTotal }.reduce(0) { $0 + $1.quantity }, 9)
        XCTAssertEqual(checkpoint?.cumulativeMetrics[.inputUnclassified], 2)
        XCTAssertEqual(checkpoint?.cumulativeMetrics[.output], 1)
    }

    func testUnsafeCodexModelUsesSameOpaqueAliasInUsageAndCheckpoint() async throws {
        let setup = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let rawModel = "vendor/model:beta@2026"
        let token = #"{"timestamp":"2026-08-05T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"total_tokens":2}}}}"#
        try Data("\(codexPreamble(model: rawModel))\n\(token)\n".utf8).write(to: setup.file)

        _ = try await setup.scanner.scan(file: setup.file, provider: .codex, calendar: calendar)
        let rows = try await setup.ledger.usageRows(in: nil, calendar: calendar)
        let fingerprint = try await setup.ledger.sourceFingerprint(provider: .codex, stableID: "session-a")
        let checkpoint = try await setup.ledger.checkpoint(for: fingerprint)
        let modelID = try XCTUnwrap(rows.first?.observedModelID)

        XCTAssertEqual(modelID.count, 72)
        XCTAssertTrue(modelID.hasPrefix("unknown-"))
        XCTAssertEqual(checkpoint?.adapterState["current_model"], modelID)
        XCTAssertNotEqual(modelID, rawModel)
    }

    func testChangedPreviouslyCommittedLineRequiresAttention() async throws {
        let setup = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let original = claudeLine(requestID: "request-a", messageID: "message-a")
        try Data("\(original)\n".utf8).write(to: setup.file)
        _ = try await setup.scanner.scan(file: setup.file, provider: .claudeCode, calendar: calendar)
        let changed = original.replacingOccurrences(of: "claude-opus-test", with: "claude-echo-test")
        XCTAssertEqual(changed.utf8.count, original.utf8.count)
        try Data("\(changed)\n".utf8).write(to: setup.file)

        let outcome = try await setup.scanner.scan(file: setup.file, provider: .claudeCode, calendar: calendar)

        XCTAssertEqual(outcome.attention, .replaced)
        XCTAssertEqual(outcome.committedUsageRecords, 0)
    }

    func testMissingStableIdentityReturnsAttentionWithoutWriting() async throws {
        let setup = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        try Data("{\"type\":\"user\"}\n".utf8).write(to: setup.file)

        let outcome = try await setup.scanner.scan(file: setup.file, provider: .claudeCode, calendar: calendar)
        let rows = try await setup.ledger.usageRows(in: nil, calendar: calendar)

        XCTAssertEqual(outcome.attention, .missingStableIdentity)
        XCTAssertEqual(outcome.finalOffset, 0)
        XCTAssertEqual(rows, [])
    }

    func testSourceProbeAcceptsProviderIdentityFallbacks() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let claude = directory.appending(path: "claude.jsonl")
        let codex = directory.appending(path: "codex.jsonl")
        try Data("{\"session_id\":\"claude-session\"}\n".utf8).write(to: claude)
        try Data("{\"type\":\"session_meta\",\"payload\":{\"session_id\":\"codex-session\"}}\n".utf8).write(to: codex)

        XCTAssertEqual(try SourceProbe().stableID(at: claude, provider: .claudeCode), "claude-session")
        XCTAssertEqual(try SourceProbe().stableID(at: codex, provider: .codex), "codex-session")
    }

    func testSkippedDiagnosticsPersistOnlyTheAllowlistedKind() async throws {
        let setup = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let metadata = #"{"type":"user","sessionId":"session-a"}"#
        let malformed = #"{"type":"assistant","message":{}}"#
        try Data("\(metadata)\n\(malformed)\n".utf8).write(to: setup.file)

        let outcome = try await setup.scanner.scan(file: setup.file, provider: .claudeCode, calendar: calendar)

        XCTAssertEqual(outcome.skippedRecords, 1)
        XCTAssertEqual(outcome.attention, nil)
    }

    func testEmptyLinesAdvanceCheckpointWithoutCreatingSkippedRecords() async throws {
        let setup = try await makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let metadata = #"{"type":"user","sessionId":"session-a"}"#
        try Data("\(metadata)\n\n".utf8).write(to: setup.file)

        let outcome = try await setup.scanner.scan(file: setup.file, provider: .claudeCode, calendar: calendar)

        XCTAssertEqual(outcome.skippedRecords, 0)
        XCTAssertEqual(outcome.finalOffset, Int64(Data("\(metadata)\n\n".utf8).count))
    }

    private func claudeLine(requestID: String, messageID: String) -> String {
        #"{"type":"assistant","timestamp":"2026-08-05T10:00:00.000Z","sessionId":"session-a","requestId":"\#(requestID)","message":{"id":"\#(messageID)","model":"claude-opus-test","usage":{"input_tokens":100,"cache_creation_input_tokens":30,"cache_read_input_tokens":40,"output_tokens":20,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":20}}}}"#
    }

    private func codexPreamble(model: String) -> String {
        #"""
        {"type":"session_meta","payload":{"id":"session-a"}}
        {"type":"turn_context","payload":{"model":"\#(model)"}}
        """#
    }

    private func makeSetup() async throws -> (
        directory: URL,
        file: URL,
        ledger: SQLiteLedger,
        scanner: IncrementalScanner
    ) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = try SQLiteLedger(
            databaseURL: directory.appending(path: "ledger.sqlite"),
            backupDirectory: directory.appending(path: "Backups")
        )
        try await ledger.migrate()
        return (
            directory,
            directory.appending(path: "source.jsonl"),
            ledger,
            IncrementalScanner(ledger: ledger)
        )
    }
}
