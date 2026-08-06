import Combine
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
}

protocol AppUsageQuerying: Sendable {
    func summary(
        period: CalendarPeriod,
        now: Date,
        calendar: Calendar
    ) async throws -> UsageSummary
}

protocol AppIngestionCoordinating: Sendable {
    func start(roots: [Provider: URL]) async throws
    func refreshAll() async
    func stop() async
}

protocol AppPricingInboxWatching: Sendable {
    func start() async throws
    func stop() async throws
}

extension SQLiteLedger: AppLedgerRuntime {}
extension UsageQueryService: AppUsageQuerying {}
extension IngestionCoordinator: AppIngestionCoordinating {}
extension PricingInbox: AppPricingInboxWatching {}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var presentation: MenuPresentation?
    @Published private(set) var sourceHealth: [Provider: SourceHealth] = [
        .claudeCode: .notGranted,
        .codex: .notGranted
    ]
    @Published private(set) var sourceFileCounts: [Provider: Int] = [:]
    @Published private(set) var onboardingRequired = false
    @Published private(set) var selectedPeriod: CalendarPeriod
    @Published private(set) var selectedDisplayMetric: DisplayMetric
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var revision = 0

    var onOpenPricing: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let ledger: any AppLedgerRuntime
    private let queryService: any AppUsageQuerying
    private let coordinator: any AppIngestionCoordinating
    private let pricingInbox: any AppPricingInboxWatching
    private let grantStore: SourceGrantStore
    private let grantController: SourceGrantController
    private let preferences: AppPreferences
    private let bundledCatalogData: Data
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let discovery: LogDiscovery
    private var activeGrants: [Provider: ActiveSourceGrant] = [:]
    private var lastSummary: UsageSummary?
    private var started = false
    private var coordinatorStarted = false
    private var inboxStarted = false
    private var isShutdown = false

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
        discovery: LogDiscovery = LogDiscovery()
    ) {
        self.ledger = ledger
        self.queryService = queryService
        self.coordinator = coordinator
        self.pricingInbox = pricingInbox
        self.grantStore = grantStore
        self.grantController = SourceGrantController(store: grantStore)
        self.preferences = preferences
        self.bundledCatalogData = bundledCatalogData
        self.now = now
        self.calendar = calendar
        self.discovery = discovery
        selectedPeriod = preferences.selectedPeriod
        selectedDisplayMetric = preferences.selectedDisplayMetric
    }

    var canStartHistoricalImport: Bool {
        Provider.allCases.allSatisfy { activeGrants[$0] != nil }
    }

    func hasActiveGrant(for provider: Provider) -> Bool {
        activeGrants[provider] != nil
    }

    func start() async {
        guard !started, !isShutdown else { return }
        started = true
        do {
            try await ledger.migrate()
            try await ledger.integrityCheck()
            try await installBundledCatalogIfNeeded()
            try await pricingInbox.start()
            inboxStarted = true
            resolveStoredGrants()
            guard canStartHistoricalImport,
                  preferences.historicalImportApproved else {
                onboardingRequired = true
                if preferences.historicalImportApproved {
                    try await querySelectedSummary()
                }
                publishChange()
                return
            }
            try await startCoordinatorAndQuery()
        } catch {
            publishWarning("Startup paused: \(Self.errorDescription(error))")
        }
    }

    func startHistoricalImport() async {
        guard !isShutdown else { return }
        guard canStartHistoricalImport else {
            onboardingRequired = true
            publishChange()
            return
        }

        preferences.historicalImportApproved = true
        onboardingRequired = false
        for provider in Provider.allCases {
            sourceHealth[provider] = .indexing(fileCount: sourceFileCounts[provider, default: 0])
        }
        publishChange()

        do {
            try await startCoordinatorAndQuery()
        } catch {
            publishWarning("Historical import paused: \(Self.errorDescription(error))")
        }
    }

    func refresh() async {
        guard preferences.historicalImportApproved, canStartHistoricalImport else {
            onboardingRequired = true
            publishChange()
            return
        }
        do {
            if coordinatorStarted {
                await coordinator.refreshAll()
            } else {
                try await coordinator.start(roots: activeRoots())
                coordinatorStarted = true
            }
            try await querySelectedSummary()
            markSourcesHealthy()
        } catch {
            publishWarning("Refresh paused: \(Self.errorDescription(error))")
        }
    }

    func select(period: CalendarPeriod) async {
        selectedPeriod = period
        preferences.selectedPeriod = period
        publishChange()
        await requeryWithoutScanning()
    }

    func select(displayMetric: DisplayMetric) async {
        selectedDisplayMetric = displayMetric
        preferences.selectedDisplayMetric = displayMetric
        if let lastSummary {
            presentation = makePresentation(summary: lastSummary)
        }
        publishChange()
        await requeryWithoutScanning()
    }

    func chooseSource(_ provider: Provider) async {
        do {
            guard try grantController.select(provider: provider) != nil else { return }
            if coordinatorStarted {
                await coordinator.stop()
                coordinatorStarted = false
            }
            activeGrants[provider]?.close()
            activeGrants[provider] = nil
            try openStoredGrant(for: provider)
            onboardingRequired = !canStartHistoricalImport || !preferences.historicalImportApproved
            publishChange()
            if canStartHistoricalImport, preferences.historicalImportApproved {
                try await startCoordinatorAndQuery()
            }
        } catch {
            sourceHealth[provider] = .warning(
                message: "Access unavailable: \(Self.errorDescription(error))"
            )
            onboardingRequired = true
            publishChange()
        }
    }

    func openPricing() { onOpenPricing?() }
    func openSettings() { onOpenSettings?() }

    func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        await coordinator.stop()
        coordinatorStarted = false
        if inboxStarted {
            do {
                try await pricingInbox.stop()
            } catch {
                publishWarning("Pricing shutdown warning: \(Self.errorDescription(error))")
            }
            inboxStarted = false
        }
        closeActiveGrants()
    }

    private func installBundledCatalogIfNeeded() async throws {
        guard try await ledger.latestAppliedPricingCatalogJSON() == nil else { return }
        let loaded = try PricingCatalogLoader().load(bundledCatalogData)
        let validated = try PricingCatalogValidator().validate(loaded)
        try await ledger.applyPricingCatalog(
            validated,
            canonicalJSON: validated.canonicalJSON,
            origin: PricingImportMetadata.bundledRepositoryOrigin,
            validationSummary: PricingImportMetadata.schemaV1ValidSummary
        )
    }

    private func resolveStoredGrants() {
        for provider in Provider.allCases {
            do {
                try openStoredGrant(for: provider)
            } catch {
                activeGrants[provider]?.close()
                activeGrants[provider] = nil
                sourceHealth[provider] = .warning(
                    message: "Access unavailable: \(Self.errorDescription(error))"
                )
            }
        }
    }

    private func openStoredGrant(for provider: Provider) throws {
        activeGrants[provider]?.close()
        activeGrants[provider] = nil
        guard let grant = try grantStore.openGrant(for: provider) else {
            sourceFileCounts[provider] = nil
            sourceHealth[provider] = .notGranted
            return
        }
        activeGrants[provider] = grant
        let fileCount = try discovery.jsonlFiles(under: grant.root).count
        sourceFileCounts[provider] = fileCount
        sourceHealth[provider] = .indexing(fileCount: fileCount)
    }

    private func startCoordinatorAndQuery() async throws {
        guard canStartHistoricalImport, preferences.historicalImportApproved else { return }
        if !coordinatorStarted {
            try await coordinator.start(roots: activeRoots())
            coordinatorStarted = true
        }
        try await querySelectedSummary()
        markSourcesHealthy()
        onboardingRequired = false
        publishChange()
    }

    private func requeryWithoutScanning() async {
        guard preferences.historicalImportApproved else { return }
        do {
            try await querySelectedSummary()
        } catch {
            publishWarning("Summary unavailable: \(Self.errorDescription(error))")
        }
    }

    private func querySelectedSummary() async throws {
        let summary = try await queryService.summary(
            period: selectedPeriod,
            now: now(),
            calendar: calendar
        )
        lastSummary = summary
        presentation = makePresentation(summary: summary)
    }

    private func makePresentation(summary: UsageSummary) -> MenuPresentation {
        MenuPresentation(
            summary: summary,
            displayMetric: selectedDisplayMetric,
            hasHealthWarning: sourceHealth.values.contains(where: Self.isWarning)
        )
    }

    private func markSourcesHealthy() {
        let updated = now()
        lastUpdated = updated
        for provider in Provider.allCases {
            sourceHealth[provider] = .healthy(
                fileCount: sourceFileCounts[provider, default: 0],
                lastUpdated: updated
            )
        }
        if let lastSummary {
            presentation = makePresentation(summary: lastSummary)
        }
    }

    private func activeRoots() -> [Provider: URL] {
        Dictionary(uniqueKeysWithValues: activeGrants.map { ($0.key, $0.value.root) })
    }

    private func closeActiveGrants() {
        for grant in activeGrants.values { grant.close() }
        activeGrants.removeAll()
    }

    private func publishWarning(_ message: String) {
        for provider in Provider.allCases {
            sourceHealth[provider] = .warning(message: message)
        }
        if let lastSummary {
            presentation = makePresentation(summary: lastSummary)
        }
        publishChange()
    }

    private func publishChange() { revision &+= 1 }

    private static func isWarning(_ health: SourceHealth) -> Bool {
        switch health {
        case .notGranted, .warning:
            return true
        case .indexing, .healthy:
            return false
        }
    }

    private static func errorDescription(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
