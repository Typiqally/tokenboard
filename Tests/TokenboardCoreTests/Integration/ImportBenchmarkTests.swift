import Foundation
import XCTest
@testable import TokenboardCore

final class ImportBenchmarkTests: XCTestCase {
    func testImportsFiveThousandOneHundredFilesIdempotently() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TOKENBOARD_RUN_BENCHMARK"] == "1",
            "Set TOKENBOARD_RUN_BENCHMARK=1 to run the import benchmark"
        )

        let benchmark = try await BenchmarkImportEnvironment.make(
            claudeLogCount: 2_000,
            codexLogCount: 3_100
        )
        defer { benchmark.removeTemporaryFiles() }

        let firstPassCommitted = try await benchmark.importAll()
        let secondPassCommitted = try await benchmark.importAll()
        let rows = try await benchmark.ledger.usageRows(
            in: nil,
            calendar: benchmark.calendar
        )

        XCTAssertEqual(firstPassCommitted, 5_100)
        XCTAssertEqual(secondPassCommitted, 0)
        XCTAssertFalse(rows.isEmpty)
        try await benchmark.ledger.shutdown()
    }
}

private struct BenchmarkImportEnvironment {
    let root: URL
    let claudeLogs: [URL]
    let codexLogs: [URL]
    let ledger: SQLiteLedger
    let scanner: IncrementalScanner
    let calendar: Calendar

    static func make(claudeLogCount: Int, codexLogCount: Int) async throws -> Self {
        let root = canonicalTestTemporaryDirectory
            .appending(path: "tokenboard-import-benchmark-\(UUID().uuidString)")
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: root)
            }
        }
        let claudeRoot = root.appending(path: "claude", directoryHint: .isDirectory)
        let codexRoot = root.appending(path: "codex", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)

        var claudeLogs: [URL] = []
        claudeLogs.reserveCapacity(claudeLogCount)
        for index in 0..<claudeLogCount {
            let sessionID = "claude-benchmark-\(index)"
            let log = claudeRoot.appending(path: "\(index).jsonl")
            let record = #"{"type":"assistant","timestamp":"2026-08-05T10:00:00.000Z","sessionId":"\#(sessionID)","requestId":"request-0","message":{"id":"message-0","model":"claude-benchmark","usage":{"input_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":1,"output_tokens":3}}}"#
            try Data("\(record)\n".utf8).write(to: log)
            claudeLogs.append(log)
        }

        var codexLogs: [URL] = []
        codexLogs.reserveCapacity(codexLogCount)
        for index in 0..<codexLogCount {
            let sessionID = "codex-benchmark-\(index)"
            let log = codexRoot.appending(path: "\(index).jsonl")
            let records = """
            {"type":"session_meta","payload":{"id":"\(sessionID)"}}
            {"type":"turn_context","payload":{"model":"gpt-benchmark"}}
            {"timestamp":"2026-08-05T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":3,"cached_input_tokens":1,"output_tokens":2,"total_tokens":5}}}}

            """
            try Data(records.utf8).write(to: log)
            codexLogs.append(log)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        calendar.firstWeekday = 2
        let ledger = try SQLiteLedger(
            databaseURL: root.appending(path: "ledger.sqlite"),
            backupDirectory: root.appending(path: "Backups", directoryHint: .isDirectory)
        )
        try await ledger.migrate()

        completed = true
        return Self(
            root: root,
            claudeLogs: claudeLogs,
            codexLogs: codexLogs,
            ledger: ledger,
            scanner: IncrementalScanner(ledger: ledger),
            calendar: calendar
        )
    }

    func importAll() async throws -> Int {
        var committed = 0
        for log in claudeLogs {
            let outcome = try await scanner.scan(
                file: log,
                provider: .claudeCode,
                calendar: calendar
            )
            if let attention = outcome.attention {
                throw BenchmarkImportError.sourceAttention(.claudeCode, attention, log.path)
            }
            committed += outcome.committedUsageRecords
        }
        for log in codexLogs {
            let outcome = try await scanner.scan(
                file: log,
                provider: .codex,
                calendar: calendar
            )
            if let attention = outcome.attention {
                throw BenchmarkImportError.sourceAttention(.codex, attention, log.path)
            }
            committed += outcome.committedUsageRecords
        }
        return committed
    }

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum BenchmarkImportError: Error {
    case sourceAttention(Provider, ScanOutcome.Attention, String)
}
