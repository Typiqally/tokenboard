import Foundation
import XCTest
@testable import TokenboardApp
@testable import TokenboardCore

final class WorkPatternInsightPresentationTests: XCTestCase {
    func testQualifiedRangePresentsStableNeutralInsightSlots() throws {
        let snapshot = try makeSnapshot(activity: [
            slice("2026-08-03T07:00:00Z", provider: .codex),
            slice("2026-08-03T07:10:00Z", provider: .codex),
            slice("2026-08-04T07:00:00Z", provider: .claudeCode),
            slice("2026-08-04T08:00:00Z", provider: .codex),
            slice("2026-08-05T07:00:00Z", provider: .codex),
            slice("2026-08-06T07:00:00Z", provider: .claudeCode),
            slice("2026-08-06T07:15:00Z", provider: .codex),
        ])

        XCTAssertEqual(
            WorkPatternInsightPresentation.make(
                snapshot,
                range: .sevenDays,
                provider: nil
            ),
            WorkPatternInsightPresentation(rows: [
                WorkPatternInsightRow(
                    kind: .rhythm,
                    title: "Most estimated focus landed between 09:00 and 11:00.",
                    detail: "Middle 50%: first activity 09:00–09:00 · last activity 09:00–09:15",
                    isLearning: false
                ),
                WorkPatternInsightRow(
                    kind: .blocks,
                    title: "Focus blocks were shorter than 30 minutes in this range.",
                    detail: "5–10m: 3 · 15–25m: 2 · 30–55m: 0 · 60m+: 0",
                    isLearning: false
                ),
                WorkPatternInsightRow(
                    kind: .aiInteraction,
                    title: "Codex-only blocks were the most common.",
                    detail: "Claude only: 1 · Codex only: 3 · Both tools: 1",
                    isLearning: false
                ),
            ])
        )
    }

    func testSparseRangeKeepsAllSlotsInLearningState() throws {
        let snapshot = try makeSnapshot(activity: [slice("2026-08-03T07:00:00Z")])

        let presentation = try XCTUnwrap(WorkPatternInsightPresentation.make(
            snapshot,
            range: .sevenDays,
            provider: nil
        ))

        XCTAssertEqual(presentation.rows.map(\.kind), [.rhythm, .blocks, .aiInteraction])
        XCTAssertEqual(presentation.rows.map(\.isLearning), [true, true, true])
        XCTAssertEqual(presentation.rows.map(\.detail), [
            "3 active days needed · 1 recorded",
            "5 focus blocks needed · 1 recorded",
            "5 focus blocks needed · 1 recorded",
        ])
    }

    func testProviderFilterUsesCadenceAfterFiveRecordedGaps() throws {
        let snapshot = try makeSnapshot(activity: [
            slice("2026-08-03T07:00:00Z"),
            slice("2026-08-03T07:05:00Z"),
            slice("2026-08-03T07:10:00Z"),
            slice("2026-08-03T07:15:00Z"),
            slice("2026-08-03T07:20:00Z"),
            slice("2026-08-03T07:25:00Z"),
        ])

        let presentation = try XCTUnwrap(WorkPatternInsightPresentation.make(
            snapshot,
            range: .sevenDays,
            provider: .codex
        ))
        let interaction = try XCTUnwrap(
            presentation.rows.first { $0.kind == .aiInteraction }
        )

        XCTAssertEqual(interaction, WorkPatternInsightRow(
            kind: .aiInteraction,
            title: "Recorded interactions were typically 5 minutes apart.",
            detail: "Based on 5 gaps within focus blocks.",
            isLearning: false
        ))
    }

    func testTodayDoesNotGenerateRecurringInsights() throws {
        let snapshot = try makeSnapshot(activity: [slice("2026-08-03T07:00:00Z")])

        XCTAssertNil(WorkPatternInsightPresentation.make(
            snapshot,
            range: .today,
            provider: nil
        ))
    }

    private func makeSnapshot(activity: [ActivitySliceRow]) throws -> WorkPatternSnapshot {
        let current = interval("2026-08-02T22:00:00Z", "2026-08-09T22:00:00Z")
        return try WorkPatternCalculator().make(
            currentRows: [],
            currentActivity: activity,
            previousActivity: [],
            currentInterval: current,
            previousInterval: interval("2026-07-26T22:00:00Z", "2026-08-02T22:00:00Z"),
            coverageStart: date("2026-07-01T00:00:00Z"),
            now: current.end.addingTimeInterval(-1),
            calendar: calendar()
        )
    }

    private func slice(
        _ value: String,
        provider: Provider = .codex
    ) -> ActivitySliceRow {
        let timestamp = date(value)
        return ActivitySliceRow(
            sliceStart: timestamp,
            localDay: LocalDay(date: timestamp, calendar: calendar()),
            provider: provider
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func interval(_ start: String, _ end: String) -> DateInterval {
        DateInterval(start: date(start), end: date(end))
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        calendar.firstWeekday = 2
        return calendar
    }
}
