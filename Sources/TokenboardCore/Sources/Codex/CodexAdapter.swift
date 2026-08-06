import Foundation

public struct CodexAdapter: StatefulLogAdapter {
    public static let parserVersion = 1

    private var stableSourceID: String?
    private var currentModel: String?

    public init(stableSourceID: String? = nil, currentModel: String? = nil) {
        self.stableSourceID = stableSourceID
        self.currentModel = currentModel?.isEmpty == false ? currentModel : nil
    }

    public var checkpointState: [String: String] {
        guard let currentModel else { return [:] }
        return ["current_model": currentModel]
    }

    public mutating func consume(line: Data) -> AdapterResult {
        let record: CodexRecord
        do {
            record = try JSONDecoder().decode(CodexRecord.self, from: line)
        } catch {
            return .skipped(.init(kind: .malformedRecord, message: "Codex record is malformed"))
        }

        switch record.type {
        case "session_meta":
            stableSourceID = record.payload?.id ?? record.payload?.sessionID
            return .ignored
        case "turn_context":
            guard let model = record.payload?.model, !model.isEmpty else {
                return .ignored
            }
            currentModel = model
            return .ignored
        case "event_msg":
            break
        default:
            return .ignored
        }

        guard record.payload?.type == "token_count" else {
            return .ignored
        }
        guard let info = record.payload?.info, let last = info.last else {
            return .skipped(.init(kind: .malformedRecord, message: "Codex token count is malformed"))
        }
        guard let timestampValue = record.timestamp, let timestamp = TimestampParser.parse(timestampValue) else {
            return .skipped(.init(kind: .malformedRecord, message: "Codex record has an invalid timestamp"))
        }
        guard let stableSourceID, !stableSourceID.isEmpty else {
            return .skipped(.init(kind: .missingSourceIdentity, message: "Codex record is missing source identity"))
        }
        guard let currentModel else {
            return .skipped(.init(kind: .missingModel, message: "Codex record is missing a model"))
        }
        guard last.isNonnegative, info.total?.isNonnegative ?? true else {
            return .skipped(.init(kind: .malformedRecord, message: "Codex record has invalid counters"))
        }

        let (subtotals, subtotalOverflow) = last.cachedInput.addingReportingOverflow(last.cacheWriteInput)
        var diagnostics: [AdapterDiagnostic] = []
        var metrics: [UsageMetric: Int64]
        if subtotalOverflow || subtotals > last.input {
            metrics = [.inputUnclassified: last.input]
            diagnostics.append(.init(kind: .inconsistentSubtotals, message: "Codex input subsets exceed input total"))
        } else {
            metrics = [
                .inputUncached: last.input - subtotals,
                .inputCacheRead: last.cachedInput,
                .inputCacheWrite: last.cacheWriteInput
            ]
        }
        metrics[.output] = last.output
        if last.reasoningOutput <= last.output {
            metrics[.detailReasoningOutput] = last.reasoningOutput
        } else {
            diagnostics.append(.init(kind: .inconsistentSubtotals, message: "Codex reasoning output exceeds output total"))
        }

        let (calculatedTotal, totalOverflow) = last.input.addingReportingOverflow(last.output)
        guard !totalOverflow else {
            return .skipped(.init(kind: .malformedRecord, message: "Codex token counters overflow"))
        }
        if last.total != calculatedTotal {
            diagnostics.append(.init(kind: .inconsistentTotal, message: "Codex total differs from input plus output"))
        }

        do {
            let normalized = try NormalizedUsage(
                provider: .codex,
                observedModelID: currentModel,
                timestamp: timestamp,
                metrics: metrics,
                stableSourceID: stableSourceID,
                stableUsageID: info.total.map { "\(timestampValue):\($0.total)" }
            )
            return .usage(.init(
                usage: normalized,
                cumulativeMetrics: info.total.map(Self.cumulativeMetrics) ?? [:],
                diagnostics: diagnostics
            ))
        } catch {
            return .skipped(.init(kind: .malformedRecord, message: "Codex record has invalid counters"))
        }
    }

    private static func cumulativeMetrics(for snapshot: TokenSnapshot) -> [UsageMetric: Int64] {
        [
            .inputUnclassified: snapshot.input,
            .inputCacheRead: snapshot.cachedInput,
            .inputCacheWrite: snapshot.cacheWriteInput,
            .output: snapshot.output,
            .detailReasoningOutput: snapshot.reasoningOutput
        ]
    }

}

private struct CodexRecord: Decodable {
    let timestamp: String?
    let type: String
    let payload: CodexPayload?
}

private struct CodexPayload: Decodable {
    let type: String?
    let id: String?
    let sessionID: String?
    let model: String?
    let info: TokenCountInfo?

    enum CodingKeys: String, CodingKey {
        case type, id, model, info
        case sessionID = "session_id"
    }
}

private struct TokenCountInfo: Decodable {
    let last: TokenSnapshot?
    let total: TokenSnapshot?

    enum CodingKeys: String, CodingKey {
        case last = "last_token_usage"
        case total = "total_token_usage"
    }
}

private struct TokenSnapshot: Decodable {
    let input: Int64
    let cachedInput: Int64
    let cacheWriteInput: Int64
    let output: Int64
    let reasoningOutput: Int64
    let total: Int64

    enum CodingKeys: String, CodingKey {
        case input = "input_tokens"
        case cachedInput = "cached_input_tokens"
        case cacheWriteInput = "cache_write_input_tokens"
        case output = "output_tokens"
        case reasoningOutput = "reasoning_output_tokens"
        case total = "total_tokens"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        input = try values.decode(Int64.self, forKey: .input)
        cachedInput = try values.decode(Int64.self, forKey: .cachedInput)
        cacheWriteInput = try values.decodeIfPresent(Int64.self, forKey: .cacheWriteInput) ?? 0
        output = try values.decode(Int64.self, forKey: .output)
        reasoningOutput = try values.decodeIfPresent(Int64.self, forKey: .reasoningOutput) ?? 0
        total = try values.decode(Int64.self, forKey: .total)
    }

    var isNonnegative: Bool {
        input >= 0 && cachedInput >= 0 && cacheWriteInput >= 0
            && output >= 0 && reasoningOutput >= 0 && total >= 0
    }
}
