import Foundation
import XCTest
@testable import TokenboardCore

final class AgentActivityTests: XCTestCase {
    func testOnlyContextPeakTakesTheMaximum() {
        for counter in AgentActivityCounter.allCases {
            XCTAssertEqual(counter.aggregation == .maximum, counter == .contextPeak, "\(counter)")
        }
    }

    func testContextTokensCountEveryInputMetricAndNoOutput() throws {
        for metric in UsageMetric.allCases {
            XCTAssertEqual(metric.countsTowardContext, metric.rawValue.hasPrefix("input_"), "\(metric)")
        }
        let usage = try usage(metrics: [
            .inputUncached: 10, .inputCacheRead: 20, .inputCacheWrite5m: 3, .inputCacheWrite1h: 4,
            .output: 50, .detailReasoningOutput: 40
        ])
        XCTAssertEqual(usage.contextTokens, 37)
    }

    func testUsageBecomesRequestContextAndActivityTokenCounters() throws {
        var aggregator = AgentActivityAggregator(calendar: calendar)
        try aggregator.add(usage(metrics: [.inputUncached: 100, .inputCacheRead: 900, .output: 20]))
        try aggregator.add(usage(metrics: [.inputUncached: 50, .output: 5], hour: 11))

        XCTAssertEqual(quantities(aggregator.rows), [
            .activityTokens: 1_075,
            .contextPeak: 1_000,
            .contextTokens: 1_050,
            .requests: 2
        ])
    }

    func testResponsesWithoutBilledTokensAreNotRequests() throws {
        var aggregator = AgentActivityAggregator(calendar: calendar)
        try aggregator.add(usage(metrics: [:]))
        try aggregator.add(usage(metrics: [.detailReasoningOutput: 7]))

        XCTAssertTrue(aggregator.isEmpty)
    }

    func testObservationsSumPerLocalDayAndModelAndSkipZeroCounters() throws {
        var aggregator = AgentActivityAggregator(calendar: calendar)
        try aggregator.add(observation(delta: .init(tasks: 1, toolCalls: 3), hour: 8))
        try aggregator.add(observation(delta: .init(toolCalls: 2, linesAdded: 12, linesRemoved: 4), hour: 9))
        try aggregator.add(observation(model: "gpt-other", delta: .init(tasks: 1), hour: 9))
        try aggregator.add(observation(delta: .init(tasks: 1), day: 12, hour: 1))

        let rows = aggregator.rows
        XCTAssertEqual(
            quantities(rows.filter { $0.localDay.value == "2026-08-11" && $0.observedModelID == "gpt-test" }),
            [.tasks: 1, .toolCalls: 5, .linesAdded: 12, .linesRemoved: 4]
        )
        XCTAssertEqual(
            quantities(rows.filter { $0.observedModelID == "gpt-other" }),
            [.tasks: 1]
        )
        XCTAssertEqual(
            quantities(rows.filter { $0.localDay.value == "2026-08-12" }),
            [.tasks: 1]
        )
        XCTAssertEqual(Set(rows.map(\.localDay.timeZoneIdentifier)), ["Europe/Amsterdam"])
    }

    func testLocalDayFollowsTheCalendarTimeZone() throws {
        var aggregator = AgentActivityAggregator(calendar: calendar)
        // 23:30 UTC on 11 August is already 12 August in Amsterdam.
        try aggregator.add(AgentActivityObservation(
            provider: .codex,
            observedModelID: "gpt-test",
            timestamp: Date(timeIntervalSince1970: 1_786_491_000),
            delta: .init(tasks: 1)
        ))
        XCTAssertEqual(aggregator.rows.map(\.localDay.value), ["2026-08-12"])
    }

    func testRowsAreDeterministicallyOrdered() throws {
        var first = AgentActivityAggregator(calendar: calendar)
        var second = AgentActivityAggregator(calendar: calendar)
        let observations = [
            observation(model: "b-model", delta: .init(tasks: 1, toolCalls: 1)),
            observation(model: "a-model", delta: .init(linesAdded: 1)),
            observation(delta: .init(tasks: 2), day: 10)
        ]
        for entry in observations { try first.add(entry) }
        for entry in observations.reversed() { try second.add(entry) }

        XCTAssertEqual(first.rows, second.rows)
        XCTAssertEqual(first.rows.first?.localDay.value, "2026-08-10")
    }

    func testOverflowAndNegativeQuantitiesFailInsteadOfWrapping() throws {
        var aggregator = AgentActivityAggregator(calendar: calendar)
        try aggregator.add(observation(delta: .init(toolCalls: .max)))
        XCTAssertThrowsError(try aggregator.add(observation(delta: .init(toolCalls: 1)))) { error in
            XCTAssertEqual(error as? LedgerError, .quantityOverflow)
        }
        XCTAssertThrowsError(try aggregator.add(observation(delta: .init(linesRemoved: -1)))) { error in
            XCTAssertEqual(error as? AgentActivityError, .negativeQuantity(.linesRemoved))
        }
        XCTAssertThrowsError(try AgentActivityDelta(tasks: .max).adding(.init(tasks: 1)))
        XCTAssertEqual(
            try AgentActivityDelta(tasks: 1, toolCalls: 2).adding(.init(toolCalls: 3, linesAdded: 4)),
            AgentActivityDelta(tasks: 1, toolCalls: 5, linesAdded: 4)
        )
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }

    private func date(day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour))!
    }

    private func usage(metrics: [UsageMetric: Int64], hour: Int = 10) throws -> NormalizedUsage {
        try NormalizedUsage(
            provider: .codex,
            observedModelID: "gpt-test",
            timestamp: date(day: 11, hour: hour),
            metrics: metrics,
            stableSourceID: "source",
            stableUsageID: nil
        )
    }

    private func observation(
        model: String = "gpt-test",
        delta: AgentActivityDelta,
        day: Int = 11,
        hour: Int = 10
    ) -> AgentActivityObservation {
        AgentActivityObservation(
            provider: .codex,
            observedModelID: model,
            timestamp: date(day: day, hour: hour),
            delta: delta
        )
    }

    private func quantities(_ rows: [AgentActivityRow]) -> [AgentActivityCounter: Int64] {
        rows.reduce(into: [:]) { result, row in result[row.counter, default: 0] += row.quantity }
    }
}
