import Foundation
import TokenboardCore

struct SourceSettingsState: Equatable, Sendable {
    let provider: Provider
    let resolvedPath: String?
    let accessStatus: String
    let fileCount: Int
    let lastScan: Date?
    let health: SourceHealth
}

struct PricingSettingsState: Equatable, Sendable {
    var activeCatalogIDs: [String]
    var verificationDates: [String]
    var provenanceURLs: [URL]
    var unpricedModels: [String]
    var pendingCandidate: PendingPricingCandidate?
    var preview: PricingPreview?
    var validationConflicts: [String]
    var inboxStatus: PricingInboxStatus
    var isFinalizationRetryInProgress: Bool

    var canApply: Bool {
        if case .valid = inboxStatus {} else { return false }
        return pendingCandidate != nil
            && preview != nil
            && validationConflicts.isEmpty
            && preview?.diff.conflicts.isEmpty == true
    }

    var finalizationIdentity: PricingCandidateIdentity? {
        switch inboxStatus {
        case let .appliedFinalizing(identity), let .rejectedFinalizing(identity):
            identity
        default:
            nil
        }
    }

    var canRetryFinalization: Bool {
        finalizationIdentity != nil && !isFinalizationRetryInProgress
    }

    static let empty = PricingSettingsState(
        activeCatalogIDs: [],
        verificationDates: [],
        provenanceURLs: [],
        unpricedModels: [],
        pendingCandidate: nil,
        preview: nil,
        validationConflicts: [],
        inboxStatus: .empty,
        isFinalizationRetryInProgress: false
    )
}

struct SettingsDiagnosticsState: Equatable, Sendable {
    var health: TokenboardHealth
    var parserVersions: [Provider: Int]

    var skippedRecordCount: Int { health.skippedRecordCount }

    static let empty = SettingsDiagnosticsState(
        health: TokenboardHealth(
            claude: .notGranted,
            codex: .notGranted,
            database: .healthy,
            lastSuccessfulScan: nil,
            skippedRecordCount: 0,
            unpricedTokens: 0
        ),
        parserVersions: [
            .claudeCode: ClaudeCodeAdapter.parserVersion,
            .codex: CodexAdapter.parserVersion
        ]
    )
}

enum DatabaseRecoveryDisposition: Equatable, Sendable {
    case none
    case requiresRelaunch
    case preservationFailed
}

struct AppSettingsState: Equatable, Sendable {
    var sources: [Provider: SourceSettingsState]
    var pricing: PricingSettingsState
    var diagnostics: SettingsDiagnosticsState
    var statusMessage: String?
    var isLoading: Bool
    var isSourceMutationInProgress: Bool
    var recoveryBackups: [DatabaseBackup]
    var isRestoringDatabase: Bool
    var databaseRecoveryDisposition: DatabaseRecoveryDisposition

    var isFinalizationRetryInProgress: Bool {
        get { pricing.isFinalizationRetryInProgress }
        set { pricing.isFinalizationRetryInProgress = newValue }
    }

    static let initial = AppSettingsState(
        sources: [:],
        pricing: .empty,
        diagnostics: .empty,
        statusMessage: nil,
        isLoading: false,
        isSourceMutationInProgress: false,
        recoveryBackups: [],
        isRestoringDatabase: false,
        databaseRecoveryDisposition: .none
    )
}
