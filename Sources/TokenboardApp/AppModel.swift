import Combine
import Foundation
import TokenboardCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: AppPublishedState

    var onOpenPricing: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    var presentation: MenuPresentation? { state.presentation }
    var sourceHealth: [Provider: SourceHealth] { state.sourceHealth }
    var sourceFileCounts: [Provider: Int] { state.sourceFileCounts }
    var onboardingRequired: Bool { state.onboardingRequired }
    var selectedPeriod: CalendarPeriod { state.selectedPeriod }
    var selectedDisplayMetric: DisplayMetric { state.selectedDisplayMetric }
    var lastUpdated: Date? { state.lastUpdated }
    var canStartHistoricalImport: Bool { state.canStartHistoricalImport }

    let ledger: any AppLedgerRuntime
    let queryService: any AppUsageQuerying
    let coordinator: any AppIngestionCoordinating
    let pricingInbox: any AppPricingInboxWatching
    let grantStore: SourceGrantStore
    let sourcePicker: any AppSourcePicking
    let preferences: AppPreferences
    let bundledCatalogData: Data
    let now: @Sendable () -> Date
    let calendar: Calendar
    let discovery: any LogDiscovering
    var activeGrants: [Provider: ActiveSourceGrant] = [:]
    var lastSummary: UsageSummary?
    var lifecycleGeneration: UInt64 = 0
    var readyGeneration: UInt64?
    var queryGeneration: UInt64 = 0
    var inFlightQueries: [UInt64: Task<Result<UsageSummary, Error>, Never>] = [:]
    var activityGeneration: UInt64 = 0
    var startupTask: Task<Void, Never>?
    var activity: AppRuntimeActivity?
    var shutdownTask: Task<Void, Never>?
    var resultConsumerTask: Task<Void, Never>?
    var pendingIngestionResults: [IngestionResultKey: IngestionBatchResult] = [:]
    var knownIngestionResults: Set<IngestionResultKey> = []
    var ingestionResultWaiters: [IngestionResultKey: [CheckedContinuation<Void, Never>]] = [:]
    var lastAppliedSequence: [UInt64: UInt64] = [:]
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
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current,
        discovery: any LogDiscovering = LogDiscovery(),
        sourcePicker: (any AppSourcePicking)? = nil
    ) {
        self.ledger = ledger
        self.queryService = queryService
        self.coordinator = coordinator
        self.pricingInbox = pricingInbox
        self.grantStore = grantStore
        self.sourcePicker = sourcePicker ?? SourceGrantController()
        self.preferences = preferences
        self.bundledCatalogData = bundledCatalogData
        self.now = now
        self.calendar = calendar
        self.discovery = discovery
        state = .initial(
            period: preferences.selectedPeriod,
            displayMetric: preferences.selectedDisplayMetric,
            historicalImportApproved: preferences.historicalImportApproved
        )
    }

    func hasActiveGrant(for provider: Provider) -> Bool {
        activeGrants[provider] != nil
    }

    func commitState(_ next: AppPublishedState) {
        state = next
    }

    func start() async {
        guard state.lifecycle != .ready else { return }
        guard await ensureReady(retryFailed: false) else { return }
        await finishStartupBehavior()
    }

    func startHistoricalImport() async {
        guard isReadyForSources,
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
        guard await ensureReady(retryFailed: true) else { return }
        guard isReadyForSources else { return }
        guard preferences.historicalImportApproved,
              hasEveryGrant else {
            var next = state
            next.onboardingRequired = true
            state = next
            if preferences.historicalImportApproved {
                await querySelectedSummary()
            }
            return
        }
        if let activity {
            await activity.task.value
            return
        }
        await launchIngestion(refreshExisting: true)
    }

    func select(period: CalendarPeriod) async {
        guard state.lifecycle != .stopped,
              state.lifecycle != .shuttingDown else { return }
        preferences.selectedPeriod = period
        var next = state
        next.selectedPeriod = period
        state = next
        await requeryWithoutScanning()
    }

    func select(displayMetric: DisplayMetric) async {
        guard state.lifecycle != .stopped,
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

    func chooseSource(_ provider: Provider) async {
        guard isReadyForSources else { return }
        if let activity { await activity.task.value }
        guard isReadyForSources else { return }
        do {
            guard let url = try sourcePicker.select(provider: provider) else { return }
            await launchReplacement(provider: provider, url: url)
        } catch {
            return
        }
    }

    func openPricing() { onOpenPricing?() }
    func openSettings() { onOpenSettings?() }

    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performShutdown()
        }
        shutdownTask = task
        await task.value
    }

    private func performShutdown() async {
        guard state.lifecycle != .stopped else { return }

        lifecycleGeneration &+= 1
        readyGeneration = nil
        queryGeneration &+= 1
        let startup = startupTask
        let currentActivity = activity?.task
        let currentResultConsumer = resultConsumerTask
        let currentQueries = Array(inFlightQueries.values)
        startup?.cancel()
        currentActivity?.cancel()
        currentResultConsumer?.cancel()
        currentQueries.forEach { $0.cancel() }
        pendingIngestionResults.removeAll()
        knownIngestionResults.removeAll()
        settleAllIngestionWaiters()
        var next = state
        next.lifecycle = .shuttingDown
        next.isImporting = false
        next.onboardingRequired = false
        state = next

        await coordinator.stop()
        if inboxStatus != .inactive {
            try? await pricingInbox.stop()
        }
        await startup?.value
        await currentActivity?.value
        await currentResultConsumer?.value
        for query in currentQueries { _ = await query.value }

        await coordinator.stop()
        if inboxStatus != .inactive {
            try? await pricingInbox.stop()
        }
        coordinatorStatus = .inactive
        inboxStatus = .inactive
        startupTask = nil
        activity = nil
        resultConsumerTask = nil
        lastAppliedSequence.removeAll()
        isProcessingIngestionResults = false
        inFlightQueries.removeAll()
        closeActiveGrants()
        lastSummary = nil

        next = state
        next.lifecycle = .stopped
        next.presentation = nil
        next.grantedProviders = []
        next.sourceFileCounts = [:]
        next.sourceHealth = [.claudeCode: .notGranted, .codex: .notGranted]
        next.lastUpdated = nil
        next.isImporting = false
        next.onboardingRequired = false
        state = next
    }

}
