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
    func stop() async throws
    func pendingCandidate() async -> PendingPricingCandidate?
    func status() async -> PricingInboxStatus
    func exportCurrentSnapshot() async throws
    func applyPending() async throws
    func applyPending(matching identity: PricingCandidateIdentity) async throws -> PricingApplyOutcome
    func rejectPending() async throws
    func rejectPending(matching identity: PricingCandidateIdentity) async throws -> PricingRejectOutcome
}

extension AppPricingInboxWatching {
    func status() async -> PricingInboxStatus {
        await pendingCandidate().map(PricingInboxStatus.valid) ?? .empty
    }

    func applyPending(
        matching identity: PricingCandidateIdentity
    ) async throws -> PricingApplyOutcome {
        guard await pendingCandidate()?.identity == identity else {
            throw PricingInboxError.candidateChanged
        }
        try await applyPending()
        return .finalized
    }

    func rejectPending(
        matching identity: PricingCandidateIdentity
    ) async throws -> PricingRejectOutcome {
        guard await pendingCandidate()?.identity == identity else {
            throw PricingInboxError.candidateChanged
        }
        try await rejectPending()
        return .finalized
    }
}

extension SQLiteLedger: AppLedgerRuntime {}
extension UsageQueryService: AppUsageQuerying {}
extension IngestionCoordinator: AppIngestionCoordinating {}
extension PricingInbox: AppPricingInboxWatching {}

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
    var sourceHealth: [Provider: SourceHealth]
    var sourceFileCounts: [Provider: Int]
    var lastSuccessfulScans: [Provider: Date]
    var grantedProviders: Set<Provider>
    var onboardingRequired: Bool
    var historicalImportApproved: Bool
    var selectedPeriod: CalendarPeriod
    var selectedDisplayMetric: DisplayMetric
    var lastUpdated: Date?
    var isImporting: Bool

    static func initial(
        period: CalendarPeriod,
        displayMetric: DisplayMetric,
        historicalImportApproved: Bool = false
    ) -> AppPublishedState {
        AppPublishedState(
            lifecycle: .idle,
            presentation: nil,
            sourceHealth: [.claudeCode: .notGranted, .codex: .notGranted],
            sourceFileCounts: [:],
            lastSuccessfulScans: [:],
            grantedProviders: [],
            onboardingRequired: false,
            historicalImportApproved: historicalImportApproved,
            selectedPeriod: period,
            selectedDisplayMetric: displayMetric,
            lastUpdated: nil,
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
