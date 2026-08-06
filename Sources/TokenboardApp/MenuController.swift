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
enum NativeMenuBuilder {
    static func makeMenu(
        state: AppPublishedState?,
        startupError: String?,
        target: AnyObject?
    ) -> BuiltNativeMenu {
        let menu = NSMenu()
        let statusTitle: String

        if let presentation = state?.presentation {
            statusTitle = presentation.statusTitle
            menu.addDisabledItem(presentation.tokenTitle)
            menu.addDisabledItem(presentation.apiValueTitle)
            if let unpricedTitle = presentation.unpricedTitle {
                menu.addDisabledItem(unpricedTitle)
            }
        } else {
            let warning = startupError != nil || state?.sourceHealth.values.contains(where: {
                switch $0 {
                case .notGranted, .warning: true
                case .indexing, .healthy: false
                }
            }) == true
            statusTitle = warning ? "⚠ Unavailable" : "◉ …"
            menu.addDisabledItem("Token total unavailable")
            menu.addDisabledItem("API equivalent unavailable")
        }

        menu.addItem(.separator())
        menu.addItem(periodMenuItem(state: state, target: target))
        menu.addItem(displayMetricMenuItem(state: state, target: target))
        menu.addItem(.separator())

        if let state {
            menu.addDisabledItem(healthTitle(
                state.sourceHealth[.claudeCode],
                name: "Claude Code"
            ))
            menu.addDisabledItem(healthTitle(state.sourceHealth[.codex], name: "Codex"))
        } else {
            menu.addDisabledItem("Claude Code: \(startupError ?? "Unavailable")")
            menu.addDisabledItem("Codex: \(startupError ?? "Unavailable")")
        }
        let updatedItem = menu.addDisabledItem("Updated never · Local only")

        menu.addItem(.separator())
        menu.addItem(actionItem(
            "Refresh Now",
            action: NSSelectorFromString("refresh"),
            target: target,
            keyEquivalent: "r"
        ))
        var pricingTitle = "Pricing"
        if let unpriced = state?.presentation?.unpricedTitle {
            pricingTitle += " ⚠ \(unpriced)"
        }
        menu.addItem(actionItem(
            pricingTitle,
            action: NSSelectorFromString("openPricing"),
            target: target
        ))
        menu.addItem(actionItem(
            "Settings",
            action: NSSelectorFromString("openSettings"),
            target: target,
            keyEquivalent: ","
        ))
        menu.addItem(.separator())
        menu.addItem(actionItem(
            "Quit Tokenboard",
            action: NSSelectorFromString("quit"),
            target: target,
            keyEquivalent: "q"
        ))
        return BuiltNativeMenu(menu: menu, statusTitle: statusTitle, updatedItem: updatedItem)
    }

    private static func periodMenuItem(
        state: AppPublishedState?,
        target: AnyObject?
    ) -> NSMenuItem {
        let parent = NSMenuItem(title: "Period", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Period")
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
                target: target
            )
            item.representedObject = period.rawValue
            item.state = state?.selectedPeriod == period ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private static func displayMetricMenuItem(
        state: AppPublishedState?,
        target: AnyObject?
    ) -> NSMenuItem {
        let parent = NSMenuItem(title: "Menu Bar Shows", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Menu Bar Shows")
        for (metric, title) in [(DisplayMetric.tokens, "Tokens"), (.apiValue, "API Value")] {
            let item = actionItem(
                title,
                action: NSSelectorFromString("selectDisplayMetric:"),
                target: target
            )
            item.representedObject = metric.rawValue
            item.state = state?.selectedDisplayMetric == metric ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private static func actionItem(
        _ title: String,
        action: Selector,
        target: AnyObject?,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        return item
    }

    private static func healthTitle(_ health: SourceHealth?, name: String) -> String {
        guard let health else { return "\(name): Unavailable" }
        switch health {
        case .notGranted:
            return "\(name): Access required"
        case let .indexing(fileCount):
            return "\(name): Ready, \(fileCount) logs"
        case let .healthy(fileCount, _):
            return "\(name): \(fileCount) logs"
        case let .warning(message):
            return "\(name): ⚠ \(message)"
        }
    }
}

@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel?
    private let startupError: String?
    private var stateObservation: AnyCancellable?
    private weak var updatedItem: NSMenuItem?

    init(model: AppModel) {
        self.model = model
        startupError = nil
        super.init()
        stateObservation = model.$state
            .dropFirst()
            .sink { [weak self] state in self?.rebuildMenu(state: state) }
        rebuildMenu(state: model.state)
    }

    init(startupError: Error) {
        model = nil
        self.startupError = "Startup paused: \(String(describing: startupError))"
        super.init()
        rebuildMenu(state: nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let updatedItem else { return }
        let relative: String
        if let lastUpdated = model?.state.lastUpdated {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            relative = formatter.localizedString(for: lastUpdated, relativeTo: Date())
        } else {
            relative = "never"
        }
        updatedItem.title = "Updated \(relative) · Local only"
    }

    var renderedMenu: NSMenu? { statusItem.menu }
    var renderedStatusTitle: String? { statusItem.button?.title }

    private func rebuildMenu(state: AppPublishedState?) {
        let built = NativeMenuBuilder.makeMenu(
            state: state,
            startupError: startupError,
            target: self
        )
        built.menu.delegate = self
        statusItem.button?.title = built.statusTitle
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
