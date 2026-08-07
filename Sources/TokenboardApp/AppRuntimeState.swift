import Foundation
import TokenboardCore

protocol AppLedgerRuntime: Sendable {
    func migrate() async throws
    func integrityCheck() async throws
    func latestAppliedPricingCatalogJSON() async throws -> Data?
    func applyPricingCatalog(
        _ catalog: ValidatedPricingCatalog,
        canonicalJSON: Data,
        origin: String,
        validationSummary: String
    ) async throws
    func pricingSnapshot() async throws -> PricingSnapshot
    func usageRows(
        in interval: DateInterval?,
        calendar: Calendar
    ) async throws -> [DailyUsageRow]
    func skippedRecordCount() async throws -> Int
    func skippedRecordCountsByProvider() async throws -> [Provider: Int]
    func shutdown() async throws
}

extension AppLedgerRuntime {
    func shutdown() async throws {}

    func skippedRecordCountsByProvider() async throws -> [Provider: Int] { [:] }
}

protocol AppUsageQuerying: Sendable {
    func summary(
        period: CalendarPeriod,
        now: Date,
        calendar: Calendar
    ) async throws -> UsageSummary
}

protocol AppIngestionCoordinating: Sendable {
    func results() async -> AsyncStream<IngestionBatchResult>
    func start(roots: [Provider: URL]) async throws -> IngestionBatchResult
    func startMonitoring(roots: [Provider: URL]) async throws -> IngestionBatchResult
    func refreshAll() async -> IngestionBatchResult
    func replaceSource(
        _ provider: Provider,
        with root: URL,
        roots: [Provider: URL]
    ) async throws -> IngestionBatchResult
    func revokeSource(
        _ provider: Provider,
        remainingRoots: [Provider: URL]
    ) async throws -> UInt64?
    func stop() async
}

protocol AppPricingInboxWatching: Sendable {
    func start() async throws
    func quiesce() async throws
    func stop() async throws
    func pendingCandidate() async -> PendingPricingCandidate?
    func status() async -> PricingInboxStatus
    func exportCurrentSnapshot() async throws
    func applyPending(matching identity: PricingCandidateIdentity) async throws -> PricingApplyOutcome
    func rejectPending(matching identity: PricingCandidateIdentity) async throws -> PricingRejectOutcome
    func retryFinalization(
        matching identity: PricingCandidateIdentity
    ) async throws -> PricingFinalizationOutcome
}

protocol AppDatabaseRecovering: Sendable {
    func availableBackups() async throws -> [DatabaseBackup]
    func restore(
        _ confirmedBackup: DatabaseBackup,
        afterShutdown: @Sendable () async throws -> Void
    ) async throws -> DatabaseBackup
    func retryPreservation() async throws
}

extension AppDatabaseRecovering {
    func retryPreservation() async throws {
        throw DatabaseRecoveryError.preservationFailed
    }
}

extension AppPricingInboxWatching {
    func quiesce() async throws {}

    func status() async -> PricingInboxStatus {
        await pendingCandidate().map(PricingInboxStatus.valid) ?? .empty
    }

    func retryFinalization(
        matching identity: PricingCandidateIdentity
    ) async throws -> PricingFinalizationOutcome {
        throw PricingInboxError.noPendingCandidate
    }
}

extension SQLiteLedger: AppLedgerRuntime {}
extension UsageQueryService: AppUsageQuerying {}
extension IngestionCoordinator: AppIngestionCoordinating {}
extension PricingInbox: AppPricingInboxWatching {}
extension DatabaseRecoveryService: AppDatabaseRecovering {}

enum AppLifecycleState: Equatable, Sendable {
    case idle
    case starting
    case ready
    case failed(message: String)
    case shuttingDown
    case stopped
}

struct AppPublishedState: Equatable, Sendable {
    var lifecycle: AppLifecycleState
    var presentation: MenuPresentation?
    var sourceFileCounts: [Provider: Int]
    var grantedProviders: Set<Provider>
    var onboardingRequired: Bool
    var historicalImportApproved: Bool
    var selectedPeriod: CalendarPeriod
    var selectedDisplayMetric: DisplayMetric
    var health: TokenboardHealth
    var isImporting: Bool

    var sourceHealth: [Provider: SourceHealth] {
        get { [.claudeCode: health.claude, .codex: health.codex] }
        set {
            health = health.replacing(
                claude: newValue[.claudeCode] ?? .notGranted,
                codex: newValue[.codex] ?? .notGranted
            )
        }
    }

    var lastSuccessfulScans: [Provider: Date] {
        get { health.providerLastSuccessfulScans }
        set { health = health.replacing(providerLastSuccessfulScans: newValue) }
    }

    var lastUpdated: Date? {
        get { health.lastSuccessfulScan }
        set { health = health.replacing(lastSuccessfulScan: .some(newValue)) }
    }

    static func initial(
        period: CalendarPeriod,
        displayMetric: DisplayMetric,
        historicalImportApproved: Bool = false
    ) -> AppPublishedState {
        AppPublishedState(
            lifecycle: .idle,
            presentation: nil,
            sourceFileCounts: [:],
            grantedProviders: [],
            onboardingRequired: false,
            historicalImportApproved: historicalImportApproved,
            selectedPeriod: period,
            selectedDisplayMetric: displayMetric,
            health: TokenboardHealth(
                claude: .notGranted,
                codex: .notGranted,
                database: .healthy,
                lastSuccessfulScan: nil,
                skippedRecordCount: 0,
                unpricedTokens: 0
            ),
            isImporting: false
        )
    }

    var canStartHistoricalImport: Bool {
        lifecycle == .ready
            && !isImporting
            && !historicalImportApproved
            && Provider.allCases.allSatisfy(grantedProviders.contains)
    }
}

enum AppRuntimeStatus: Equatable {
    case inactive
    case starting
    case active(runID: UInt64)
}

extension AppRuntimeStatus {
    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

struct AppRuntimeActivity {
    let id: UInt64
    let task: Task<Void, Never>
}

enum AppSourceMutationRequest: Sendable {
    case choose(Provider)
    case revoke(Provider)
}

struct IngestionResultKey: Hashable {
    let runID: UInt64
    let sequence: UInt64
}

@MainActor
struct AppResolvedGrants {
    let grants: [Provider: ActiveSourceGrant]
    let health: [Provider: SourceHealth]
    let counts: [Provider: Int]
}
