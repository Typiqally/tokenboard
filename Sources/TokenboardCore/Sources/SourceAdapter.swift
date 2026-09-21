import Foundation

public struct AdapterDiagnostic: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case malformedRecord = "malformed_record"
        case missingModel = "missing_model"
        case missingSourceIdentity = "missing_source_identity"
        case inconsistentSubtotals = "inconsistent_subtotals"
        case inconsistentTotal = "inconsistent_total"
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public struct ParsedUsageRecord: Equatable, Sendable {
    public let usage: NormalizedUsage
    public let cumulativeMetrics: [UsageMetric: Int64]
    public let diagnostics: [AdapterDiagnostic]
    /// Agent activity on the same line, attributed to this record's provider, model, and timestamp. It is
    /// counted even when the usage itself repeats the previous record.
    public let activity: AgentActivityDelta

    public init(
        usage: NormalizedUsage,
        cumulativeMetrics: [UsageMetric: Int64],
        diagnostics: [AdapterDiagnostic],
        activity: AgentActivityDelta = .zero
    ) {
        self.usage = usage
        self.cumulativeMetrics = cumulativeMetrics
        self.diagnostics = diagnostics
        self.activity = activity
    }
}

public enum AdapterResult: Equatable, Sendable {
    case usage(ParsedUsageRecord)
    /// Agent activity on a line that carries no billed usage, such as a tool result or an applied patch.
    case activity(AgentActivityObservation)
    case ignored
    case skipped(AdapterDiagnostic)
}

public protocol StatefulLogAdapter: Sendable {
    static var parserVersion: Int { get }
    var checkpointState: [String: String] { get }
    mutating func consume(line: Data) -> AdapterResult
}
