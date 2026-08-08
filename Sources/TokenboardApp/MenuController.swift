import AppKit
import Combine
import TokenboardCore

@MainActor
struct BuiltNativeMenu {
    let menu: NSMenu
    let statusTitle: String
    let updatedItem: NSMenuItem
}

@MainActor
protocol StatusItemHosting: AnyObject {
    var menu: NSMenu? { get set }
    var title: String { get set }
}

@MainActor
private final class SystemStatusItemHost: StatusItemHosting {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    var menu: NSMenu? {
        get { statusItem.menu }
        set { statusItem.menu = newValue }
    }

    var title: String {
        get { statusItem.button?.title ?? "" }
        set { statusItem.button?.title = newValue }
    }
}

@MainActor
enum NativeMenuBuilder {
    static func makeMenu(
        state: AppPublishedState?,
        startupError: String?,
        target: AnyObject?,
        availableDisplayCurrencies: Set<DisplayCurrency> = Set(DisplayCurrency.allCases),
        isRestoringDatabase: Bool = false,
        requiresRelaunch: Bool = false,
        preservationRetryRequired: Bool = false,
        preservationFailed: Bool = false
    ) -> BuiltNativeMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let statusTitle: String

        if let presentation = state?.presentation {
            statusTitle = presentation.statusTitle
            menu.addDisabledItem(presentation.tokenTitle)
            menu.addDisabledItem(presentation.apiValueTitle)
        } else {
            statusTitle = startupError == nil ? "…" : "Unavailable"
            menu.addDisabledItem("Token total unavailable")
            menu.addDisabledItem("API equivalent unavailable")
        }

        menu.addItem(.separator())
        let regularActionsEnabled = !isRestoringDatabase
            && !requiresRelaunch
            && !preservationRetryRequired
            && !preservationFailed
        menu.addItem(periodMenuItem(
            state: state,
            target: target,
            isEnabled: regularActionsEnabled
        ))
        menu.addItem(currencyMenuItem(
            state: state,
            target: target,
            availableCurrencies: availableDisplayCurrencies,
            isEnabled: regularActionsEnabled
        ))
        menu.addItem(displayMetricMenuItem(
            state: state,
            target: target,
            isEnabled: regularActionsEnabled
        ))
        menu.addItem(.separator())

        if state == nil {
            menu.addDisabledItem(startupError ?? "Sources unavailable")
        }
        let updatedItem = menu.addDisabledItem("Updated never")

        menu.addItem(.separator())
        menu.addItem(actionItem(
            "Refresh Now",
            action: NSSelectorFromString("refresh"),
            target: target,
            keyEquivalent: "r",
            isEnabled: regularActionsEnabled
        ))
        var pricingTitle = "Pricing"
        if let unpriced = state?.presentation?.unpricedTitle {
            pricingTitle += " (\(unpriced))"
        }
        menu.addItem(actionItem(
            pricingTitle,
            action: NSSelectorFromString("openPricing"),
            target: target,
            isEnabled: regularActionsEnabled
        ))
        menu.addItem(actionItem(
            "Settings",
            action: NSSelectorFromString("openSettings"),
            target: target,
            keyEquivalent: ",",
            isEnabled: !isRestoringDatabase
        ))
        menu.addItem(.separator())
        menu.addItem(actionItem(
            "Quit Tokenboard",
            action: NSSelectorFromString("quit"),
            target: target,
            keyEquivalent: "q",
            isEnabled: !isRestoringDatabase && !preservationRetryRequired
        ))
        return BuiltNativeMenu(menu: menu, statusTitle: statusTitle, updatedItem: updatedItem)
    }

    private static func periodMenuItem(
        state: AppPublishedState?,
        target: AnyObject?,
        isEnabled: Bool
    ) -> NSMenuItem {
        let selectedTitle = state.map { periodTitle($0.selectedPeriod) }
        let parent = NSMenuItem(
            title: selectedTitle.map { "Period: \($0)" } ?? "Period",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu(title: "Period")
        submenu.autoenablesItems = false
        let choices: [(CalendarPeriod, String)] = [
            (.today, "Today"),
            (.thisWeek, "This Week"),
            (.thisMonth, "This Month"),
            (.thisYear, "This Year"),
            (.allTime, "All Time")
        ]
        for (period, title) in choices {
            let item = actionItem(
                title,
                action: NSSelectorFromString("selectPeriod:"),
                target: target,
                isEnabled: isEnabled
            )
            item.representedObject = period.rawValue
            item.state = state?.selectedPeriod == period ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        parent.isEnabled = isEnabled
        return parent
    }

    private static func displayMetricMenuItem(
        state: AppPublishedState?,
        target: AnyObject?,
        isEnabled: Bool
    ) -> NSMenuItem {
        let selectedTitle = state.map { displayMetricTitle($0.selectedDisplayMetric) }
        let parent = NSMenuItem(
            title: selectedTitle.map { "Menu Bar: \($0)" } ?? "Menu Bar",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu(title: "Menu Bar")
        submenu.autoenablesItems = false
        for (metric, title) in [(DisplayMetric.tokens, "Tokens"), (.apiValue, "API Value")] {
            let item = actionItem(
                title,
                action: NSSelectorFromString("selectDisplayMetric:"),
                target: target,
                isEnabled: isEnabled
            )
            item.representedObject = metric.rawValue
            item.state = state?.selectedDisplayMetric == metric ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        parent.isEnabled = isEnabled
        return parent
    }

    private static func currencyMenuItem(
        state: AppPublishedState?,
        target: AnyObject?,
        availableCurrencies: Set<DisplayCurrency>,
        isEnabled: Bool
    ) -> NSMenuItem {
        let selectedCurrency = state?.selectedDisplayCurrency
        let parent = NSMenuItem(
            title: selectedCurrency.map { "Currency: \($0.rawValue)" } ?? "Currency",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu(title: "Currency")
        submenu.autoenablesItems = false
        for currency in DisplayCurrency.allCases {
            let item = actionItem(
                currency.rawValue,
                action: NSSelectorFromString("selectDisplayCurrency:"),
                target: target,
                isEnabled: isEnabled && availableCurrencies.contains(currency)
            )
            item.representedObject = currency.rawValue
            item.state = selectedCurrency == currency ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        parent.isEnabled = isEnabled
        return parent
    }

    private static func actionItem(
        _ title: String,
        action: Selector,
        target: AnyObject?,
        keyEquivalent: String = "",
        isEnabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        item.isEnabled = isEnabled
        return item
    }

    private static func periodTitle(_ period: CalendarPeriod) -> String {
        switch period {
        case .today: "Today"
        case .thisWeek: "This Week"
        case .thisMonth: "This Month"
        case .thisYear: "This Year"
        case .allTime: "All Time"
        }
    }

    private static func displayMetricTitle(_ metric: DisplayMetric) -> String {
        switch metric {
        case .tokens: "Tokens"
        case .apiValue: "API Value"
        }
    }
}

@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let statusItem: any StatusItemHosting
    private let model: AppModel?
    private let startupError: String?
    private var stateObservation: AnyCancellable?
    private weak var updatedItem: NSMenuItem?

    init(
        model: AppModel,
        statusItem: any StatusItemHosting = SystemStatusItemHost()
    ) {
        self.statusItem = statusItem
        self.model = model
        startupError = nil
        super.init()
        stateObservation = model.$state
            .combineLatest(model.$settingsState)
            .dropFirst()
            .sink { [weak self] state, settings in
                self?.rebuildMenu(
                    state: state,
                    exchangeRates: settings.pricing.exchangeRates,
                    isRestoringDatabase: settings.isRestoringDatabase,
                    disposition: settings.databaseRecoveryDisposition
                )
            }
        rebuildMenu(
            state: model.state,
            exchangeRates: model.settingsState.pricing.exchangeRates,
            isRestoringDatabase: model.settingsState.isRestoringDatabase,
            disposition: model.settingsState.databaseRecoveryDisposition
        )
    }

    init(
        startupError: Error,
        statusItem: any StatusItemHosting = SystemStatusItemHost()
    ) {
        self.statusItem = statusItem
        model = nil
        self.startupError = "Startup paused: \(String(describing: startupError))"
        super.init()
        rebuildMenu(
            state: nil,
            exchangeRates: nil,
            isRestoringDatabase: false,
            disposition: .none
        )
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let updatedItem else { return }
        let relative: String
        if let lastUpdated = model?.health.lastSuccessfulScan {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            relative = formatter.localizedString(for: lastUpdated, relativeTo: Date())
        } else {
            relative = "never"
        }
        updatedItem.title = "Updated \(relative)"
    }

    var renderedMenu: NSMenu? { statusItem.menu }
    var renderedStatusTitle: String? { statusItem.title }

    private func rebuildMenu(
        state: AppPublishedState?,
        exchangeRates: ExchangeRateSnapshot?,
        isRestoringDatabase: Bool,
        disposition: DatabaseRecoveryDisposition
    ) {
        var availableDisplayCurrencies: Set<DisplayCurrency> = [.usd]
        if let exchangeRates {
            availableDisplayCurrencies.formUnion(exchangeRates.rates.keys)
        }
        let built = NativeMenuBuilder.makeMenu(
            state: state,
            startupError: startupError,
            target: self,
            availableDisplayCurrencies: availableDisplayCurrencies,
            isRestoringDatabase: isRestoringDatabase,
            requiresRelaunch: disposition == .requiresRelaunch,
            preservationRetryRequired: disposition == .preservationRetryRequired,
            preservationFailed: disposition == .preservationFailed
        )
        built.menu.delegate = self
        statusItem.title = built.statusTitle
        updatedItem = built.updatedItem
        statusItem.menu = built.menu
    }

    @objc func refresh() {
        guard let model else { return }
        Task { await model.refresh() }
    }

    @objc func selectPeriod(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let period = CalendarPeriod(rawValue: rawValue),
              let model else { return }
        Task { await model.select(period: period) }
    }

    @objc func selectDisplayMetric(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let metric = DisplayMetric(rawValue: rawValue),
              let model else { return }
        Task { await model.select(displayMetric: metric) }
    }

    @objc func selectDisplayCurrency(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let currency = DisplayCurrency(rawValue: rawValue),
              let model else { return }
        model.select(displayCurrency: currency)
    }

    @objc func openPricing() { model?.openPricing() }
    @objc func openSettings() { model?.openSettings() }
    @objc func quit() { NSApplication.shared.terminate(nil) }
}

private extension NSMenu {
    @discardableResult
    func addDisabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
        return item
    }
}
