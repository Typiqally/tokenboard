import Foundation
import XCTest
@testable import TokenboardCore

final class UsageHistoryQueryServiceTests: XCTestCase {
    func testTodayHistoryBuildsHourlyProgressionAndKeepsPreUpgradeUsageAsBaseline() async throws {
        let calendar = amsterdamCalendar()
        let ledger = HistoryQueryTestLedger(
            rows: [
                row(day: "2026-08-10", provider: .codex, model: "gpt-5", metric: .output, quantity: 100),
                row(day: "2026-08-11", provider: .codex, model: "gpt-5", metric: .inputUncached, quantity: 125),
                row(day: "2026-08-11", provider: .claudeCode, model: "claude-opus-4-1", metric: .output, quantity: 50),
            ],
            hourlyRows: [
                hourlyRow(
                    at: "2026-08-11T07:00:00Z",
                    provider: .codex,
                    model: "gpt-5",
                    metric: .inputUncached,
                    quantity: 100
                ),
                hourlyRow(
                    at: "2026-08-11T14:00:00Z",
                    provider: .claudeCode,
                    model: "claude-opus-4-1",
                    metric: .output,
                    quantity: 50
                ),
            ],
            activityRows: [
                activityRow(at: "2026-08-11T07:00:00Z", provider: .codex),
                activityRow(at: "2026-08-11T14:00:00Z", provider: .claudeCode),
            ]
        )

        let snapshot = try await UsageQueryService(ledger: ledger).history(
            range: .today,
            now: date("2026-08-11T20:00:00Z"),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.range, .today)
        XCTAssertEqual(snapshot.points.count, 24)
        let totalsByHour = Dictionary(uniqueKeysWithValues: snapshot.points.map { point in
            (calendar.component(.hour, from: point.hourStart!), point.tokenTotal)
        })
        XCTAssertEqual(totalsByHour[0], 25)
        XCTAssertEqual(totalsByHour[9], 100)
        XCTAssertEqual(totalsByHour[16], 50)
        XCTAssertEqual(snapshot.points.reduce(0) { $0 + $1.tokenTotal }, 175)
        XCTAssertEqual(snapshot.breakdown.tokenTotal, 175)
        XCTAssertEqual(snapshot.comparison.previousTokenTotal, 100)
        XCTAssertEqual(snapshot.comparison.percentChange, 75)
        XCTAssertEqual(snapshot.workPatterns?.totalFocusMinutes, 10)
        XCTAssertEqual(snapshot.workPatterns?.focusSessionCount, 2)
        XCTAssertEqual(snapshot.workPatterns?.activeDayCount, 1)
        XCTAssertEqual(snapshot.workPatterns?.volumePeakHour?.hour, 9)
        XCTAssertEqual(snapshot.workPatterns?.volumePeakHour?.tokenTotal, 100)
    }

    func testHistoryBuildsContinuousDailySeriesComparisonAndBreakdowns() async throws {
        let calendar = amsterdamCalendar()
        let ledger = HistoryQueryTestLedger(rows: [
            row(day: "2026-07-29", provider: .codex, model: "gpt-5", metric: .inputUncached, quantity: 100),
            row(day: "2026-08-04", provider: .claudeCode, model: "claude-opus-4-1", metric: .output, quantity: 100),
            row(day: "2026-08-05", provider: .codex, model: "gpt-5", metric: .inputUncached, quantity: 100),
            row(day: "2026-08-06", provider: .codex, model: "gpt-5", metric: .inputUnclassified, quantity: 10),
            row(day: "2026-08-07", provider: .codex, model: "gpt-5", metric: .inputCacheRead, quantity: 20),
            row(day: "2026-08-08", provider: .claudeCode, model: "claude-opus-4-1", metric: .inputCacheWrite, quantity: 30),
            row(day: "2026-08-09", provider: .claudeCode, model: "claude-opus-4-1", metric: .output, quantity: 40),
            row(day: "2026-08-10", provider: .claudeCode, model: "claude-opus-4-1", metric: .detailReasoningOutput, quantity: 999),
            row(day: "2026-08-11", provider: .codex, model: "gpt-5", metric: .output, quantity: 50)
        ])

        let snapshot = try await UsageQueryService(ledger: ledger).history(
            range: .sevenDays,
            now: date("2026-08-11T10:00:00Z"),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.range, .sevenDays)
        XCTAssertNil(snapshot.provider)
        XCTAssertEqual(snapshot.points.count, 7)
        XCTAssertEqual(snapshot.points.first?.localDay, localDay("2026-08-05"))
        XCTAssertEqual(snapshot.points.first?.tokenTotal, 100)
        XCTAssertEqual(snapshot.points.first?.breakdown?.providers, [
            ProviderUsageBreakdown(provider: .codex, tokenTotal: 100)
        ])
        XCTAssertEqual(snapshot.points.first?.breakdown?.tokenTypes, [
            TokenTypeUsageBreakdown(category: .input, tokenTotal: 100),
            TokenTypeUsageBreakdown(category: .cache, tokenTotal: 0),
            TokenTypeUsageBreakdown(category: .output, tokenTotal: 0)
        ])
        XCTAssertEqual(snapshot.points[1].tokenTotal, 10)
        XCTAssertEqual(snapshot.points[5].tokenTotal, 0)
        XCTAssertEqual(snapshot.points.last?.localDay.value, "2026-08-11")
        XCTAssertEqual(snapshot.points.last?.tokenTotal, 50)

        XCTAssertEqual(snapshot.comparison.currentTokenTotal, 250)
        XCTAssertEqual(snapshot.comparison.previousTokenTotal, 200)
        XCTAssertEqual(snapshot.comparison.tokenDelta, 50)
        XCTAssertEqual(snapshot.comparison.percentChange, Decimal(25))

        XCTAssertEqual(snapshot.breakdown.tokenTotal, 250)
        XCTAssertEqual(snapshot.breakdown.knownAPIEquivalentUSD, .zero)
        XCTAssertEqual(snapshot.breakdown.unpricedTokens, 250)
        XCTAssertEqual(snapshot.breakdown.providers, [
            ProviderUsageBreakdown(provider: .codex, tokenTotal: 180),
            ProviderUsageBreakdown(provider: .claudeCode, tokenTotal: 70)
        ])
        XCTAssertEqual(snapshot.breakdown.models, [
            ModelUsageBreakdown(provider: .codex, observedModelID: "gpt-5", tokenTotal: 180),
            ModelUsageBreakdown(provider: .claudeCode, observedModelID: "claude-opus-4-1", tokenTotal: 70)
        ])
        XCTAssertEqual(snapshot.breakdown.tokenTypes, [
            TokenTypeUsageBreakdown(category: .input, tokenTotal: 110),
            TokenTypeUsageBreakdown(category: .cache, tokenTotal: 50),
            TokenTypeUsageBreakdown(category: .output, tokenTotal: 90)
        ])

        let recordedInterval = await ledger.lastInterval()
        let interval = try XCTUnwrap(recordedInterval)
        XCTAssertEqual(LocalDay(date: interval.start, calendar: calendar).value, "2026-07-29")
        XCTAssertEqual(LocalDay(
            date: calendar.date(byAdding: .day, value: -1, to: interval.end)!,
            calendar: calendar
        ).value, "2026-08-11")
        let pricingCallCount = await ledger.pricingSnapshotCallCount()
        XCTAssertEqual(pricingCallCount, 1)
    }

    func testHistoryCanBeScopedToOneProvider() async throws {
        let ledger = HistoryQueryTestLedger(rows: [
            row(day: "2026-08-04", provider: .claudeCode, model: "claude-sonnet-4", metric: .output, quantity: 30),
            row(day: "2026-08-05", provider: .codex, model: "gpt-5", metric: .output, quantity: 100),
            row(day: "2026-08-06", provider: .claudeCode, model: "claude-sonnet-4", metric: .output, quantity: 60)
        ])

        let snapshot = try await UsageQueryService(ledger: ledger).history(
            range: .sevenDays,
            now: date("2026-08-11T10:00:00Z"),
            calendar: amsterdamCalendar(),
            provider: .claudeCode
        )

        XCTAssertEqual(snapshot.provider, .claudeCode)
        XCTAssertEqual(snapshot.breakdown.tokenTotal, 60)
        XCTAssertEqual(snapshot.comparison.previousTokenTotal, 30)
        XCTAssertEqual(snapshot.comparison.percentChange, Decimal(100))
        XCTAssertEqual(snapshot.breakdown.providers, [
            ProviderUsageBreakdown(provider: .claudeCode, tokenTotal: 60)
        ])
        XCTAssertEqual(snapshot.points.map(\.tokenTotal), [0, 60, 0, 0, 0, 0, 0])
    }

    func testHistoryUsesNilPercentChangeWhenPreviousPeriodIsZero() async throws {
        let ledger = HistoryQueryTestLedger(rows: [
            row(day: "2026-08-11", provider: .codex, model: "gpt-5", metric: .output, quantity: 25)
        ])

        let snapshot = try await UsageQueryService(ledger: ledger).history(
            range: .thirtyDays,
            now: date("2026-08-11T10:00:00Z"),
            calendar: amsterdamCalendar()
        )

        XCTAssertEqual(snapshot.points.count, 30)
        XCTAssertEqual(snapshot.comparison.tokenDelta, 25)
        XCTAssertNil(snapshot.comparison.percentChange)
    }

    func testBulkHistoryReadsUsageAndPricingOnlyOnce() async throws {
        let ledger = HistoryQueryTestLedger(rows: [])

        let snapshots = try await UsageQueryService(ledger: ledger).history(
            ranges: UsageHistoryRange.allCases,
            now: date("2026-08-11T10:00:00Z"),
            calendar: amsterdamCalendar()
        )

        let usageQueries = await ledger.usageQueryCount()
        let hourlyQueries = await ledger.hourlyUsageQueryCount()
        let activityQueries = await ledger.activitySliceQueryCount()
        let pricingQueries = await ledger.pricingSnapshotCallCount()
        XCTAssertEqual(Set(snapshots.keys), Set(UsageHistoryRange.allCases))
        XCTAssertEqual(usageQueries, 1)
        XCTAssertEqual(hourlyQueries, 1)
        XCTAssertEqual(activityQueries, 1)
        XCTAssertEqual(pricingQueries, 1)
    }

    private func row(
        day value: String,
        provider: Provider,
        model: String,
        metric: UsageMetric,
        quantity: Int64
    ) -> DailyUsageRow {
        DailyUsageRow(
            localDay: localDay(value),
            provider: provider,
            observedModelID: model,
            metric: metric,
            aggregation: metric.aggregation,
            quantity: quantity
        )
    }

    private func hourlyRow(
        at timestamp: String,
        provider: Provider,
        model: String,
        metric: UsageMetric,
        quantity: Int64
    ) -> HourlyUsageRow {
        let hourStart = date(timestamp)
        return HourlyUsageRow(
            hourStart: hourStart,
            localDay: LocalDay(date: hourStart, calendar: amsterdamCalendar()),
            provider: provider,
            observedModelID: model,
            metric: metric,
            aggregation: metric.aggregation,
            quantity: quantity
        )
    }

    private func activityRow(
        at timestamp: String,
        provider: Provider
    ) -> ActivitySliceRow {
        let sliceStart = date(timestamp)
        return ActivitySliceRow(
            sliceStart: sliceStart,
            localDay: LocalDay(date: sliceStart, calendar: amsterdamCalendar()),
            provider: provider
        )
    }

    private func localDay(_ value: String) -> LocalDay {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return LocalDay(date: formatter.date(from: value)!, calendar: amsterdamCalendar())
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func amsterdamCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }
}

private enum HistoryQueryTestLedgerError: Error {
    case unsupported
}

private actor HistoryQueryTestLedger: LedgerStore {
    private let rows: [DailyUsageRow]
    private let hourlyRows: [HourlyUsageRow]
    private let activityRows: [ActivitySliceRow]
    private var queryIntervals: [DateInterval?] = []
    private var pricingCalls = 0
    private var hourlyQueryCount = 0
    private var activityQueryCount = 0

    init(
        rows: [DailyUsageRow],
        hourlyRows: [HourlyUsageRow] = [],
        activityRows: [ActivitySliceRow] = []
    ) {
        self.rows = rows
        self.hourlyRows = hourlyRows
        self.activityRows = activityRows
    }

    func migrate() {}

    func commit(
        _ usage: [NormalizedUsage],
        skipped: [SkippedRecord],
        checkpoint: SourceCheckpoint,
        calendar: Calendar
    ) throws {
        throw HistoryQueryTestLedgerError.unsupported
    }

    func backfillActivitySlices(
        _ observations: [ActivityObservation],
        calendar: Calendar
    ) throws {
        throw HistoryQueryTestLedgerError.unsupported
    }

    func usageRows(in interval: DateInterval?, calendar: Calendar) -> [DailyUsageRow] {
        queryIntervals.append(interval)
        guard let interval else { return rows }
        let first = LocalDay(date: interval.start, calendar: calendar).value
        let finalDate = calendar.date(byAdding: .day, value: -1, to: interval.end)!
        let last = LocalDay(date: finalDate, calendar: calendar).value
        return rows.filter { $0.localDay.value >= first && $0.localDay.value <= last }
    }

    func hourlyUsageRows(
        in interval: DateInterval?,
        calendar: Calendar
    ) -> [HourlyUsageRow] {
        hourlyQueryCount += 1
        guard let interval else { return hourlyRows }
        return hourlyRows.filter { interval.contains($0.hourStart) }
    }

    func activitySliceRows(
        in interval: DateInterval?,
        calendar: Calendar
    ) -> [ActivitySliceRow] {
        activityQueryCount += 1
        guard let interval else { return activityRows }
        return activityRows.filter { interval.contains($0.sliceStart) }
    }

    func activitySliceCoverageStart() -> Date? {
        activityQueryCount += 1
        return activityRows.map(\.sliceStart).min()
    }

    func checkpoint(for fingerprint: String) throws -> SourceCheckpoint? {
        throw HistoryQueryTestLedgerError.unsupported
    }

    func sourceFingerprint(provider: Provider, stableID: String) throws -> String {
        throw HistoryQueryTestLedgerError.unsupported
    }

    func recordIdentityHash(_ value: String) throws -> String {
        throw HistoryQueryTestLedgerError.unsupported
    }

    func pricingSnapshot() -> PricingSnapshot {
        pricingCalls += 1
        return PricingSnapshot(
            catalogIDs: [],
            rates: [],
            aliases: [],
            exchangeRateSnapshots: []
        )
    }

    func latestAppliedPricingCatalogJSON() throws -> Data? {
        throw HistoryQueryTestLedgerError.unsupported
    }

    func applyPricingCatalog(
        _ catalog: ValidatedPricingCatalog,
        canonicalJSON: Data,
        origin: String,
        validationSummary: String
    ) throws {
        throw HistoryQueryTestLedgerError.unsupported
    }

    func lastInterval() -> DateInterval? { queryIntervals.last ?? nil }
    func usageQueryCount() -> Int { queryIntervals.count }
    func hourlyUsageQueryCount() -> Int { hourlyQueryCount }
    func activitySliceQueryCount() -> Int { activityQueryCount }
    func pricingSnapshotCallCount() -> Int { pricingCalls }
}
