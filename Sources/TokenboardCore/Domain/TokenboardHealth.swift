import Foundation

public enum TokenboardHealthIssue: String, Equatable, Sendable {
    case unknownFormats = "unknown_formats"
    case staleBookmark = "stale_bookmark"
    case missingRoot = "missing_root"
    case truncatedLog = "truncated_log"
    case replacedLog = "replaced_log"
    case oversizedRecord = "oversized_record"
    case unsafeSource = "unsafe_source"
    case missingStableIdentity = "missing_stable_identity"
    case importFailure = "import_failure"
    case applicationFailure = "application_failure"
    case migrationFailure = "migration_failure"
    case integrityFailure = "integrity_failure"
    case invalidPricingCatalog = "invalid_pricing_catalog"

    public var isDismissibleSourceWarning: Bool {
        switch self {
        case .unknownFormats, .staleBookmark, .missingRoot, .truncatedLog,
             .replacedLog, .oversizedRecord, .unsafeSource,
             .missingStableIdentity, .importFailure:
            true
        case .applicationFailure, .migrationFailure, .integrityFailure,
             .invalidPricingCatalog:
            false
        }
    }

    public var message: String {
        switch self {
        case .unknownFormats: "Unknown source formats were skipped"
        case .staleBookmark: "Saved folder access is stale"
        case .missingRoot: "The selected source folder is unavailable"
        case .truncatedLog: "A previously imported log was truncated; import is paused"
        case .replacedLog: "A previously imported log changed; import is paused"
        case .oversizedRecord: "A source record is too large; import is paused at that record"
        case .unsafeSource: "A source file is unsafe; import is paused"
        case .missingStableIdentity: "A source log has no stable identity; import is paused"
        case .importFailure: "Import failed"
        case .applicationFailure: "Tokenboard is unavailable"
        case .migrationFailure: "Database migration failed; recovery is required"
        case .integrityFailure: "Database integrity check failed; recovery is required"
        case .invalidPricingCatalog: "The pricing catalog update is invalid; last valid pricing remains active"
        }
    }
}

public struct TokenboardHealth: Equatable, Sendable {
    public typealias Issue = TokenboardHealthIssue
    public enum DatabaseState: Equatable, Sendable {
        case healthy
        case recoveryRequired(message: String)
    }

    public enum PricingState: Equatable, Sendable {
        case healthy
        case warning(message: String)
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
            || skippedRecordCount > 0
            || unpricedTokens > 0
    }

    public var hasDisplayIntegrityWarning: Bool {
        Self.affectsDisplayIntegrity(claude)
            || Self.affectsDisplayIntegrity(codex)
            || database != .healthy
            || skippedRecordCount > 0
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

    private static func affectsDisplayIntegrity(_ health: SourceHealth) -> Bool {
        switch health {
        case .warning:
            true
        case .notGranted, .indexing, .healthy:
            false
        }
    }
}
