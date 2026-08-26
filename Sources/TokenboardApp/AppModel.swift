import Combine
import Foundation
import TokenboardCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: AppPublishedState
    @Published private(set) var settingsState: AppSettingsState

    var onOpenPricing: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenHistory: ((HistoryOpenRequest) -> Void)?

    var presentation: MenuPresentation? { state.presentation }
    var health: TokenboardHealth { state.health }
    var sourceHealth: [Provider: SourceHealth] { state.sourceHealth }
    var sourceFileCounts: [Provider: Int] { state.sourceFileCounts }
    var onboardingRequired: Bool { state.onboardingRequired }
    var selectedPeriod: CalendarPeriod { state.selectedPeriod }
    var selectedDisplayMetric: DisplayMetric { state.selectedDisplayMetric }
    var selectedDisplayCurrency: DisplayCurrency { state.selectedDisplayCurrency }
    func isDisplayCurrencyAvailable(_ currency: DisplayCurrency) -> Bool {
        currency == .usd
            || lastSummary?.exchangeRates?.rates[currency] != nil
            || settingsState.pricing.exchangeRates?.rates[currency] != nil
    }
    var companionState: CompanionState { state.companion }
    var selectedHistoryRange: UsageHistoryRange { state.selectedHistoryRange }
    var historyState: UsageHistoryLoadState { state.historyState }
    var lastUpdated: Date? { state.lastUpdated }
    var canStartHistoricalImport: Bool { state.canStartHistoricalImport }
    var isSourceMutationInProgress: Bool { sourceMutation != nil }
    var isDatabaseRestoreInProgress: Bool {
        restoreActivity != nil || preservationActivity != nil || settingsState.isRestoringDatabase
    }
    var requiresDatabaseRecoveryRelaunch: Bool {
        settingsState.databaseRecoveryDisposition == .requiresRelaunch
    }
    var databaseRecoveryPreservationRetryRequired: Bool {
        settingsState.databaseRecoveryDisposition == .preservationRetryRequired
    }
    var isDatabaseRecoveryActionLocked: Bool {
        settingsState.databaseRecoveryDisposition != .none
    }

    let ledger: any AppLedgerRuntime
    let queryService: any AppUsageQuerying
    let coordinator: any AppIngestionCoordinating
    let pricingInbox: any AppPricingInboxWatching
    let grantStore: SourceGrantStore
    let sourcePicker: any AppSourcePicking
    let preferences: AppPreferences
    let bundledCatalogData: Data
    let applicationPaths: ApplicationPaths
    let now: @Sendable () -> Date
    private(set) var calendar: Calendar
    let discovery: any LogDiscovering
    let pasteboard: any AppPlainTextCopying
    let localDataRevealer: any AppLocalDataRevealing
    let databaseRecovery: any AppDatabaseRecovering
    var activeGrants: [Provider: ActiveSourceGrant] = [:]
    var lastSummary: UsageSummary?
    var lifecycleGeneration: UInt64 = 0
    var readyGeneration: UInt64?
    var queryGeneration: UInt64 = 0
    var inFlightQueries: [UInt64: Task<Result<UsageSummary, Error>, Never>] = [:]
    var historyQueryGeneration: UInt64 = 0
    var inFlightHistoryQueries: [
        UInt64: Task<Result<[UsageHistoryRange: UsageHistorySnapshot], Error>, Never>
    ] = [:]
    var activityGeneration: UInt64 = 0
    var sourceMutationGeneration: UInt64 = 0
    var settingsActivityGeneration: UInt64 = 0
    var restoreActivityGeneration: UInt64 = 0
    var preservationActivityGeneration: UInt64 = 0
    var startupTask: Task<Void, Never>?
    var activity: AppRuntimeActivity?
    var sourceMutation: AppRuntimeActivity?
    var settingsActivity: AppRuntimeActivity?
    var restoreActivity: AppRuntimeActivity?
    var preservationActivity: AppRuntimeActivity?
    var terminationRecoveryGate = TerminationRecoveryGate.idle
    var shutdownTask: Task<Bool, Never>?
    var recoveryBarrierTask: Task<Result<Void, any Error>, Never>?
    var isWriterQuiescing = false
    var resultConsumerTask: Task<Void, Never>?
    var pricingUpdateConsumerTask: Task<Void, Never>?
    var pendingIngestionResults: [IngestionResultKey: IngestionBatchResult] = [:]
    var knownIngestionResults: Set<IngestionResultKey> = []
    var ingestionResultWaiters: [IngestionResultKey: [CheckedContinuation<Void, Never>]] = [:]
    var lastAppliedSequence: [UInt64: UInt64] = [:]
    var inFlightCoordinatorInventoryRequests = 0
    var isProcessingIngestionResults = false
    var coordinatorStatus = AppRuntimeStatus.inactive
    var inboxStatus = AppRuntimeStatus.inactive

    init(
        ledger: any AppLedgerRuntime,
        queryService: any AppUsageQuerying,
        coordinator: any AppIngestionCoordinating,
        pricingInbox: any AppPricingInboxWatching,
        grantStore: SourceGrantStore,
        preferences: AppPreferences,
        bundledCatalogData: Data,
        applicationPaths: ApplicationPaths,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current,
        discovery: any LogDiscovering = LogDiscovery(),
        sourcePicker: (any AppSourcePicking)? = nil,
        pasteboard: (any AppPlainTextCopying)? = nil,
        localDataRevealer: (any AppLocalDataRevealing)? = nil,
        databaseRecovery: (any AppDatabaseRecovering)? = nil
    ) {
        self.ledger = ledger
        self.queryService = queryService
        self.coordinator = coordinator
        self.pricingInbox = pricingInbox
        self.grantStore = grantStore
        self.sourcePicker = sourcePicker ?? SourceGrantController()
        self.preferences = preferences
        self.bundledCatalogData = bundledCatalogData
        self.applicationPaths = applicationPaths
        self.now = now
        self.calendar = calendar
        self.discovery = discovery
        self.pasteboard = pasteboard ?? GeneralPasteboardTextCopier()
        self.localDataRevealer = localDataRevealer ?? WorkspaceLocalDataRevealer()
        self.databaseRecovery = databaseRecovery ?? DatabaseRecoveryService(
            databaseURL: applicationPaths.ledger,
            backupDirectory: applicationPaths.backups
        )
        state = .initial(
            period: preferences.selectedPeriod,
            displayMetric: preferences.selectedDisplayMetric,
            displayCurrency: preferences.selectedDisplayCurrency,
            historicalImportApproved: preferences.historicalImportApproved,
            companion: CompanionState(
                theme: preferences.selectedCompanionTheme,
                showInMenuBar: preferences.showCompanionInMenuBar,
                seed: preferences.companionSeed
            )
        )
        settingsState = .initial
    }

    func hasActiveGrant(for provider: Provider) -> Bool {
        activeGrants[provider] != nil
    }

    func commitState(_ next: AppPublishedState) {
        state = next
    }

    func commitSettingsState(_ next: AppSettingsState) {
        settingsState = next
    }

    func start() async {
        guard state.lifecycle != .ready else { return }
        guard await ensureReady(retryFailed: false) else { return }
        await finishStartupBehavior()
    }

    func startHistoricalImport() async {
        guard !isDatabaseRecoveryActionLocked,
              isReadyForSources,
              state.canStartHistoricalImport else { return }
        if let activity {
            await activity.task.value
            return
        }
        preferences.historicalImportApproved = true
        var next = state
        next.historicalImportApproved = true
        next.onboardingRequired = false
        state = next
        await launchIngestion(refreshExisting: false)
    }

    func refresh() async {
        guard !isDatabaseRestoreInProgress, !isDatabaseRecoveryActionLocked else { return }
        guard state.health.database == .healthy else { return }
        guard await ensureReady(retryFailed: true) else { return }
        guard isReadyForSources else { return }
        guard preferences.historicalImportApproved,
              hasAnyGrant else {
            var next = state
            next.onboardingRequired = true
            state = next
            if preferences.historicalImportApproved { await queryUsagePresentations() }
            return
        }
        if let activity {
            await activity.task.value
            return
        }
        await launchIngestion(refreshExisting: true)
    }

    func select(period: CalendarPeriod) async {
        guard !isDatabaseRestoreInProgress,
              !isDatabaseRecoveryActionLocked,
              state.lifecycle != .stopped,
              state.lifecycle != .shuttingDown else { return }
        let refreshesPricingCoverage = settingsState.pricing.coveragePeriod != nil
        preferences.selectedPeriod = period
        var next = state
        next.selectedPeriod = period
        state = next
        await requeryWithoutScanning()
        if refreshesPricingCoverage {
            await refreshSettings()
        }
    }

    func select(displayMetric: DisplayMetric) async {
        guard !isDatabaseRestoreInProgress,
              !isDatabaseRecoveryActionLocked,
              state.lifecycle != .stopped,
              state.lifecycle != .shuttingDown else { return }
        preferences.selectedDisplayMetric = displayMetric
        var next = state
        next.selectedDisplayMetric = displayMetric
        if let lastSummary {
            next.presentation = makePresentation(summary: lastSummary, state: next)
        }
        state = next
        await requeryWithoutScanning()
    }

    func select(displayCurrency: DisplayCurrency) {
        guard !isDatabaseRestoreInProgress,
              !isDatabaseRecoveryActionLocked,
              state.lifecycle != .stopped,
              state.lifecycle != .shuttingDown,
              isDisplayCurrencyAvailable(displayCurrency) else { return }
        preferences.selectedDisplayCurrency = displayCurrency
        var next = state
        next.selectedDisplayCurrency = displayCurrency
        if let lastSummary {
            next.presentation = makePresentation(summary: lastSummary, state: next)
        }
        state = next
    }

    func normalizeDisplayCurrency(
        in state: inout AppPublishedState,
        for summary: UsageSummary
    ) {
        let currency = state.selectedDisplayCurrency
        guard currency != .usd,
              summary.exchangeRates?.rates[currency] == nil else { return }
        preferences.selectedDisplayCurrency = .usd
        state.selectedDisplayCurrency = .usd
    }

    func select(companionTheme: CompanionTheme) async {
        guard !isDatabaseRestoreInProgress,
              !isDatabaseRecoveryActionLocked,
              state.lifecycle != .shuttingDown,
              state.lifecycle != .stopped else { return }
        preferences.selectedCompanionTheme = companionTheme
        var next = state
        next.companion.theme = companionTheme
        commitState(next)
    }

    func setShowCompanionInMenuBar(_ enabled: Bool) {
        guard !isDatabaseRestoreInProgress, !isDatabaseRecoveryActionLocked else { return }
        preferences.showCompanionInMenuBar = enabled
        var next = state
        next.companion.showInMenuBar = enabled
        commitState(next)
    }

    func companionDailyTokenTotal(at date: Date) -> Int64 {
        companionDailyTokenTotal(for: state, at: date)
    }

    func refreshForCalendarChange(_ updatedCalendar: Calendar) async {
        guard !isDatabaseRestoreInProgress,
              !isDatabaseRecoveryActionLocked,
              state.lifecycle == .ready else { return }
        calendar = updatedCalendar
        await queryUsagePresentations()
        if settingsState.pricing.coveragePeriod != nil {
            await refreshSettings()
        }
    }

    func companionPresentation(
        for state: AppPublishedState,
        at date: Date
    ) -> CompanionPresentation? {
        CompanionPresentation.make(
            state: state.companion,
            dailyTokenTotal: companionDailyTokenTotal(for: state, at: date),
            date: date,
            calendar: calendar
        )
    }

    private func companionDailyTokenTotal(
        for state: AppPublishedState,
        at date: Date
    ) -> Int64 {
        CompanionDailyTokenSource.total(
            from: state.historyState.snapshots?[.today],
            at: date,
            calendar: calendar
        )
    }

    func select(historyRange: UsageHistoryRange) {
        guard !isDatabaseRestoreInProgress,
              !isDatabaseRecoveryActionLocked,
              state.lifecycle != .stopped,
              state.lifecycle != .shuttingDown else { return }
        var next = state
        next.selectedHistoryRange = historyRange
        state = next
    }

    func chooseSource(_ provider: Provider) async {
        guard !isDatabaseRecoveryActionLocked else { return }
        await startSourceMutation(.choose(provider))
    }

    func openPricing() {
        guard !isDatabaseRestoreInProgress,
              !isDatabaseRecoveryActionLocked,
              state.lifecycle != .stopped,
              state.lifecycle != .shuttingDown else { return }
        onOpenPricing?()
    }

    func openSettings() {
        guard !isDatabaseRestoreInProgress else { return }
        onOpenSettings?()
    }

    func openHistory(provider: Provider? = nil, range: UsageHistoryRange? = nil) {
        guard !isDatabaseRestoreInProgress,
              !isDatabaseRecoveryActionLocked,
              state.lifecycle != .stopped,
              state.lifecycle != .shuttingDown else { return }
        onOpenHistory?(HistoryOpenRequest(
            provider: provider,
            range: range ?? state.selectedHistoryRange
        ))
    }

    func historySnapshot(
        range: UsageHistoryRange,
        provider: Provider?,
        ignoreCache: Bool = false
    ) async throws -> UsageHistorySnapshot {
        if !ignoreCache,
           provider == nil,
           let cached = state.historyState.snapshots?[range] {
            return cached
        }
        guard isReadyForSources else { throw AppUsageQueryError.historyUnavailable }
        return try await queryService.history(
            range: range,
            now: now(),
            calendar: calendar,
            provider: provider
        )
    }

    @discardableResult
    func shutdown() async -> Bool {
        if let shutdownTask {
            return await shutdownTask.value
        }
        terminationRecoveryGate = .terminating
        if let restoreActivity {
            await restoreActivity.task.value
        }
        if let preservationActivity {
            await preservationActivity.task.value
        }
        guard settingsState.databaseRecoveryDisposition != .preservationRetryRequired else {
            if terminationRecoveryGate == .terminating {
                terminationRecoveryGate = .idle
            }
            return false
        }
        if let shutdownTask {
            return await shutdownTask.value
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return true }
            let succeeded = await self.performShutdown()
            if !succeeded { self.shutdownTask = nil }
            return succeeded
        }
        shutdownTask = task
        let succeeded = await task.value
        if !succeeded, terminationRecoveryGate == .terminating {
            terminationRecoveryGate = .idle
        }
        return succeeded
    }

    private func performShutdown() async -> Bool {
        guard state.lifecycle != .stopped else { return true }

        guard case .success = await prepareForDatabaseRecovery() else {
            return false
        }

        publishStoppedState()
        return true
    }

    func publishStoppedState() {
        lastSummary = nil
        var next = state
        next.lifecycle = .stopped
        next.presentation = nil
        next.historyState = .idle
        next.grantedProviders = []
        next.sourceFileCounts = [:]
        next.lastSuccessfulScans = [:]
        next.sourceHealth = [.claudeCode: .notGranted, .codex: .notGranted]
        next.lastUpdated = nil
        next.isImporting = false
        next.onboardingRequired = false
        state = next
    }

    func prepareForDatabaseRecovery() async -> Result<Void, any Error> {
        if let recoveryBarrierTask {
            return await recoveryBarrierTask.value
        }
        let task = Task { @MainActor [weak self] () -> Result<Void, any Error> in
            guard let self else { return .success(()) }
            do {
                try await self.performRecoveryBarrier()
                return .success(())
            } catch {
                self.recoveryBarrierTask = nil
                return .failure(error)
            }
        }
        recoveryBarrierTask = task
        return await task.value
    }

    private func performRecoveryBarrier() async throws {
        isWriterQuiescing = true

        lifecycleGeneration &+= 1
        sourceMutationGeneration &+= 1
        readyGeneration = nil
        queryGeneration &+= 1
        historyQueryGeneration &+= 1
        let startup = startupTask
        let currentActivity = activity?.task
        let currentSourceMutation = sourceMutation?.task
        let currentSettingsActivity = settingsActivity?.task
        let currentResultConsumer = resultConsumerTask
        let currentPricingUpdateConsumer = pricingUpdateConsumerTask
        let currentQueries = Array(inFlightQueries.values)
        let currentHistoryQueries = Array(inFlightHistoryQueries.values)
        startup?.cancel()
        currentActivity?.cancel()
        currentSourceMutation?.cancel()
        currentResultConsumer?.cancel()
        currentPricingUpdateConsumer?.cancel()
        currentQueries.forEach { $0.cancel() }
        currentHistoryQueries.forEach { $0.cancel() }
        pendingIngestionResults.removeAll()
        knownIngestionResults.removeAll()
        settleAllIngestionWaiters()
        inFlightCoordinatorInventoryRequests = 0
        var next = state
        next.lifecycle = .shuttingDown
        next.isImporting = false
        next.onboardingRequired = false
        state = next

        await coordinator.stop()
        await startup?.value
        await currentActivity?.value
        await currentSourceMutation?.value
        await currentSettingsActivity?.value
        await currentResultConsumer?.value
        await currentPricingUpdateConsumer?.value
        for query in currentQueries { _ = await query.value }
        for query in currentHistoryQueries { _ = await query.value }

        await coordinator.stop()
        let remainingQueries = Array(inFlightQueries.values)
        remainingQueries.forEach { $0.cancel() }
        for query in remainingQueries { _ = await query.value }
        try await pricingInbox.quiesce()
        try await pricingInbox.stop()
        let finalQueries = Array(inFlightQueries.values)
        finalQueries.forEach { $0.cancel() }
        for query in finalQueries { _ = await query.value }
        await settingsActivity?.task.value
        coordinatorStatus = .inactive
        inboxStatus = .inactive
        startupTask = nil
        activity = nil
        sourceMutation = nil
        settingsActivity = nil
        resultConsumerTask = nil
        pricingUpdateConsumerTask = nil
        lastAppliedSequence.removeAll()
        isProcessingIngestionResults = false
        inFlightQueries.removeAll()
        inFlightHistoryQueries.removeAll()
        closeActiveGrants()
        try await ledger.shutdown()
    }

}

enum TerminationRecoveryGate: Equatable {
    case idle
    case restoring
    case preserving
    case terminating
}
