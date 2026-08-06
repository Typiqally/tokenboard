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

    public init(
        usage: NormalizedUsage,
        cumulativeMetrics: [UsageMetric: Int64],
        diagnostics: [AdapterDiagnostic]
    ) {
        self.usage = usage
        self.cumulativeMetrics = cumulativeMetrics
        self.diagnostics = diagnostics
    }
}

public enum AdapterResult: Equatable, Sendable {
    case usage(ParsedUsageRecord)
    case ignored
    case skipped(AdapterDiagnostic)
}

public protocol StatefulLogAdapter: Sendable {
    static var parserVersion: Int { get }
    var checkpointState: [String: String] { get }
    mutating func consume(line: Data) -> AdapterResult
}
