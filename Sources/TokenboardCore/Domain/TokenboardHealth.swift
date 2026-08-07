import Foundation

public struct TokenboardHealth: Equatable, Sendable {
    public enum DatabaseState: Equatable, Sendable {
        case healthy
        case recoveryRequired(message: String)
    }

    public enum PricingState: Equatable, Sendable {
        case healthy
        case warning(message: String)
    }

    public enum Issue: Equatable, Sendable {
        case unknownFormats
        case staleBookmark
        case missingRoot
        case truncatedLog
        case replacedLog
        case migrationFailure
        case integrityFailure
        case invalidPricingCandidate

        public var message: String {
            switch self {
            case .unknownFormats:
                "Unknown source formats were skipped"
            case .staleBookmark:
                "Saved folder access is stale"
            case .missingRoot:
                "The selected source folder is unavailable"
            case .truncatedLog:
                "A previously imported log was truncated; import is paused"
            case .replacedLog:
                "A previously imported log changed; import is paused"
            case .migrationFailure:
                "Database migration failed; recovery is required"
            case .integrityFailure:
                "Database integrity check failed; recovery is required"
            case .invalidPricingCandidate:
                "The pricing candidate is invalid; active pricing is unchanged"
            }
        }
    }

    public let claude: SourceHealth
    public let codex: SourceHealth
    public let database: DatabaseState
    public let lastSuccessfulScan: Date?
    public let skippedRecordCount: Int
    public let unpricedTokens: Int64
    public let providerLastSuccessfulScans: [Provider: Date]
    public let pricing: PricingState

    public init(
        claude: SourceHealth,
        codex: SourceHealth,
        database: DatabaseState,
        lastSuccessfulScan: Date?,
        skippedRecordCount: Int,
        unpricedTokens: Int64,
        providerLastSuccessfulScans: [Provider: Date] = [:],
        pricing: PricingState = .healthy
    ) {
        self.claude = claude
        self.codex = codex
        self.database = database
        self.lastSuccessfulScan = lastSuccessfulScan
        self.skippedRecordCount = max(0, skippedRecordCount)
        self.unpricedTokens = max(0, unpricedTokens)
        self.providerLastSuccessfulScans = providerLastSuccessfulScans
        self.pricing = pricing
    }

    public func source(_ provider: Provider) -> SourceHealth {
        switch provider {
        case .claudeCode: claude
        case .codex: codex
        }
    }

    public var hasWarning: Bool {
        Self.isWarning(claude)
            || Self.isWarning(codex)
            || database != .healthy
            || pricing != .healthy
            || unpricedTokens > 0
    }

    public func replacing(
        claude: SourceHealth? = nil,
        codex: SourceHealth? = nil,
        database: DatabaseState? = nil,
        lastSuccessfulScan: Date?? = nil,
        skippedRecordCount: Int? = nil,
        unpricedTokens: Int64? = nil,
        providerLastSuccessfulScans: [Provider: Date]? = nil,
        pricing: PricingState? = nil
    ) -> TokenboardHealth {
        TokenboardHealth(
            claude: claude ?? self.claude,
            codex: codex ?? self.codex,
            database: database ?? self.database,
            lastSuccessfulScan: lastSuccessfulScan ?? self.lastSuccessfulScan,
            skippedRecordCount: skippedRecordCount ?? self.skippedRecordCount,
            unpricedTokens: unpricedTokens ?? self.unpricedTokens,
            providerLastSuccessfulScans: providerLastSuccessfulScans
                ?? self.providerLastSuccessfulScans,
            pricing: pricing ?? self.pricing
        )
    }

    private static func isWarning(_ health: SourceHealth) -> Bool {
        switch health {
        case .notGranted, .warning:
            true
        case .indexing, .healthy:
            false
        }
    }
}
