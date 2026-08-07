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

struct ActiveModelPricingSummary: Equatable, Identifiable, Sendable {
    let provider: Provider
    let canonicalModelID: String
    let rates: [UsageMetric: Decimal]

    var id: String { "\(provider.rawValue)/\(canonicalModelID)" }
}

struct PricingSettingsState: Equatable, Sendable {
    var activeModels: [ActiveModelPricingSummary]
    var exchangeRates: ExchangeRateSnapshot?
    var activeCatalogID: String?
    var catalogStatus: PricingCatalogStatus?

    static let empty = PricingSettingsState(
        activeModels: [],
        exchangeRates: nil,
        activeCatalogID: nil,
        catalogStatus: nil
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
    case preservationRetryRequired
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
