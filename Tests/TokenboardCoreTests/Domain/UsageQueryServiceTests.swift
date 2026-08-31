import Foundation
import XCTest
@testable import TokenboardCore

final class UsageQueryServiceTests: XCTestCase {
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

    private func row(
        day value: String,
        quantity: Int64,
        calendar: Calendar? = nil
    ) -> DailyUsageRow {
        DailyUsageRow(
            localDay: localDay(value, calendar: calendar ?? amsterdamCalendar()),
            provider: .codex,
            observedModelID: "gpt-observed",
            metric: .inputUncached,
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
    private var pricingCalls = 0
    private var queryIntervals: [DateInterval?] = []
    private var queryCalendars: [Calendar] = []

    init(rows: [DailyUsageRow]) {
        self.rows = rows
    }

    func migrate() {}

    func commit(
        _ usage: [NormalizedUsage],
        skipped: [SkippedRecord],
        checkpoint: SourceCheckpoint,
        calendar: Calendar
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
