public struct ScanOutcome: Equatable, Sendable {
    public enum Attention: String, Hashable, Sendable {
        case truncated
        case replaced
        case missingStableIdentity
        case oversizedRecord
        case unsafeSource
    }

    public let committedUsageRecords: Int
    public let skippedRecords: Int
    public let finalOffset: Int64
    public let attention: Attention?

    public init(
        committedUsageRecords: Int,
        skippedRecords: Int,
        finalOffset: Int64,
        attention: Attention? = nil
    ) {
        self.committedUsageRecords = committedUsageRecords
        self.skippedRecords = skippedRecords
        self.finalOffset = finalOffset
        self.attention = attention
    }
}
