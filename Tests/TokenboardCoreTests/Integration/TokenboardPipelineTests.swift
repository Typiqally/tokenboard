import Foundation
import XCTest
@testable import TokenboardCore

final class TokenboardPipelineTests: XCTestCase {
    func testDeletionRecreationAppendAndRevokePreserveCommittedHistoricalTotals() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let claude = directory.appending(path: "claude.jsonl")
        let codex = directory.appending(path: "codex.jsonl")
        let database = directory.appending(path: "ledger.sqlite")
        let ledger = try SQLiteLedger(
            databaseURL: database,
            backupDirectory: directory.appending(path: "Backups")
        )
        try await ledger.migrate()
        try await ledger.integrityCheck()
        let scanner = IncrementalScanner(ledger: ledger)
        let query = UsageQueryService(ledger: ledger)
        let calendar = pipelineCalendar()
        let claudeOriginal = Data((claudeLine(request: "main", message: "main") + "\n"
            + claudeLine(request: "subagent", message: "subagent") + "\n").utf8)
        let codexOriginal = Data((codexPreamble()
            + codexUsage(input: 50, cached: 10, output: 20)
            + codexUsage(input: 3, cached: 1, output: 2)).utf8)
        try claudeOriginal.write(to: claude)
        try codexOriginal.write(to: codex)

        _ = try await scanner.scan(file: claude, provider: .claudeCode, calendar: calendar)
        _ = try await scanner.scan(file: codex, provider: .codex, calendar: calendar)
        let imported = try await query.summary(period: .allTime, now: pipelineNow(), calendar: calendar)
        XCTAssertEqual(imported.tokenTotal, 455)
        XCTAssertEqual(imported.unpricedTokens, 455)

        let catalog = try historicalCatalog()
        try await ledger.applyPricingCatalog(
            catalog,
            canonicalJSON: catalog.canonicalJSON,
            origin: PricingImportMetadata.agentCandidateOrigin,
            validationSummary: PricingImportMetadata.schemaV1ValidSummary
        )
        let priced = try await query.summary(period: .allTime, now: pipelineNow(), calendar: calendar)
        XCTAssertEqual(priced.tokenTotal, 455)
        XCTAssertEqual(priced.knownAPIEquivalentUSD, Decimal(string: "0.000455"))
        XCTAssertEqual(priced.unpricedTokens, 0)

        try FileManager.default.removeItem(at: claude)
        try FileManager.default.removeItem(at: codex)
        let afterDeletion = try await query.summary(period: .allTime, now: pipelineNow(), calendar: calendar)
        XCTAssertEqual(afterDeletion, priced)

        try claudeOriginal.write(to: claude)
        try codexOriginal.write(to: codex)
        _ = try await scanner.scan(file: claude, provider: .claudeCode, calendar: calendar)
        _ = try await scanner.scan(file: codex, provider: .codex, calendar: calendar)
        let afterIdenticalRecreation = try await query.summary(
            period: .allTime,
            now: pipelineNow(),
            calendar: calendar
        )
        XCTAssertEqual(afterIdenticalRecreation, priced)

        try append(Data(claudeLine(
            request: "background",
            message: "background",
            timestamp: "2026-08-06T10:00:00.000Z"
        ).appending("\n").utf8), to: claude)
        try append(Data(codexUsage(
            input: 6,
            cached: 1,
            output: 4,
            timestamp: "2026-08-06T10:00:00Z"
        ).utf8), to: codex)
        _ = try await scanner.scan(file: claude, provider: .claudeCode, calendar: calendar)
        _ = try await scanner.scan(file: codex, provider: .codex, calendar: calendar)
        let afterAppend = try await query.summary(period: .allTime, now: pipelineNow(), calendar: calendar)
        XCTAssertEqual(afterAppend.tokenTotal, 655)
        XCTAssertEqual(afterAppend.knownAPIEquivalentUSD, Decimal(string: "0.000855"))
        XCTAssertEqual(afterAppend.unpricedTokens, 0)

        var grants = PipelineGrantStore(granted: Set(Provider.allCases))
        let scanDate = pipelineNow()
        let beforeRevoke = grants.health(
            lastSuccessfulScan: scanDate,
            unpricedTokens: afterAppend.unpricedTokens
        )
        grants.revoke(.claudeCode)
        let afterRevoke = grants.health(
            lastSuccessfulScan: scanDate,
            unpricedTokens: afterAppend.unpricedTokens
        )
        let totalsAfterRevoke = try await query.summary(
            period: .allTime,
            now: pipelineNow(),
            calendar: calendar
        )
        XCTAssertEqual(beforeRevoke.claude, .healthy(fileCount: 1, lastUpdated: scanDate))
        XCTAssertEqual(afterRevoke.claude, .notGranted)
        XCTAssertEqual(afterRevoke.codex, beforeRevoke.codex)
        XCTAssertEqual(totalsAfterRevoke, afterAppend)
        try await ledger.shutdown()
    }

    func testCentralHealthMessagesAreDistinctAndContainNoContentOrPaths() {
        let issues: [TokenboardHealth.Issue] = [
            .unknownFormats,
            .staleBookmark,
            .missingRoot,
            .truncatedLog,
            .replacedLog,
            .importFailure,
            .applicationFailure,
            .migrationFailure,
            .integrityFailure,
            .invalidPricingCandidate
        ]
        let messages = issues.map(\.message)

        XCTAssertEqual(Set(messages).count, issues.count)
        for message in messages {
            XCTAssertFalse(message.contains("/Users/"))
            XCTAssertFalse(message.contains("conversation"))
            XCTAssertFalse(message.contains("project"))
        }
    }

    private func pipelineCalendar() -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        value.firstWeekday = 2
        return value
    }

    private func pipelineNow() -> Date {
        ISO8601DateFormatter().date(from: "2026-08-05T12:00:00Z")!
    }

    private func claudeLine(
        request: String,
        message: String,
        timestamp: String = "2026-08-05T10:00:00.000Z"
    ) -> String {
        #"{"type":"assistant","timestamp":"\#(timestamp)","sessionId":"claude-source","requestId":"\#(request)","message":{"id":"\#(message)","model":"claude-test","usage":{"input_tokens":100,"cache_creation_input_tokens":30,"cache_read_input_tokens":40,"output_tokens":20,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":20}}}}"#
    }

    private func codexPreamble() -> String {
        """
        {"type":"session_meta","payload":{"id":"codex-source"}}
        {"type":"turn_context","payload":{"model":"gpt-test"}}

        """
    }

    private func codexUsage(
        input: Int,
        cached: Int,
        output: Int,
        timestamp: String = "2026-08-05T10:00:00Z"
    ) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"total_tokens":\#(input + output)}}}}"# + "\n"
    }

    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func historicalCatalog() throws -> ValidatedPricingCatalog {
        let metrics = [
            UsageMetric.inputUncached,
            .inputCacheRead,
            .inputCacheWrite,
            .inputCacheWrite5m,
            .inputCacheWrite1h,
            .output
        ]
        func prices(_ value: Decimal) -> [String: DecimalString] {
            Dictionary(uniqueKeysWithValues: metrics.map {
                ($0.rawValue, DecimalString(decimal: value))
            })
        }
        return try PricingCatalogValidator().validate(PricingCatalog(
            schemaVersion: 1,
            catalogID: "pipeline-history",
            generatedAt: "2026-08-05T12:00:00Z",
            origin: CatalogOrigin(kind: .officialResearch, url: "https://openai.com/api/pricing/"),
            models: [
                CatalogModel(
                    provider: .claudeCode,
                    canonicalModelID: "claude-test",
                    aliases: [CatalogAlias(
                        observedModelID: "claude-test",
                        effectiveFrom: "2026-01-01",
                        effectiveTo: nil
                    )],
                    rates: historicalRates(
                        prices: prices,
                        provenanceURL: "https://www.anthropic.com/pricing"
                    )
                ),
                CatalogModel(
                    provider: .codex,
                    canonicalModelID: "gpt-test",
                    aliases: [CatalogAlias(
                        observedModelID: "gpt-test",
                        effectiveFrom: "2026-01-01",
                        effectiveTo: nil
                    )],
                    rates: historicalRates(
                        prices: prices,
                        provenanceURL: "https://openai.com/api/pricing/"
                    )
                )
            ]
        ))
    }

    private func historicalRates(
        prices: (Decimal) -> [String: DecimalString],
        provenanceURL: String
    ) -> [CatalogRate] {
        [
            CatalogRate(
                effectiveFrom: "2026-01-01",
                effectiveTo: nil,
                prices: prices(1),
                provenanceURL: provenanceURL,
                verifiedAt: "2026-08-05"
            ),
            CatalogRate(
                effectiveFrom: "2026-08-06",
                effectiveTo: nil,
                prices: prices(2),
                provenanceURL: provenanceURL,
                verifiedAt: "2026-08-06"
            )
        ]
    }
}

private struct PipelineGrantStore {
    var granted: Set<Provider>

    mutating func revoke(_ provider: Provider) {
        granted.remove(provider)
    }

    func health(lastSuccessfulScan: Date, unpricedTokens: Int64) -> TokenboardHealth {
        func source(_ provider: Provider) -> SourceHealth {
            granted.contains(provider)
                ? .healthy(fileCount: 1, lastUpdated: lastSuccessfulScan)
                : .notGranted
        }
        return TokenboardHealth(
            claude: source(.claudeCode),
            codex: source(.codex),
            database: .healthy,
            lastSuccessfulScan: lastSuccessfulScan,
            skippedRecordCount: 0,
            unpricedTokens: unpricedTokens
        )
    }
}
