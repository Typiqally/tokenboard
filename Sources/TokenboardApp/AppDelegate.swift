import AppKit
import Combine
import TokenboardCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var menuController: MenuController?
    private var onboardingController: OnboardingWindowController?
    private var settingsController: SettingsWindowController?
    private var onboardingObservation: AnyCancellable?
    private var terminationPending = false

    override init() {
        super.init()
    }

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let paths = try ApplicationPaths.resolve()
            let bundledCatalogURL = try bundledCatalogURL()
            let bundledCatalogData = try Data(contentsOf: bundledCatalogURL)
            let ledger = try SQLiteLedger(databaseURL: paths.ledger, backupDirectory: paths.backups)
            let scanner = IncrementalScanner(ledger: ledger)
            let coordinator = IngestionCoordinator(scanner: scanner)
            let pricingInbox = PricingInbox(
                ledger: ledger,
                applicationSupportDirectory: paths.root,
                bundledCatalogData: bundledCatalogData
            )
            let preferences = AppPreferences()
            let grantStore = SourceGrantStore()
            let model = AppModel(
                ledger: ledger,
                queryService: UsageQueryService(ledger: ledger),
                coordinator: coordinator,
                pricingInbox: pricingInbox,
                grantStore: grantStore,
                preferences: preferences,
                bundledCatalogData: bundledCatalogData,
                applicationPaths: paths
            )
            self.model = model
            menuController = MenuController(model: model)
            let onboardingController = OnboardingWindowController(model: model)
            self.onboardingController = onboardingController
            let settingsController = SettingsWindowController(model: model)
            self.settingsController = settingsController
            model.onOpenSettings = { [weak settingsController] in
                settingsController?.showWindow(nil)
            }
            model.onOpenPricing = { [weak settingsController] in
                settingsController?.showWindow(nil)
            }
            onboardingObservation = model.$state
                .map(\.onboardingRequired)
                .removeDuplicates()
                .sink { [weak self] required in
                    self?.onboardingController?.update(isRequired: required)
                }
            Task { await model.start() }
        } catch {
            menuController = MenuController(startupError: error)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model != nil else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task {
            let shutdownSucceeded = await shutdownForTermination()
            if !shutdownSucceeded { terminationPending = false }
            sender.reply(toApplicationShouldTerminate: shutdownSucceeded)
        }
        return .terminateLater
    }

    func shutdownForTermination() async -> Bool {
        guard let model else { return true }
        return await model.shutdown()
    }

    private func bundledCatalogURL() throws -> URL {
        guard let url = Bundle.main.url(
            forResource: "tokenboard-pricing",
            withExtension: "json"
        ) else {
            throw AppStartupError.missingBundledCatalog
        }
        return url
    }
}

private enum AppStartupError: Error {
    case missingBundledCatalog
}
