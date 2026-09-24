import Foundation

/// A daily counter describing what coding agents did, independent of how many tokens a model spends.
///
/// These definitions are the single source of truth for the activity metrics:
/// - `tasks`: human prompts that received at least one billed model response, attributed to the model of that
///   first response. Prompts that got no response of their own collapse into the next task.
/// - `toolCalls`: tool invocations the model requested, including subagents.
/// - `linesAdded` / `linesRemoved`: lines changed by successful agent edit tools. Edits made through shell
///   commands are not visible in the logs and are not counted.
/// - `requests`: billed model responses with a positive token total.
/// - `contextTokens`: the summed input-side tokens of those requests; `contextPeak` is the largest single one.
/// - `activityTokens`: the token total of the counted requests, so tokens per task stays consistent when older
///   logs were deleted before activity counting began.
public enum AgentActivityCounter: String, CaseIterable, Codable, Sendable {
    case tasks
    case toolCalls = "tool_calls"
    case linesAdded = "lines_added"
    case linesRemoved = "lines_removed"
    case requests
    case contextTokens = "context_tokens"
    case contextPeak = "context_peak"
    case activityTokens = "activity_tokens"

    public enum Aggregation: Sendable {
        case sum
        case maximum
    }

    public var aggregation: Aggregation {
        switch self {
        case .contextPeak:
            .maximum
        case .tasks, .toolCalls, .linesAdded, .linesRemoved, .requests, .contextTokens, .activityTokens:
            .sum
        }
    }
}

public enum AgentActivityError: Error, Equatable, Sendable {
    case negativeQuantity(AgentActivityCounter)
}

/// Activity a source adapter found on one log line, before it is attributed and stored.
public struct AgentActivityDelta: Equatable, Sendable {
    public var tasks: Int64
    public var toolCalls: Int64
    public var linesAdded: Int64
    public var linesRemoved: Int64

    public static let zero = AgentActivityDelta()

    public init(tasks: Int64 = 0, toolCalls: Int64 = 0, linesAdded: Int64 = 0, linesRemoved: Int64 = 0) {
        self.tasks = tasks
        self.toolCalls = toolCalls
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
    }

    public var isZero: Bool { self == .zero }

    var quantities: [(counter: AgentActivityCounter, quantity: Int64)] {
        [(.tasks, tasks), (.toolCalls, toolCalls), (.linesAdded, linesAdded), (.linesRemoved, linesRemoved)]
    }

    /// Combines two deltas, failing instead of wrapping on overflow.
    public func adding(_ other: AgentActivityDelta) throws -> AgentActivityDelta {
        func sum(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
            let (total, overflow) = lhs.addingReportingOverflow(rhs)
            guard !overflow else { throw LedgerError.quantityOverflow }
            return total
        }
        return AgentActivityDelta(
            tasks: try sum(tasks, other.tasks),
            toolCalls: try sum(toolCalls, other.toolCalls),
            linesAdded: try sum(linesAdded, other.linesAdded),
            linesRemoved: try sum(linesRemoved, other.linesRemoved)
        )
    }
}

/// Adapter activity attributed to the provider and model that did the work.
public struct AgentActivityObservation: Equatable, Sendable {
    public let provider: Provider
    public let observedModelID: String
    public let timestamp: Date
    public let delta: AgentActivityDelta

    public init(provider: Provider, observedModelID: String, timestamp: Date, delta: AgentActivityDelta) {
        self.provider = provider
        self.observedModelID = observedModelID
        self.timestamp = timestamp
        self.delta = delta
    }
}

public struct AgentActivityRow: Equatable, Sendable {
    public let localDay: LocalDay
    public let provider: Provider
    public let observedModelID: String
    public let counter: AgentActivityCounter
    public let quantity: Int64

    public init(
        localDay: LocalDay,
        provider: Provider,
        observedModelID: String,
        counter: AgentActivityCounter,
        quantity: Int64
    ) {
        self.localDay = localDay
        self.provider = provider
        self.observedModelID = observedModelID
        self.counter = counter
        self.quantity = quantity
    }
}

/// Groups stored usage and adapter activity into daily per-model counter rows.
///
/// Request, context, and activity-token counters derive from the same deduplicated usage that feeds the token
/// ledger, so they can never disagree with it. Memory is bounded by days × models × counters.
public struct AgentActivityAggregator: Sendable {
    private let calendar: Calendar
    private var quantities: [AgentActivityKey: Int64] = [:]

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    public var isEmpty: Bool { quantities.isEmpty }

    /// Counts one stored model response. Responses without billed tokens are not requests.
    public mutating func add(_ usage: NormalizedUsage) throws {
        let tokenTotal = usage.tokenTotal
        guard tokenTotal > 0 else { return }
        let localDay = LocalDay(date: usage.timestamp, calendar: calendar)
        let context = usage.contextTokens
        for (counter, quantity) in [
            (AgentActivityCounter.requests, Int64(1)),
            (.contextTokens, context),
            (.contextPeak, context),
            (.activityTokens, tokenTotal)
        ] {
            try accumulate(quantity, counter: counter, day: localDay, provider: usage.provider, model: usage.observedModelID)
        }
    }

    public mutating func add(_ observation: AgentActivityObservation) throws {
        let localDay = LocalDay(date: observation.timestamp, calendar: calendar)
        for (counter, quantity) in observation.delta.quantities {
            try accumulate(
                quantity,
                counter: counter,
                day: localDay,
                provider: observation.provider,
                model: observation.observedModelID
            )
        }
    }

    /// Rows in a stable order so commits and tests are deterministic.
    public var rows: [AgentActivityRow] {
        quantities.map { key, quantity in
            AgentActivityRow(
                localDay: key.localDay,
                provider: key.provider,
                observedModelID: key.observedModelID,
                counter: key.counter,
                quantity: quantity
            )
        }
        .sorted {
            ($0.localDay.value, $0.localDay.timeZoneIdentifier, $0.provider.rawValue, $0.observedModelID, $0.counter.rawValue)
                < ($1.localDay.value, $1.localDay.timeZoneIdentifier, $1.provider.rawValue, $1.observedModelID, $1.counter.rawValue)
        }
    }

    private mutating func accumulate(
        _ quantity: Int64,
        counter: AgentActivityCounter,
        day: LocalDay,
        provider: Provider,
        model: String
    ) throws {
        guard quantity >= 0 else { throw AgentActivityError.negativeQuantity(counter) }
        guard quantity > 0 else { return }
        let key = AgentActivityKey(localDay: day, provider: provider, observedModelID: model, counter: counter)
        guard let current = quantities[key] else {
            quantities[key] = quantity
            return
        }
        switch counter.aggregation {
        case .sum:
            let (total, overflow) = current.addingReportingOverflow(quantity)
            guard !overflow else { throw LedgerError.quantityOverflow }
            quantities[key] = total
        case .maximum:
            quantities[key] = max(current, quantity)
        }
    }
}

private struct AgentActivityKey: Hashable {
    let localDay: LocalDay
    let provider: Provider
    let observedModelID: String
    let counter: AgentActivityCounter
}
