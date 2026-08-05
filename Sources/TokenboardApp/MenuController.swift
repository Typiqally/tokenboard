import AppKit

@MainActor
final class MenuController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init() {
        statusItem.button?.title = "◉ —"
        let menu = NSMenu()
        menu.addItem(withTitle: "Tokenboard is starting…", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tokenboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }
}
