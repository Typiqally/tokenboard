import Foundation
import XCTest
@testable import TokenboardCore

final class CodexAdapterTests: XCTestCase {
    func testUsesSessionAndTurnContextForTokenCount() throws {
        var adapter = CodexAdapter()
        XCTAssertEqual(adapter.consume(line: Data(#"{"type":"session_meta","payload":{"id":"session-a"}}"#.utf8)), .ignored)
        XCTAssertEqual(adapter.consume(line: Data(#"{"type":"turn_context","payload":{"model":"gpt-test"}}"#.utf8)), .ignored)
        let tokenLine = #"{"timestamp":"2026-08-05T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"cache_write_input_tokens":10,"output_tokens":30,"reasoning_output_tokens":5,"total_tokens":130},"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"cache_write_input_tokens":10,"output_tokens":30,"reasoning_output_tokens":5,"total_tokens":130}}}}"#
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
            .inputUnclassified: 100,
            .inputCacheRead: 20,
            .inputCacheWrite: 10,
            .output: 30,
            .detailReasoningOutput: 5
        ])
        XCTAssertEqual(parsed.usage.stableUsageID, "2026-08-05T10:00:00.000Z:130")
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

    func testUnsafeModelContextDoesNotEnterCheckpointState() {
        var adapter = CodexAdapter(stableSourceID: "session-a")
        XCTAssertEqual(adapter.consume(line: Data(#"{"type":"turn_context","payload":{"model":"unsafe\nmodel"}}"#.utf8)), .ignored)
        XCTAssertNil(adapter.checkpointState["current_model"])
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
}
