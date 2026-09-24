import Foundation

/// A view of normalized usage; cached input remains part of input.
public enum UsageTokenScope: String, Codable, CaseIterable, Sendable {
    case all
    case input
    case output

    public func includes(_ metric: UsageMetric) -> Bool {
        guard metric.countsTowardTokenTotal else { return false }
        switch self {
        case .all: return true
        case .input: return metric != .output
        case .output: return metric == .output
        }
    }
}
