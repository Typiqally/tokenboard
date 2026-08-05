import Foundation
import XCTest
@testable import TokenboardCore

final class UsageModelsTests: XCTestCase {
    func testOnlyReasoningDetailIsNonAdditive() {
        XCTAssertFalse(UsageMetric.detailReasoningOutput.countsTowardTokenTotal)
        for metric in UsageMetric.allCases where metric != .detailReasoningOutput {
            XCTAssertTrue(metric.countsTowardTokenTotal)
        }
    }

    func testNormalizedUsageRejectsNegativeCounts() {
        XCTAssertThrowsError(try NormalizedUsage(
            provider: .codex,
            observedModelID: "gpt-test",
            timestamp: Date(timeIntervalSince1970: 0),
            metrics: [.output: -1],
            stableSourceID: "session",
            stableUsageID: "usage"
        ))
    }

    func testNormalizedUsageOmitsZeroMetricsAndExcludesReasoningDetailFromTotal() throws {
        let usage = try NormalizedUsage(
            provider: .claudeCode,
            observedModelID: "claude-test",
            timestamp: Date(timeIntervalSince1970: 0),
            metrics: [.inputUncached: 100, .output: 25, .detailReasoningOutput: 20, .inputCacheRead: 0],
            stableSourceID: "session",
            stableUsageID: nil
        )

        XCTAssertEqual(usage.metrics, [.inputUncached: 100, .output: 25, .detailReasoningOutput: 20])
        XCTAssertEqual(usage.tokenTotal, 125)
    }

    func testNormalizedUsageRejectsAnEmptyModelID() {
        XCTAssertThrowsError(try NormalizedUsage(
            provider: .codex,
            observedModelID: "",
            timestamp: Date(timeIntervalSince1970: 0),
            metrics: [:],
            stableSourceID: "session",
            stableUsageID: nil
        ))
    }
}
