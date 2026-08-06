import AppKit
import Combine
import TokenboardCore

@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel?
    private let startupError: String?
    private var revisionObservation: AnyCancellable?
    private weak var updatedItem: NSMenuItem?

    init(model: AppModel) {
        self.model = model
        startupError = nil
        super.init()
        revisionObservation = model.$revision
            .dropFirst()
            .sink { [weak self] _ in self?.rebuildMenu() }
        rebuildMenu()
    }

    init(startupError: Error) {
        model = nil
        self.startupError = "Startup paused: \(String(describing: startupError))"
        super.init()
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let updatedItem else { return }
        let relative: String
        if let lastUpdated = model?.lastUpdated {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            relative = formatter.localizedString(for: lastUpdated, relativeTo: Date())
        } else {
            relative = "never"
        }
        updatedItem.title = "Updated \(relative) · Local only"
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        if let presentation = model?.presentation {
            statusItem.button?.title = presentation.statusTitle
            menu.addDisabledItem(presentation.tokenTitle)
            menu.addDisabledItem(presentation.apiValueTitle)
            if let unpricedTitle = presentation.unpricedTitle {
                menu.addDisabledItem(unpricedTitle)
            }
        } else {
            let warning = startupError != nil || model?.sourceHealth.values.contains(where: {
                switch $0 {
                case .notGranted, .warning: return true
                case .indexing, .healthy: return false
                }
            }) == true
            statusItem.button?.title = warning ? "⚠ Unavailable" : "◉ …"
            menu.addDisabledItem("Token total unavailable")
            menu.addDisabledItem("API equivalent unavailable")
        }

        menu.addItem(.separator())
        menu.addItem(periodMenuItem())
        menu.addItem(displayMetricMenuItem())
        menu.addItem(.separator())

        if model != nil {
            menu.addDisabledItem(healthTitle(for: .claudeCode, name: "Claude Code"))
            menu.addDisabledItem(healthTitle(for: .codex, name: "Codex"))
        } else {
            menu.addDisabledItem("Claude Code: \(startupError ?? "Unavailable")")
            menu.addDisabledItem("Codex: \(startupError ?? "Unavailable")")
        }
        let updated = menu.addDisabledItem("Updated never · Local only")
        updatedItem = updated

        menu.addItem(.separator())
        menu.addItem(actionItem("Refresh Now", action: #selector(refresh), keyEquivalent: "r"))

        var pricingTitle = "Pricing"
        if let unpriced = model?.presentation?.unpricedTitle {
            pricingTitle += " ⚠ \(unpriced)"
        }
        menu.addItem(actionItem(pricingTitle, action: #selector(openPricing)))
        menu.addItem(actionItem("Settings", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit Tokenboard", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func periodMenuItem() -> NSMenuItem {
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
            let item = actionItem(title, action: #selector(selectPeriod))
            item.representedObject = period.rawValue
            item.state = model?.selectedPeriod == period ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func displayMetricMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Menu Bar Shows", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Menu Bar Shows")
        for (metric, title) in [(DisplayMetric.tokens, "Tokens"), (.apiValue, "API Value")] {
            let item = actionItem(title, action: #selector(selectDisplayMetric))
            item.representedObject = metric.rawValue
            item.state = model?.selectedDisplayMetric == metric ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func actionItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func healthTitle(for provider: Provider, name: String) -> String {
        guard let health = model?.sourceHealth[provider] else { return "\(name): Unavailable" }
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

    @objc private func refresh() {
        guard let model else { return }
        Task { await model.refresh() }
    }

    @objc private func selectPeriod(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let period = CalendarPeriod(rawValue: rawValue),
              let model else { return }
        Task { await model.select(period: period) }
    }

    @objc private func selectDisplayMetric(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let metric = DisplayMetric(rawValue: rawValue),
              let model else { return }
        Task { await model.select(displayMetric: metric) }
    }

    @objc private func openPricing() { model?.openPricing() }
    @objc private func openSettings() { model?.openSettings() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
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
