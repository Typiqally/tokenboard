import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude_code"
    case codex
}

public enum MetricAggregation: String, Codable, Sendable {
    case additive
    case informationalSubset = "informational_subset"
}

public enum UsageMetric: String, Codable, CaseIterable, Sendable {
    case inputUncached = "input_uncached"
    case inputCacheRead = "input_cache_read"
    case inputCacheWrite = "input_cache_write"
    case inputCacheWrite5m = "input_cache_write_5m"
    case inputCacheWrite1h = "input_cache_write_1h"
    case inputUnclassified = "input_unclassified"
    case output
    case detailReasoningOutput = "detail_reasoning_output"

    public var aggregation: MetricAggregation {
        self == .detailReasoningOutput ? .informationalSubset : .additive
    }

    public var countsTowardTokenTotal: Bool { aggregation == .additive }
}

public enum UsageModelError: Error, Equatable {
    case emptyModelID
    case negativeQuantity(metric: UsageMetric)
}

public struct NormalizedUsage: Equatable, Sendable {
    public let provider: Provider
    public let observedModelID: String
    public let timestamp: Date
    public let metrics: [UsageMetric: Int64]
    public let stableSourceID: String
    public let stableUsageID: String?

    public init(
        provider: Provider,
        observedModelID: String,
        timestamp: Date,
        metrics: [UsageMetric: Int64],
        stableSourceID: String,
        stableUsageID: String?
    ) throws {
        guard !observedModelID.isEmpty else { throw UsageModelError.emptyModelID }
        if let pair = metrics.first(where: { $0.value < 0 }) {
            throw UsageModelError.negativeQuantity(metric: pair.key)
        }
        self.provider = provider
        self.observedModelID = observedModelID
        self.timestamp = timestamp
        self.metrics = metrics.filter { $0.value > 0 }
        self.stableSourceID = stableSourceID
        self.stableUsageID = stableUsageID
    }

    public var tokenTotal: Int64 {
        metrics.reduce(0) { total, pair in
            pair.key.countsTowardTokenTotal ? total + pair.value : total
        }
    }
}

public struct SourceCheckpoint: Codable, Equatable, Sendable {
    public let fingerprint: String
    public let provider: Provider
    public var parserVersion: Int
    public var byteOffset: Int64
    public var fileSize: Int64
    public var modificationTime: Date?
    public var lastUsageIdentityHash: String?
    public var lastCommittedLineHash: String?
    public var cumulativeMetrics: [UsageMetric: Int64]
    public var adapterState: [String: String]

    public init(
        fingerprint: String,
        provider: Provider,
        parserVersion: Int,
        byteOffset: Int64,
        fileSize: Int64,
        modificationTime: Date?,
        lastUsageIdentityHash: String?,
        lastCommittedLineHash: String? = nil,
        cumulativeMetrics: [UsageMetric: Int64],
        adapterState: [String: String] = [:]
    ) {
        self.fingerprint = fingerprint
        self.provider = provider
        self.parserVersion = parserVersion
        self.byteOffset = byteOffset
        self.fileSize = fileSize
        self.modificationTime = modificationTime
        self.lastUsageIdentityHash = lastUsageIdentityHash
        self.lastCommittedLineHash = lastCommittedLineHash
        self.cumulativeMetrics = cumulativeMetrics
        self.adapterState = adapterState
    }
}
