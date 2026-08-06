import Foundation

public struct ClaudeCodeAdapter: StatefulLogAdapter {
    public static let parserVersion = 1

    public init() {}

    public var checkpointState: [String: String] { [:] }

    public mutating func consume(line: Data) -> AdapterResult {
        let record: ClaudeRecord
        do {
            record = try JSONDecoder().decode(ClaudeRecord.self, from: line)
        } catch {
            return .skipped(.init(kind: .malformedRecord, message: "Claude record is malformed"))
        }

        guard record.type == "assistant" else {
            return .ignored
        }
        guard let message = record.message else {
            return .ignored
        }
        guard let usage = message.usage else {
            return .skipped(.init(kind: .malformedRecord, message: "Claude record is malformed"))
        }
        guard let timestampValue = record.timestamp, let timestamp = TimestampParser.parse(timestampValue) else {
            return .skipped(.init(kind: .malformedRecord, message: "Claude record has an invalid timestamp"))
        }
        guard let sessionID = record.sessionID, !sessionID.isEmpty,
              let messageID = message.id, !messageID.isEmpty else {
            return .skipped(.init(kind: .missingSourceIdentity, message: "Claude record is missing source identity"))
        }
        guard let model = message.model, !model.isEmpty else {
            return .skipped(.init(kind: .missingModel, message: "Claude record is missing a model"))
        }
        guard usage.inputTokens >= 0,
              usage.cacheCreationInputTokens >= 0,
              usage.cacheReadInputTokens >= 0,
              usage.outputTokens >= 0 else {
            return .skipped(.init(kind: .malformedRecord, message: "Claude record has invalid counters"))
        }

        guard (usage.cacheCreation?.fiveMinute ?? 0) >= 0,
              (usage.cacheCreation?.oneHour ?? 0) >= 0 else {
            return .skipped(.init(kind: .malformedRecord, message: "Claude record has invalid counters"))
        }

        var metrics: [UsageMetric: Int64] = [
            .inputUncached: usage.inputTokens,
            .inputCacheRead: usage.cacheReadInputTokens,
            .output: usage.outputTokens
        ]
        let fiveMinute = usage.cacheCreation?.fiveMinute ?? 0
        let oneHour = usage.cacheCreation?.oneHour ?? 0
        let (detailedCacheWrite, cacheOverflow) = fiveMinute.addingReportingOverflow(oneHour)
        guard !cacheOverflow else {
            return .skipped(.init(kind: .malformedRecord, message: "Claude cache-write counters overflow"))
        }
        if detailedCacheWrite > 0 {
            metrics[.inputCacheWrite5m] = fiveMinute
            metrics[.inputCacheWrite1h] = oneHour
        } else {
            metrics[.inputCacheWrite] = usage.cacheCreationInputTokens
        }
        guard !metrics.values.reduce((total: Int64(0), overflow: false), { partial, value in
            let (total, overflow) = partial.total.addingReportingOverflow(value)
            return (total, partial.overflow || overflow)
        }).overflow else {
            return .skipped(.init(kind: .malformedRecord, message: "Claude token counters overflow"))
        }

        do {
            let normalized = try NormalizedUsage(
                provider: .claudeCode,
                observedModelID: model,
                timestamp: timestamp,
                metrics: metrics,
                stableSourceID: sessionID,
                stableUsageID: record.requestID.map { "\($0):\(messageID)" } ?? messageID
            )
            return .usage(.init(usage: normalized, cumulativeMetrics: [:], diagnostics: []))
        } catch {
            return .skipped(.init(kind: .malformedRecord, message: "Claude record has invalid counters"))
        }
    }
}

private struct ClaudeRecord: Decodable {
    let type: String
    let timestamp: String?
    let sessionID: String?
    let requestID: String?
    let message: ClaudeMessage?

    enum CodingKeys: String, CodingKey {
        case type, timestamp, message
        case sessionID = "sessionId"
        case sessionIDSnake = "session_id"
        case requestID = "requestId"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        timestamp = try values.decodeIfPresent(String.self, forKey: .timestamp)
        sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
            ?? values.decodeIfPresent(String.self, forKey: .sessionIDSnake)
        requestID = try values.decodeIfPresent(String.self, forKey: .requestID)
        message = try values.decodeIfPresent(ClaudeMessage.self, forKey: .message)
    }
}

private struct ClaudeMessage: Decodable {
    let id: String?
    let model: String?
    let usage: ClaudeUsage?
}

private struct ClaudeUsage: Decodable {
    let inputTokens: Int64
    let cacheCreationInputTokens: Int64
    let cacheReadInputTokens: Int64
    let outputTokens: Int64
    let cacheCreation: ClaudeCacheCreation?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreation = "cache_creation"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try values.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0
        cacheCreationInputTokens = try values.decodeIfPresent(Int64.self, forKey: .cacheCreationInputTokens) ?? 0
        cacheReadInputTokens = try values.decodeIfPresent(Int64.self, forKey: .cacheReadInputTokens) ?? 0
        outputTokens = try values.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0
        cacheCreation = try values.decodeIfPresent(ClaudeCacheCreation.self, forKey: .cacheCreation)
    }
}

private struct ClaudeCacheCreation: Decodable {
    let fiveMinute: Int64
    let oneHour: Int64

    enum CodingKeys: String, CodingKey {
        case fiveMinute = "ephemeral_5m_input_tokens"
        case oneHour = "ephemeral_1h_input_tokens"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fiveMinute = try values.decodeIfPresent(Int64.self, forKey: .fiveMinute) ?? 0
        oneHour = try values.decodeIfPresent(Int64.self, forKey: .oneHour) ?? 0
    }
}
