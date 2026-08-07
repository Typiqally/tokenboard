import Foundation
import Darwin
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

    func testSkippedRecordStoresDiagnosticKindAndOpaqueHashes() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "source.jsonl")
        let metadata = #"{"type":"user","sessionId":"capture-source"}"#
        let malformed = #"{"type":"assistant","message":{}}"#
        try Data("\(metadata)\n\(malformed)\n".utf8).write(to: file)
        let ledger = ScannerTestLedger()

        let outcome = try await IncrementalScanner(ledger: ledger).scan(
            file: file,
            provider: .claudeCode,
            calendar: calendar
        )
        let commits = await ledger.capturedSuccessfulCommits()
        let skipped = try XCTUnwrap(commits.first?.skipped.first)

        XCTAssertEqual(outcome.skippedRecords, 1)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].skipped.count, 1)
        XCTAssertEqual(skipped.reason, AdapterDiagnostic.Kind.malformedRecord.rawValue)
        XCTAssertNotEqual(skipped.reason, "Claude record is malformed")
        XCTAssertTrue(isOpaqueDigest(skipped.sourceFingerprint))
        XCTAssertTrue(isOpaqueDigest(skipped.recordHash))
        XCTAssertEqual(skipped.byteOffset, Int64(Data("\(metadata)\n".utf8).count))
        XCTAssertEqual(skipped.parserVersion, ClaudeCodeAdapter.parserVersion)
    }

    func testSQLiteStorageContainsNoRawSourceUsageLineDiagnosticOrUnsafeModelMarkers() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "source.jsonl")
        let database = directory.appending(path: "ledger.sqlite")
        let rawSourceID = "RAW_SOURCE_ID_SENTINEL_91D7"
        let unsafeModelID = "vendor/model:RAW_MODEL_SENTINEL@91D7"
        let stableUsageID = "2042-01-02T03:04:05Z:424242"
        let lineMarker = "RAW_LINE_BYTES_SENTINEL_91D7"
        let diagnosticMessage = "Codex record is malformed"
        let session = #"{"type":"session_meta","payload":{"id":"\#(rawSourceID)"}}"#
        let context = #"{"type":"turn_context","payload":{"model":"\#(unsafeModelID)"}}"#
        let usage = #"{"timestamp":"2042-01-02T03:04:05Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":5,"total_tokens":15},"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":40,"total_tokens":424242}}}}"#
        let malformed = #"{"type":"event_msg","payload":"\#(lineMarker)"}"#
        try Data("\(session)\n\(context)\n\(usage)\n\(malformed)\n".utf8).write(to: file)
        let ledger = try SQLiteLedger(
            databaseURL: database,
            backupDirectory: directory.appending(path: "Backups")
        )
        try await ledger.migrate()

        let outcome = try await IncrementalScanner(ledger: ledger).scan(
            file: file,
            provider: .codex,
            calendar: calendar
        )
        let rows = try await ledger.usageRows(in: nil, calendar: calendar)
        let fingerprint = try await ledger.sourceFingerprint(provider: .codex, stableID: rawSourceID)
        let checkpoint = try await ledger.checkpoint(for: fingerprint)
        let alias = try XCTUnwrap(rows.first?.observedModelID)
        let storageBytes = try sqliteStorageBytes(database: database)

        XCTAssertEqual(outcome.committedUsageRecords, 1)
        XCTAssertEqual(outcome.skippedRecords, 1)
        XCTAssertEqual(alias.count, 72)
        XCTAssertTrue(alias.hasPrefix("unknown-"))
        XCTAssertTrue(isOpaqueDigest(String(alias.dropFirst("unknown-".count))))
        XCTAssertEqual(checkpoint?.adapterState["current_model"], alias)
        for marker in [rawSourceID, stableUsageID, lineMarker, diagnosticMessage, unsafeModelID] {
            XCTAssertNil(storageBytes.range(of: Data(marker.utf8)), "persisted raw marker: \(marker)")
        }
    }

    func testFailedCommitRetriesFromPersistedCheckpointWithoutLossOrDuplication() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "source.jsonl")
        let firstLine = claudeLine(
            sessionID: "retry-source",
            requestID: "request-a",
            messageID: "message-a"
        )
        let secondLine = claudeLine(
            sessionID: "retry-source",
            requestID: "request-b",
            messageID: "message-b"
        )
        let fileData = Data("\(firstLine)\n\(secondLine)\n".utf8)
        try fileData.write(to: file)
        let ledger = ScannerTestLedger(failFirstCommit: true)
        let fingerprint = await ledger.sourceFingerprint(provider: .claudeCode, stableID: "retry-source")
        let firstUsageHash = await ledger.recordIdentityHash("request-a:message-a")
        let firstLineHash = await ledger.recordIdentityHash(Data(firstLine.utf8).base64EncodedString())
        let firstOffset = Int64(Data("\(firstLine)\n".utf8).count)
        let priorCheckpoint = SourceCheckpoint(
            fingerprint: fingerprint,
            provider: .claudeCode,
            parserVersion: ClaudeCodeAdapter.parserVersion,
            byteOffset: firstOffset,
            fileSize: Int64(fileData.count),
            modificationTime: nil,
            lastUsageIdentityHash: firstUsageHash,
            lastCommittedLineHash: firstLineHash,
            cumulativeMetrics: [:]
        )
        await ledger.seed(checkpoint: priorCheckpoint)
        let scanner = IncrementalScanner(ledger: ledger)

        do {
            _ = try await scanner.scan(file: file, provider: .claudeCode, calendar: calendar)
            XCTFail("expected the injected commit failure")
        } catch let error as ScannerTestLedgerError {
            XCTAssertEqual(error, .injectedCommitFailure)
        }
        let checkpointAfterFailure = await ledger.capturedCheckpoint()
        let failedAttempts = await ledger.capturedAttempts()
        let failedAttempt = try XCTUnwrap(failedAttempts.first)

        let retried = try await scanner.scan(file: file, provider: .claudeCode, calendar: calendar)
        let alreadyCurrent = try await scanner.scan(file: file, provider: .claudeCode, calendar: calendar)
        let attempts = await ledger.capturedAttempts()
        let successful = await ledger.capturedSuccessfulCommits()
        let firstAttempt = try XCTUnwrap(attempts.first)
        let retryAttempt = try XCTUnwrap(attempts.dropFirst().first)
        let committed = try XCTUnwrap(successful.first)
        let committedUsage = try XCTUnwrap(committed.usage.first)

        XCTAssertEqual(checkpointAfterFailure, priorCheckpoint)
        XCTAssertEqual(failedAttempts.count, 1)
        XCTAssertEqual(failedAttempt.checkpoint.byteOffset, Int64(fileData.count))
        XCTAssertEqual(retried.committedUsageRecords, 1)
        XCTAssertEqual(alreadyCurrent.committedUsageRecords, 0)
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(firstAttempt, retryAttempt)
        XCTAssertEqual(successful.count, 1)
        XCTAssertEqual(committed.usage.count, 1)
        XCTAssertEqual(committedUsage.tokenTotal, 190)
        XCTAssertEqual(committed.checkpoint.byteOffset, Int64(fileData.count))
    }

    func testMixedSourceOutcomesCommitInFiveHundredLineBatches() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "source.jsonl")
        var fileData = Data()
        var lineEndOffsets: [Int64] = []
        for index in 0..<503 {
            let line: String
            switch index % 4 {
            case 0:
                line = claudeLine(
                    sessionID: "batch-source",
                    requestID: "request-\(index)",
                    messageID: "message-\(index)"
                )
            case 1:
                line = #"{"type":"assistant","sessionId":"batch-source","message":{}}"#
            case 2:
                line = #"{"type":"user","sessionId":"batch-source"}"#
            default:
                line = ""
            }
            fileData.append(contentsOf: line.utf8)
            fileData.append(0x0A)
            lineEndOffsets.append(Int64(fileData.count))
        }
        try fileData.write(to: file)
        let ledger = ScannerTestLedger()

        let outcome = try await IncrementalScanner(ledger: ledger).scan(
            file: file,
            provider: .claudeCode,
            calendar: calendar
        )
        let commits = await ledger.capturedSuccessfulCommits()
        let firstCommit = try XCTUnwrap(commits.first)
        let secondCommit = try XCTUnwrap(commits.dropFirst().first)
        let firstEndingLine = try XCTUnwrap(lineEndOffsets.firstIndex(of: firstCommit.checkpoint.byteOffset))
        let secondEndingLine = try XCTUnwrap(lineEndOffsets.firstIndex(of: secondCommit.checkpoint.byteOffset))
        let committedSourceLineCounts = [firstEndingLine + 1, secondEndingLine - firstEndingLine]

        XCTAssertEqual(outcome.committedUsageRecords, 126)
        XCTAssertEqual(outcome.skippedRecords, 126)
        XCTAssertEqual(outcome.finalOffset, Int64(fileData.count))
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits.map { $0.usage.count }, [125, 1])
        XCTAssertEqual(commits.map { $0.skipped.count }, [125, 1])
        XCTAssertEqual(commits.map { $0.usage.count + $0.skipped.count }, [250, 2])
        XCTAssertEqual(commits.map(\.checkpoint.byteOffset), [lineEndOffsets[499], lineEndOffsets[502]])
        XCTAssertEqual(committedSourceLineCounts, [500, 3])
        XCTAssertLessThanOrEqual(firstCommit.usage.count + firstCommit.skipped.count, 500)
        XCTAssertLessThanOrEqual(secondCommit.usage.count + secondCommit.skipped.count, 500)
    }

    func testOversizedRecordCommitsPriorLinesThenPinsCheckpointAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "source.jsonl")
        let valid = claudeLine(
            sessionID: "oversized-source",
            requestID: "request-a",
            messageID: "message-a"
        )
        let prefix = Data("\(valid)\n".utf8)
        var bytes = prefix
        bytes.append(Data(repeating: 0x78, count: 1_025))
        bytes.append(0x0A)
        bytes.append(contentsOf: "later\n".utf8)
        try bytes.write(to: file)
        let ledger = ScannerTestLedger()
        let scanner = IncrementalScanner(
            ledger: ledger,
            reader: JSONLReader(maximumRecordBytes: 1_024)
        )

        let first = try await scanner.scan(file: file, provider: .claudeCode, calendar: calendar)
        let restarted = try await scanner.scan(file: file, provider: .claudeCode, calendar: calendar)
        let checkpoint = await ledger.capturedCheckpoint()

        XCTAssertEqual(first.committedUsageRecords, 1)
        XCTAssertEqual(first.attention, .oversizedRecord)
        XCTAssertEqual(first.finalOffset, Int64(prefix.count))
        XCTAssertEqual(restarted.committedUsageRecords, 0)
        XCTAssertEqual(restarted.attention, .oversizedRecord)
        XCTAssertEqual(restarted.finalOffset, Int64(prefix.count))
        XCTAssertEqual(checkpoint?.byteOffset, Int64(prefix.count))
    }

    func testSpecialSourceLeavesAreRejectedPromptlyWithoutFollowing() async throws {
        for kind in ["symlink", "hardlink", "fifo"] {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let outside = directory.appending(path: "outside.jsonl")
            let source = directory.appending(path: "source.jsonl")
            try Data("{\"type\":\"user\",\"sessionId\":\"outside\"}\n".utf8).write(to: outside)
            switch kind {
            case "symlink":
                try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
            case "hardlink":
                try FileManager.default.linkItem(at: outside, to: source)
            default:
                XCTAssertEqual(mkfifo(source.path, S_IRUSR | S_IWUSR), 0)
            }

            let outcome = try await IncrementalScanner(ledger: ScannerTestLedger()).scan(
                file: source,
                provider: .claudeCode,
                calendar: calendar
            )

            XCTAssertEqual(outcome.attention, .unsafeSource, "accepted \(kind)")
            XCTAssertEqual(outcome.finalOffset, 0)
        }
    }

    func testPathSwapAndAppendAfterOpenCannotRedirectOrExtendScan() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.jsonl")
        let retained = directory.appending(path: "retained.jsonl")
        let original = claudeLine(
            sessionID: "original-source",
            requestID: "request-a",
            messageID: "message-a"
        )
        let appended = claudeLine(
            sessionID: "original-source",
            requestID: "request-b",
            messageID: "message-b"
        )
        let replacement = claudeLine(
            sessionID: "replacement-source",
            requestID: "request-z",
            messageID: "message-z"
        )
        try Data("\(original)\n".utf8).write(to: source)
        let ledger = ScannerTestLedger()
        let scanner = IncrementalScanner(
            ledger: ledger,
            sourceOperation: { operation in
                guard operation == .didOpenSource else { return }
                try FileManager.default.moveItem(at: source, to: retained)
                let handle = try FileHandle(forWritingTo: retained)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("\(appended)\n".utf8))
                try handle.close()
                try Data("\(replacement)\n".utf8).write(to: source)
            }
        )

        let outcome = try await scanner.scan(file: source, provider: .claudeCode, calendar: calendar)
        let commits = await ledger.capturedSuccessfulCommits()
        let expectedFingerprint = await ledger.sourceFingerprint(
            provider: .claudeCode,
            stableID: "original-source"
        )

        XCTAssertEqual(outcome.committedUsageRecords, 1)
        XCTAssertEqual(outcome.finalOffset, Int64(Data("\(original)\n".utf8).count))
        XCTAssertEqual(commits.flatMap(\.usage).count, 1)
        XCTAssertEqual(commits.first?.usage.first?.stableSourceID, expectedFingerprint)
    }

    private func claudeLine(
        sessionID: String = "session-a",
        requestID: String,
        messageID: String
    ) -> String {
        #"{"type":"assistant","timestamp":"2026-08-05T10:00:00.000Z","sessionId":"\#(sessionID)","requestId":"\#(requestID)","message":{"id":"\#(messageID)","model":"claude-opus-test","usage":{"input_tokens":100,"cache_creation_input_tokens":30,"cache_read_input_tokens":40,"output_tokens":20,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":20}}}}"#
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

    private func isOpaqueDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private func sqliteStorageBytes(database: URL) throws -> Data {
        let candidates = [
            database,
            URL(fileURLWithPath: database.path + "-wal"),
            URL(fileURLWithPath: database.path + "-shm")
        ]
        return try candidates.reduce(into: Data()) { bytes, candidate in
            guard FileManager.default.fileExists(atPath: candidate.path) else { return }
            bytes.append(try Data(contentsOf: candidate))
        }
    }
}
