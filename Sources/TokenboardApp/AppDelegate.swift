import AppKit
import Combine
import TokenboardCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var menuController: MenuController?
    private var onboardingController: OnboardingWindowController?
    private var onboardingObservation: AnyCancellable?
    private var terminationPending = false

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
                bundledCatalogData: bundledCatalogData
            )
            self.model = model
            menuController = MenuController(model: model)
            let onboardingController = OnboardingWindowController(model: model)
            self.onboardingController = onboardingController
            model.onOpenSettings = { [weak onboardingController] in
                onboardingController?.present()
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
        guard let model else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
