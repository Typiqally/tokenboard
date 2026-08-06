import Foundation
import XCTest
@testable import TokenboardCore

final class ClaudeCodeAdapterTests: XCTestCase {
    private let line = #"{"type":"assistant","timestamp":"2026-08-05T10:00:00.000Z","sessionId":"session-a","requestId":"request-a","message":{"id":"message-a","model":"claude-opus-test","usage":{"input_tokens":100,"cache_creation_input_tokens":30,"cache_read_input_tokens":40,"output_tokens":20,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":20}}}}"#

    func testNormalizesMutuallyExclusiveClaudeCategories() throws {
        var adapter = ClaudeCodeAdapter()
        guard case let .usage(parsed) = adapter.consume(line: Data(line.utf8)) else {
            return XCTFail("expected usage")
        }
        XCTAssertEqual(parsed.usage.metrics[.inputUncached], 100)
        XCTAssertEqual(parsed.usage.metrics[.inputCacheRead], 40)
        XCTAssertEqual(parsed.usage.metrics[.inputCacheWrite5m], 10)
        XCTAssertEqual(parsed.usage.metrics[.inputCacheWrite1h], 20)
        XCTAssertNil(parsed.usage.metrics[.inputCacheWrite])
        XCTAssertEqual(parsed.usage.metrics[.output], 20)
        XCTAssertEqual(parsed.usage.tokenTotal, 190)
    }

    func testRepeatedStreamRecordsExposeTheSameStableIdentity() throws {
        var adapter = ClaudeCodeAdapter()
        guard case let .usage(first) = adapter.consume(line: Data(line.utf8)),
              case let .usage(second) = adapter.consume(line: Data(line.utf8)) else {
            return XCTFail("expected usage")
        }
        XCTAssertEqual(first.usage.stableUsageID, second.usage.stableUsageID)
        XCTAssertEqual(first.usage.stableUsageID, "request-a:message-a")
    }

    func testFallsBackToGenericCacheWriteWithoutDurationDetails() throws {
        let value = #"{"type":"assistant","timestamp":"2026-08-05T10:00:00Z","sessionId":"session-a","message":{"id":"message-b","model":"claude-test","usage":{"input_tokens":1,"cache_creation_input_tokens":12,"cache_read_input_tokens":0,"output_tokens":2}}}"#
        var adapter = ClaudeCodeAdapter()
        guard case let .usage(parsed) = adapter.consume(line: Data(value.utf8)) else {
            return XCTFail("expected usage")
        }
        XCTAssertEqual(parsed.usage.metrics[.inputCacheWrite], 12)
    }

    func testUnknownRecordIsIgnoredAndMalformedUsageIsSkipped() {
        var adapter = ClaudeCodeAdapter()
        XCTAssertEqual(adapter.consume(line: Data(#"{"type":"user"}"#.utf8)), .ignored)
        guard case .skipped = adapter.consume(line: Data(#"{"type":"assistant","message":{}}"#.utf8)) else {
            return XCTFail("expected skipped record")
        }
    }
}
