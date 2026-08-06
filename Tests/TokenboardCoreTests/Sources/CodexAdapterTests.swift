import Foundation
import XCTest
@testable import TokenboardCore

final class CodexAdapterTests: XCTestCase {
    func testUsesSessionAndTurnContextForTokenCount() throws {
        var adapter = CodexAdapter()
        XCTAssertEqual(adapter.consume(line: Data(#"{"type":"session_meta","payload":{"id":"session-a"}}"#.utf8)), .ignored)
        XCTAssertEqual(adapter.consume(line: Data(#"{"type":"turn_context","payload":{"model":"gpt-test"}}"#.utf8)), .ignored)
        let tokenLine = #"{"timestamp":"2026-08-05T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"cache_write_input_tokens":10,"output_tokens":30,"reasoning_output_tokens":5,"total_tokens":130},"total_token_usage":{"input_tokens":500,"cached_input_tokens":120,"cache_write_input_tokens":30,"output_tokens":200,"reasoning_output_tokens":70,"total_tokens":700}}}}"#
        guard case let .usage(parsed) = adapter.consume(line: Data(tokenLine.utf8)) else {
            return XCTFail("expected usage")
        }
        XCTAssertEqual(parsed.usage.observedModelID, "gpt-test")
        XCTAssertEqual(parsed.usage.metrics[.inputUncached], 70)
        XCTAssertEqual(parsed.usage.metrics[.inputCacheRead], 20)
        XCTAssertEqual(parsed.usage.metrics[.inputCacheWrite], 10)
        XCTAssertEqual(parsed.usage.metrics[.output], 30)
        XCTAssertEqual(parsed.usage.metrics[.detailReasoningOutput], 5)
        XCTAssertEqual(parsed.usage.tokenTotal, 130)
        XCTAssertEqual(parsed.cumulativeMetrics, [
            .inputUnclassified: 500,
            .inputCacheRead: 120,
            .inputCacheWrite: 30,
            .output: 200,
            .detailReasoningOutput: 70
        ])
        XCTAssertEqual(parsed.usage.stableUsageID, "2026-08-05T10:00:00.000Z:700")
        XCTAssertEqual(adapter.checkpointState["current_model"], "gpt-test")
    }

    func testOverlappingInputSubtotalsRemainCountedButUnclassified() throws {
        var adapter = CodexAdapter(stableSourceID: "session-a", currentModel: "gpt-test")
        let line = #"{"timestamp":"2026-08-05T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":80,"cache_write_input_tokens":30,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":110}}}}"#
        guard case let .usage(parsed) = adapter.consume(line: Data(line.utf8)) else {
            return XCTFail("expected usage")
        }
        XCTAssertEqual(parsed.usage.metrics[.inputUnclassified], 100)
        XCTAssertNil(parsed.usage.metrics[.inputUncached])
        XCTAssertEqual(parsed.diagnostics.map(\.kind), [.inconsistentSubtotals])
    }

    func testTokenCountWithoutKnownModelIsSkipped() {
        var adapter = CodexAdapter(stableSourceID: "session-a")
        let line = #"{"timestamp":"2026-08-05T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":2}}}}"#
        guard case let .skipped(diagnostic) = adapter.consume(line: Data(line.utf8)) else {
            return XCTFail("expected skipped record")
        }
        XCTAssertEqual(diagnostic.kind, .missingModel)
    }

    func testNonemptyCustomModelContextIsRetainedInMemory() {
        let model = "vendor/model:beta@2026"
        let initialized = CodexAdapter(stableSourceID: "session-a", currentModel: model)
        XCTAssertEqual(initialized.checkpointState["current_model"], model)

        var adapter = CodexAdapter(stableSourceID: "session-a")
        XCTAssertEqual(adapter.consume(line: Data(#"{"type":"turn_context","payload":{"model":"vendor/model:beta@2026"}}"#.utf8)), .ignored)
        let line = #"{"timestamp":"2026-08-05T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"total_tokens":2}}}}"#
        guard case let .usage(parsed) = adapter.consume(line: Data(line.utf8)) else {
            return XCTFail("expected usage")
        }
        XCTAssertEqual(parsed.usage.observedModelID, model)
        XCTAssertEqual(adapter.checkpointState["current_model"], model)
    }

    func testInvalidCountersAndTimestampsAreSkipped() {
        var adapter = CodexAdapter(stableSourceID: "session-a", currentModel: "gpt-test")
        let invalidCounter = #"{"timestamp":"2026-08-05T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":-1,"cached_input_tokens":0,"output_tokens":0,"total_tokens":0}}}}"#
        let invalidTimestamp = #"{"timestamp":"invalid","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"total_tokens":0}}}}"#
        guard case let .skipped(counterDiagnostic) = adapter.consume(line: Data(invalidCounter.utf8)),
              case let .skipped(timestampDiagnostic) = adapter.consume(line: Data(invalidTimestamp.utf8)) else {
            return XCTFail("expected skipped records")
        }
        XCTAssertEqual(counterDiagnostic.kind, .malformedRecord)
        XCTAssertEqual(timestampDiagnostic.kind, .malformedRecord)
    }

    func testCumulativeSnapshotsRemainRawAcrossResetForCheckpointHandoff() {
        var adapter = CodexAdapter(stableSourceID: "session-a", currentModel: "gpt-test")
        let first = #"{"timestamp":"2026-08-05T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":5,"cached_input_tokens":1,"output_tokens":2,"total_tokens":7},"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"cache_write_input_tokens":10,"output_tokens":40,"reasoning_output_tokens":4,"total_tokens":140}}}}"#
        let reset = #"{"timestamp":"2026-08-05T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"total_tokens":2},"total_token_usage":{"input_tokens":2,"cached_input_tokens":1,"cache_write_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":3}}}}"#
        guard case let .usage(firstParsed) = adapter.consume(line: Data(first.utf8)),
              case let .usage(resetParsed) = adapter.consume(line: Data(reset.utf8)) else {
            return XCTFail("expected usage")
        }
        XCTAssertEqual(firstParsed.cumulativeMetrics[.inputUnclassified], 100)
        XCTAssertEqual(resetParsed.cumulativeMetrics, [
            .inputUnclassified: 2,
            .inputCacheRead: 1,
            .inputCacheWrite: 0,
            .output: 1,
            .detailReasoningOutput: 0
        ])
        XCTAssertEqual(resetParsed.usage.stableUsageID, "2026-08-05T10:01:00Z:3")
    }

    func testLegacyTokenCountsWithoutCumulativeOrOptionalDetailsHaveNoStableIdentity() {
        var adapter = CodexAdapter(stableSourceID: "session-a", currentModel: "gpt-test")
        let line = #"{"timestamp":"2026-08-05T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":3,"cached_input_tokens":1,"output_tokens":2,"total_tokens":5}}}}"#
        guard case let .usage(parsed) = adapter.consume(line: Data(line.utf8)) else {
            return XCTFail("expected usage")
        }
        XCTAssertEqual(parsed.usage.metrics, [.inputUncached: 2, .inputCacheRead: 1, .output: 2])
        XCTAssertNil(parsed.usage.stableUsageID)
        XCTAssertTrue(parsed.cumulativeMetrics.isEmpty)
    }

    func testSessionIDFallbackSuppliesSourceIdentity() {
        var adapter = CodexAdapter(currentModel: "gpt-test")
        XCTAssertEqual(adapter.consume(line: Data(#"{"type":"session_meta","payload":{"session_id":"session-a"}}"#.utf8)), .ignored)
        let line = #"{"timestamp":"2026-08-05T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"total_tokens":2}}}}"#
        guard case let .usage(parsed) = adapter.consume(line: Data(line.utf8)) else {
            return XCTFail("expected usage")
        }
        XCTAssertEqual(parsed.usage.stableSourceID, "session-a")
    }

    func testReasoningGreaterThanOutputIsInformationallyInconsistent() {
        var adapter = CodexAdapter(stableSourceID: "session-a", currentModel: "gpt-test")
        let line = #"{"timestamp":"2026-08-05T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":5,"cached_input_tokens":0,"output_tokens":2,"reasoning_output_tokens":3,"total_tokens":7}}}}"#
        guard case let .usage(parsed) = adapter.consume(line: Data(line.utf8)) else {
            return XCTFail("expected usage")
        }
        XCTAssertNil(parsed.usage.metrics[.detailReasoningOutput])
        XCTAssertEqual(parsed.diagnostics.map(\.kind), [.inconsistentSubtotals])
    }

    func testNonOverflowTotalMismatchIsDiagnostic() {
        var adapter = CodexAdapter(stableSourceID: "session-a", currentModel: "gpt-test")
        let line = #"{"timestamp":"2026-08-05T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":5,"cached_input_tokens":0,"output_tokens":2,"total_tokens":6}}}}"#
        guard case let .usage(parsed) = adapter.consume(line: Data(line.utf8)) else {
            return XCTFail("expected usage")
        }
        XCTAssertEqual(parsed.diagnostics.map(\.kind), [.inconsistentTotal])
    }

    func testCachedAndWriteSubsetAdditionOverflowIsUnclassified() {
        var adapter = CodexAdapter(stableSourceID: "session-a", currentModel: "gpt-test")
        let line = #"{"timestamp":"2026-08-05T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":9223372036854775807,"cached_input_tokens":9223372036854775807,"cache_write_input_tokens":1,"output_tokens":0,"total_tokens":9223372036854775807}}}}"#
        guard case let .usage(parsed) = adapter.consume(line: Data(line.utf8)) else {
            return XCTFail("expected usage")
        }
        XCTAssertEqual(parsed.usage.metrics, [.inputUnclassified: .max])
        XCTAssertEqual(parsed.diagnostics.map(\.kind), [.inconsistentSubtotals])
    }

    func testInputOutputAdditionOverflowIsSkipped() {
        var adapter = CodexAdapter(stableSourceID: "session-a", currentModel: "gpt-test")
        let line = #"{"timestamp":"2026-08-05T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":9223372036854775807,"cached_input_tokens":0,"output_tokens":1,"total_tokens":0}}}}"#
        guard case let .skipped(diagnostic) = adapter.consume(line: Data(line.utf8)) else {
            return XCTFail("expected skipped record")
        }
        XCTAssertEqual(diagnostic.kind, .malformedRecord)
    }
}
