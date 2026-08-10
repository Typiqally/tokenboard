import AppKit
import Combine
import TokenboardCore

@MainActor
struct BuiltNativeMenu {
    let menu: NSMenu
    let statusTitle: String
    let summaryView: MenuSummaryView
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
        let summaryContent: MenuSummaryContent

        if let state, let presentation = state.presentation {
            statusTitle = presentation.statusTitle
            summaryContent = MenuSummaryContent(
                contextTitle: periodTitle(state.selectedPeriod),
                visualRecencyTitle: "Updated never",
                accessibilityRecencyTitle: "Updated never",
                tokenTitle: presentation.tokenTitle,
                apiValueTitle: presentation.apiValueTitle
            )
        } else {
            statusTitle = startupError == nil ? "…" : "Unavailable"
            summaryContent = MenuSummaryContent(
                contextTitle: startupError == nil ? "Starting" : "Unavailable",
                visualRecencyTitle: "Updated never",
                accessibilityRecencyTitle: "Updated never",
                tokenTitle: "Token total unavailable",
                apiValueTitle: "API equivalent unavailable"
            )
        }

        let summaryView = MenuSummaryView(content: summaryContent)
        let summaryItem = NSMenuItem(title: "Usage Summary", action: nil, keyEquivalent: "")
        summaryItem.isEnabled = false
        summaryItem.view = summaryView
        menu.addItem(summaryItem)
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
            menu.addItem(.separator())
        }
        menu.addItem(actionItem(
            "Refresh Now",
            action: NSSelectorFromString("refresh"),
            target: target,
            keyEquivalent: "r",
            systemSymbolName: "arrow.clockwise",
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
            systemSymbolName: "banknote",
            isEnabled: regularActionsEnabled
        ))
        menu.addItem(actionItem(
            "Settings",
            action: NSSelectorFromString("openSettings"),
            target: target,
            keyEquivalent: ",",
            systemSymbolName: "gearshape",
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
        return BuiltNativeMenu(
            menu: menu,
            statusTitle: statusTitle,
            summaryView: summaryView
        )
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
        systemSymbolName: String? = nil,
        isEnabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        item.isEnabled = isEnabled
        if let systemSymbolName,
           let image = NSImage(
               systemSymbolName: systemSymbolName,
               accessibilityDescription: nil
           ) {
            image.isTemplate = true
            item.image = image
        }
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
    private weak var summaryView: MenuSummaryView?

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
        guard let summaryView else { return }
        let visualRelative: String
        let accessibilityRelative: String
        if let lastUpdated = model?.health.lastSuccessfulScan {
            let visualFormatter = RelativeDateTimeFormatter()
            visualFormatter.unitsStyle = .abbreviated
            visualRelative = visualFormatter.localizedString(
                for: lastUpdated,
                relativeTo: Date()
            )

            let accessibilityFormatter = RelativeDateTimeFormatter()
            accessibilityFormatter.unitsStyle = .full
            accessibilityRelative = accessibilityFormatter.localizedString(
                for: lastUpdated,
                relativeTo: Date()
            )
        } else {
            visualRelative = "never"
            accessibilityRelative = "never"
        }
        summaryView.updateRecency(
            visualTitle: "Updated \(visualRelative)",
            accessibilityTitle: "Updated \(accessibilityRelative)"
        )
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
        summaryView = built.summaryView
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
