import Foundation

/// Agent activity counters combined over a span of days.
public struct AgentActivityTotals: Equatable, Sendable {
    public private(set) var tasks: Int64 = 0
    public private(set) var toolCalls: Int64 = 0
    public private(set) var linesAdded: Int64 = 0
    public private(set) var linesRemoved: Int64 = 0
    public private(set) var requests: Int64 = 0
    public private(set) var contextTokens: Int64 = 0
    public private(set) var contextPeak: Int64 = 0
    public private(set) var activityTokens: Int64 = 0

    public static let zero = AgentActivityTotals()

    public init() {}

    public init(rows: [AgentActivityRow]) throws {
        for row in rows {
            try add(row.quantity, to: row.counter)
        }
    }

    /// Tokens spent per task, from the same requests the tasks were counted in. `nil` without tasks.
    public var tokensPerTask: Double? {
        tasks > 0 ? Double(activityTokens) / Double(tasks) : nil
    }

    /// Average context size per request. `nil` without requests.
    public var averageContext: Double? {
        requests > 0 ? Double(contextTokens) / Double(requests) : nil
    }

    public func quantity(for counter: AgentActivityCounter) -> Int64 {
        switch counter {
        case .tasks: tasks
        case .toolCalls: toolCalls
        case .linesAdded: linesAdded
        case .linesRemoved: linesRemoved
        case .requests: requests
        case .contextTokens: contextTokens
        case .contextPeak: contextPeak
        case .activityTokens: activityTokens
        }
    }

    private mutating func add(_ quantity: Int64, to counter: AgentActivityCounter) throws {
        guard quantity >= 0 else { throw AgentActivityError.negativeQuantity(counter) }
        let current = self.quantity(for: counter)
        let combined: Int64
        switch counter.aggregation {
        case .sum:
            let (total, overflow) = current.addingReportingOverflow(quantity)
            guard !overflow else { throw UsageHistoryError.tokenTotalOverflow }
            combined = total
        case .maximum:
            combined = max(current, quantity)
        }
        switch counter {
        case .tasks: tasks = combined
        case .toolCalls: toolCalls = combined
        case .linesAdded: linesAdded = combined
        case .linesRemoved: linesRemoved = combined
        case .requests: requests = combined
        case .contextTokens: contextTokens = combined
        case .contextPeak: contextPeak = combined
        case .activityTokens: activityTokens = combined
        }
    }
}

/// How much of a span's stored token usage also had its agent activity counted.
///
/// Activity is counted from logs, so usage whose logs were deleted before activity counting began has tokens but
/// no activity. Comparing activity tokens with stored tokens tells a real zero apart from "not counted".
public struct AgentActivityCoverage: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// No stored usage in the span, so zero activity is a real zero.
        case noUsage
        /// Every stored token's activity was counted.
        case complete
        /// Some stored usage has no counted activity; counters are lower bounds.
        case partial
        /// No stored usage in the span has counted activity.
        case notCovered
    }

    public let tokenTotal: Int64
    public let activityTokens: Int64

    public init(tokenTotal: Int64, activityTokens: Int64) {
        self.tokenTotal = max(0, tokenTotal)
        self.activityTokens = max(0, activityTokens)
    }

    public var state: State {
        if tokenTotal == 0 { return .noUsage }
        if activityTokens >= tokenTotal { return .complete }
        return activityTokens == 0 ? .notCovered : .partial
    }

    /// Share of stored tokens whose activity was counted, from 0 through 1. `nil` without usage.
    public var fraction: Double? {
        tokenTotal > 0 ? min(1, Double(activityTokens) / Double(tokenTotal)) : nil
    }
}

public struct ModelAgentActivity: Equatable, Sendable {
    public let provider: Provider
    public let observedModelID: String
    public let totals: AgentActivityTotals
    public let coverage: AgentActivityCoverage

    public init(
        provider: Provider,
        observedModelID: String,
        totals: AgentActivityTotals,
        coverage: AgentActivityCoverage
    ) {
        self.provider = provider
        self.observedModelID = observedModelID
        self.totals = totals
        self.coverage = coverage
    }
}

/// Agent activity over a span, per model, with its coverage of the span's stored usage.
public struct AgentActivitySummary: Equatable, Sendable {
    public let totals: AgentActivityTotals
    /// Models ordered like the token model breakdown: most tokens first, then provider and model ID.
    public let models: [ModelAgentActivity]
    public let coverage: AgentActivityCoverage

    public static let empty = AgentActivitySummary(
        totals: .zero,
        models: [],
        coverage: AgentActivityCoverage(tokenTotal: 0, activityTokens: 0)
    )

    public init(totals: AgentActivityTotals, models: [ModelAgentActivity], coverage: AgentActivityCoverage) {
        self.totals = totals
        self.models = models
        self.coverage = coverage
    }

    /// Combines activity rows with the stored usage rows of the same span.
    public init(activityRows: [AgentActivityRow], usageRows: [DailyUsageRow]) throws {
        var activityByModel: [AgentActivityModelKey: [AgentActivityRow]] = [:]
        for row in activityRows {
            activityByModel[AgentActivityModelKey(row.provider, row.observedModelID), default: []].append(row)
        }
        var tokensByModel: [AgentActivityModelKey: Int64] = [:]
        for row in usageRows where row.aggregation == .additive {
            guard row.quantity >= 0 else { throw UsageHistoryError.negativeQuantity }
            let key = AgentActivityModelKey(row.provider, row.observedModelID)
            let (total, overflow) = tokensByModel[key, default: 0].addingReportingOverflow(row.quantity)
            guard !overflow else { throw UsageHistoryError.tokenTotalOverflow }
            tokensByModel[key] = total
        }

        let keys = Set(activityByModel.keys).union(tokensByModel.keys)
        let models = try keys.map { key in
            let totals = try AgentActivityTotals(rows: activityByModel[key, default: []])
            return ModelAgentActivity(
                provider: key.provider,
                observedModelID: key.observedModelID,
                totals: totals,
                coverage: AgentActivityCoverage(
                    tokenTotal: tokensByModel[key, default: 0],
                    activityTokens: totals.activityTokens
                )
            )
        }.sorted {
            if $0.coverage.tokenTotal != $1.coverage.tokenTotal {
                return $0.coverage.tokenTotal > $1.coverage.tokenTotal
            }
            if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
            return $0.observedModelID < $1.observedModelID
        }

        let totals = try AgentActivityTotals(rows: activityRows)
        let (tokenTotal, overflow) = tokensByModel.values.reduce((Int64(0), false)) { partial, value in
            let (sum, didOverflow) = partial.0.addingReportingOverflow(value)
            return (sum, partial.1 || didOverflow)
        }
        guard !overflow else { throw UsageHistoryError.tokenTotalOverflow }
        self.init(
            totals: totals,
            models: models,
            coverage: AgentActivityCoverage(tokenTotal: tokenTotal, activityTokens: totals.activityTokens)
        )
    }
}

private struct AgentActivityModelKey: Hashable {
    let provider: Provider
    let observedModelID: String

    init(_ provider: Provider, _ observedModelID: String) {
        self.provider = provider
        self.observedModelID = observedModelID
    }
}
