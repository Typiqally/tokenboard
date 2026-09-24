import Foundation
import XCTest
@testable import TokenboardCore

final class UsageQueryServiceTests: XCTestCase {
    func testTokenScopesPartitionCountsCostsAndUnpricedUsage() async throws {
        let metrics: [UsageMetric] = [.inputUncached, .inputCacheRead, .inputCacheWrite,
                                     .inputCacheWrite5m, .inputCacheWrite1h, .inputUnclassified, .output]
        let ledger = QueryTestLedger(rows: metrics.map {
            row(day: "2026-08-05", quantity: 100, metric: $0)
        } + [row(day: "2026-08-05", quantity: 999, metric: .detailReasoningOutput)])
        let service = UsageQueryService(ledger: ledger)
        var summaries: [UsageTokenScope: UsageSummary] = [:]
        for scope in UsageTokenScope.allCases {
            summaries[scope] = try await service.summary(
                period: .today, now: date("2026-08-05T12:00:00Z"),
                calendar: amsterdamCalendar(), tokenScope: scope
            )
            XCTAssertEqual(summaries[scope]?.tokenScope, scope)
        }
        let all = try XCTUnwrap(summaries[.all])
        let input = try XCTUnwrap(summaries[.input])
        let output = try XCTUnwrap(summaries[.output])
        XCTAssertEqual(input.tokenTotal, 600)
        XCTAssertEqual(output.tokenTotal, 100)
        XCTAssertEqual(all.tokenTotal, input.tokenTotal + output.tokenTotal)
        XCTAssertEqual(all.knownAPIEquivalentUSD, input.knownAPIEquivalentUSD + output.knownAPIEquivalentUSD)
        XCTAssertEqual(input.unpricedTokens, 500)
        XCTAssertEqual(output.unpricedTokens, 100)
        XCTAssertEqual(output.unpricedUsage.map(\.tokenCount), [100])
        XCTAssertEqual(all.allTokenUnpricedTokens, 600)
        XCTAssertEqual(input.allTokenUnpricedTokens, 600)
    }

    func testEmptyOutputScopeExcludesUnpricedInputFromItsEstimate() async throws {
        let ledger = QueryTestLedger(rows: [row(day: "2026-08-05", quantity: 100, model: "unknown-model")])
        let summary = try await UsageQueryService(ledger: ledger).summary(
            period: .today, now: date("2026-08-05T12:00:00Z"),
            calendar: amsterdamCalendar(), tokenScope: .output
        )
        XCTAssertEqual(summary.tokenTotal, 0)
        XCTAssertEqual(summary.knownAPIEquivalentUSD, 0)
        XCTAssertEqual(summary.unpricedTokens, 0)
        XCTAssertTrue(summary.unpricedUsage.isEmpty)
        XCTAssertEqual(summary.allTokenUnpricedTokens, 100)
        XCTAssertNil(MenuPresentation(summary: summary, displayMetric: .tokens).unpricedTitle)
    }

    func testSummaryIncludesOnlyUnpricedModelsInTheSelectedPeriod() async throws {
        let ledger = QueryTestLedger(rows: [
            row(day: "2026-08-04", quantity: 900, model: "gpt-older-missing"),
            row(day: "2026-08-05", quantity: 200),
            row(day: "2026-08-05", quantity: 300, model: "gpt-missing"),
            row(day: "2026-08-05", quantity: 100, metric: .output)
        ])
        let result = try await UsageQueryService(ledger: ledger).summary(
            period: .today,
            now: date("2026-08-05T12:00:00Z"),
            calendar: amsterdamCalendar()
        )

        XCTAssertEqual(result.tokenTotal, 600)
        XCTAssertEqual(result.unpricedTokens, 400)
        XCTAssertEqual(result.unpricedUsage.map(\.observedModelID), ["gpt-missing", "gpt-observed"])
        XCTAssertEqual(result.unpricedUsage.map(\.reason), [.missingAlias, .missingRate])
        XCTAssertEqual(result.unpricedUsage.map(\.tokenCount), [300, 100])
        let pricingCalls = await ledger.pricingSnapshotCallCount()
        let queryCount = await ledger.usageQueryCount()
        XCTAssertEqual(pricingCalls, 1)
        XCTAssertEqual(queryCount, 1)
    }

    func testThisWeekUsesMondayBoundaryAndPreservesPeriod() async throws {
        let calendar = amsterdamCalendar(firstWeekday: 1)
        let ledger = QueryTestLedger(rows: [
            row(day: "2026-08-02", quantity: 100),
            row(day: "2026-08-03", quantity: 200),
            row(day: "2026-08-04", quantity: 300)
        ])
        let service = UsageQueryService(ledger: ledger)

        let result = try await service.summary(
            period: .thisWeek,
            now: date("2026-08-05T12:00:00Z"),
            calendar: calendar
        )

        XCTAssertEqual(result.period, .thisWeek)
        XCTAssertEqual(result.tokenTotal, 500)
        XCTAssertEqual(result.knownAPIEquivalentUSD, Decimal(string: "0.001"))
        XCTAssertEqual(result.unpricedTokens, 0)
        XCTAssertEqual(result.exchangeRates?.rates[.eur], Decimal(string: "0.8"))
        let pricingCalls = await ledger.pricingSnapshotCallCount()
        let queryCount = await ledger.usageQueryCount()
        let timeZone = await ledger.lastCalendarTimeZoneIdentifier()
        let firstWeekday = await ledger.lastCalendarFirstWeekday()
        let intervalStart = await ledger.lastIntervalStartDay()
        XCTAssertEqual(pricingCalls, 1)
        XCTAssertEqual(queryCount, 1)
        XCTAssertEqual(timeZone, "Europe/Amsterdam")
        XCTAssertEqual(firstWeekday, 1)
        XCTAssertEqual(intervalStart, "2026-08-03")
    }

    func testAllTimePassesNilAndIncludesEveryRow() async throws {
        let ledger = QueryTestLedger(rows: [
            row(day: "2026-08-02", quantity: 100),
            row(day: "2026-08-03", quantity: 200),
            row(day: "2026-08-04", quantity: 300)
        ])
        let service = UsageQueryService(ledger: ledger)

        let result = try await service.summary(
            period: .allTime,
            now: date("2026-08-05T12:00:00Z"),
            calendar: amsterdamCalendar()
        )

        XCTAssertEqual(result.period, .allTime)
        XCTAssertEqual(result.tokenTotal, 600)
        let pricingCalls = await ledger.pricingSnapshotCallCount()
        let usedNilInterval = await ledger.lastQueryUsedNilInterval()
        XCTAssertEqual(pricingCalls, 1)
        XCTAssertEqual(usedNilInterval, true)
    }

    func testBuddhistCalendarKeepsItsWeekBoundaryButQueriesGregorianDayKeys() async throws {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.locale = Locale(identifier: "th_TH")
        buddhist.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        buddhist.firstWeekday = 1
        let ledger = QueryTestLedger(rows: [
            row(day: "2026-08-02", quantity: 100, calendar: buddhist),
            row(day: "2026-08-03", quantity: 200, calendar: buddhist),
            row(day: "2026-08-04", quantity: 300, calendar: buddhist)
        ])

        let result = try await UsageQueryService(ledger: ledger).summary(
            period: .thisWeek,
            now: date("2026-08-05T12:00:00Z"),
            calendar: buddhist
        )
        let intervalStart = await ledger.lastIntervalStartDay()

        XCTAssertEqual(result.period, .thisWeek)
        XCTAssertEqual(result.tokenTotal, 500)
        XCTAssertEqual(result.knownAPIEquivalentUSD, Decimal(string: "0.001"))
        XCTAssertEqual(result.unpricedTokens, 0)
        XCTAssertEqual(intervalStart, "2026-08-03")
    }

    func testSummaryReportsAgentActivityForThePeriodWithCoverageAgainstStoredTokens() async throws {
        let calendar = amsterdamCalendar()
        let ledger = QueryTestLedger(
            rows: [
                row(day: "2026-08-05", quantity: 200),
                row(day: "2026-08-05", quantity: 100, metric: .output),
                row(day: "2026-08-05", quantity: 400, model: "gpt-uncounted")
            ],
            agentActivity: [
                activity(day: "2026-08-04", counter: .tasks, quantity: 9),
                activity(day: "2026-08-05", counter: .tasks, quantity: 2),
                activity(day: "2026-08-05", counter: .toolCalls, quantity: 7),
                activity(day: "2026-08-05", counter: .requests, quantity: 3),
                activity(day: "2026-08-05", counter: .contextTokens, quantity: 240),
                activity(day: "2026-08-05", counter: .contextPeak, quantity: 120),
                activity(day: "2026-08-05", counter: .activityTokens, quantity: 300)
            ]
        )

        let result = try await UsageQueryService(ledger: ledger).summary(
            period: .today,
            now: date("2026-08-05T12:00:00Z"),
            calendar: calendar
        )

        let activity = result.agentActivity
        XCTAssertEqual(activity.totals.tasks, 2)
        XCTAssertEqual(activity.totals.toolCalls, 7)
        XCTAssertEqual(activity.totals.tokensPerTask, 150)
        XCTAssertEqual(activity.totals.averageContext, 80)
        XCTAssertEqual(activity.coverage, AgentActivityCoverage(tokenTotal: 700, activityTokens: 300))
        XCTAssertEqual(activity.coverage.state, .partial)
        XCTAssertEqual(activity.models.map(\.observedModelID), ["gpt-uncounted", "gpt-observed"])
        XCTAssertEqual(activity.models.map(\.coverage.state), [.notCovered, .complete])
        XCTAssertEqual(activity.models.last?.totals.tokensPerTask, 150)
    }

    private func activity(
        day value: String,
        counter: AgentActivityCounter,
        quantity: Int64,
        model: String = "gpt-observed"
    ) -> AgentActivityRow {
        AgentActivityRow(
            localDay: localDay(value, calendar: amsterdamCalendar()),
            provider: .codex,
            observedModelID: model,
            counter: counter,
            quantity: quantity
        )
    }

    private func row(
        day value: String,
        quantity: Int64,
        model: String = "gpt-observed",
        metric: UsageMetric = .inputUncached,
        calendar: Calendar? = nil
    ) -> DailyUsageRow {
        DailyUsageRow(
            localDay: localDay(value, calendar: calendar ?? amsterdamCalendar()),
            provider: .codex,
            observedModelID: model,
            metric: metric,
            aggregation: .additive,
            quantity: quantity
        )
    }

    private func localDay(_ value: String, calendar: Calendar) -> LocalDay {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return LocalDay(date: formatter.date(from: value)!, calendar: calendar)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func amsterdamCalendar(firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        calendar.firstWeekday = firstWeekday
        return calendar
    }
}

private enum QueryTestLedgerError: Error {
    case unsupported
}

private actor QueryTestLedger: LedgerStore {
    private let rows: [DailyUsageRow]
    private let agentActivity: [AgentActivityRow]
    private var pricingCalls = 0
    private var queryIntervals: [DateInterval?] = []
    private var queryCalendars: [Calendar] = []

    init(rows: [DailyUsageRow], agentActivity: [AgentActivityRow] = []) {
        self.rows = rows
        self.agentActivity = agentActivity
    }

    func agentActivityRows(in interval: DateInterval?, calendar: Calendar) async -> [AgentActivityRow] {
        guard let interval else { return agentActivity }
        let first = LocalDay(date: interval.start, calendar: calendar).value
        let lastDate = calendar.date(byAdding: .day, value: -1, to: interval.end)!
        let last = LocalDay(date: lastDate, calendar: calendar).value
        return agentActivity.filter { $0.localDay.value >= first && $0.localDay.value <= last }
    }

    func migrate() {}

    func commit(
        _ usage: [NormalizedUsage],
        agentActivity: [AgentActivityObservation],
        skipped: [SkippedRecord],
        checkpoint: SourceCheckpoint,
        calendar: Calendar
    ) throws {
        throw QueryTestLedgerError.unsupported
    }

    func agentActivityBackfillOffset(for fingerprint: String) throws -> Int64? {
        throw QueryTestLedgerError.unsupported
    }

    func commitAgentActivityBackfill(
        _ rows: [AgentActivityRow],
        fingerprint: String,
        expectedOffset: Int64
    ) throws {
        throw QueryTestLedgerError.unsupported
    }

    func backfillActivitySlices(
        _ observations: [ActivityObservation],
        calendar: Calendar
    ) throws {
        throw QueryTestLedgerError.unsupported
    }

    func usageRows(in interval: DateInterval?, calendar: Calendar) -> [DailyUsageRow] {
        queryIntervals.append(interval)
        queryCalendars.append(calendar)
        guard let interval else { return rows }
        let first = LocalDay(date: interval.start, calendar: calendar).value
        let lastDate = calendar.date(byAdding: .day, value: -1, to: interval.end)!
        let last = LocalDay(date: lastDate, calendar: calendar).value
        return rows.filter { $0.localDay.value >= first && $0.localDay.value <= last }
    }

    func checkpoint(for fingerprint: String) throws -> SourceCheckpoint? {
        throw QueryTestLedgerError.unsupported
    }

    func sourceFingerprint(provider: Provider, stableID: String) throws -> String {
        throw QueryTestLedgerError.unsupported
    }

    func recordIdentityHash(_ value: String) throws -> String {
        throw QueryTestLedgerError.unsupported
    }

    func pricingSnapshot() -> PricingSnapshot {
        pricingCalls += 1
        return PricingSnapshot(
            catalogIDs: ["test"],
            rates: [StoredPriceRate(
                provider: .codex,
                canonicalModelID: "gpt-canonical",
                metric: .inputUncached,
                usdPerMillion: Decimal(string: "2")!,
                effectiveFrom: "2026-01-01",
                effectiveTo: nil,
                provenanceURL: URL(string: "https://openai.com/api/pricing/")!,
                verifiedAt: "2026-08-05"
            )],
            aliases: [StoredModelAlias(
                provider: .codex,
                observedModelID: "gpt-observed",
                canonicalModelID: "gpt-canonical",
                effectiveFrom: "2026-01-01",
                effectiveTo: nil
            )],
            exchangeRateSnapshots: [ExchangeRateSnapshot(
                catalogID: "test",
                effectiveDate: "2026-08-05",
                verifiedAt: "2026-08-05",
                provenanceURL: URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!,
                rates: [.usd: 1, .eur: Decimal(string: "0.8")!]
            )]
        )
    }

    func latestAppliedPricingCatalogJSON() throws -> Data? {
        throw QueryTestLedgerError.unsupported
    }

    func applyPricingCatalog(
        _ catalog: ValidatedPricingCatalog,
        canonicalJSON: Data,
        origin: String,
        validationSummary: String
    ) throws {
        throw QueryTestLedgerError.unsupported
    }

    func pricingSnapshotCallCount() -> Int { pricingCalls }
    func usageQueryCount() -> Int { queryIntervals.count }
    func lastCalendarTimeZoneIdentifier() -> String? { queryCalendars.last?.timeZone.identifier }
    func lastCalendarFirstWeekday() -> Int? { queryCalendars.last?.firstWeekday }
    func lastQueryUsedNilInterval() -> Bool { queryIntervals.last.map { $0 == nil } ?? false }

    func lastIntervalStartDay() -> String? {
        guard let interval = queryIntervals.last ?? nil, let calendar = queryCalendars.last else { return nil }
        return LocalDay(date: interval.start, calendar: calendar).value
    }
}
