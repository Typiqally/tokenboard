import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let launchAtLogin: LaunchAtLoginController
    private var hostingController: NSHostingController<SettingsView>?

    var isSettingsViewLoaded: Bool { hostingController != nil }

    init(model: AppModel, launchAtLogin: LaunchAtLoginController? = nil) {
        self.model = model
        self.launchAtLogin = launchAtLogin ?? LaunchAtLoginController()
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func showWindow(_ sender: Any?) {
        if hostingController == nil {
            loadSettingsWindow()
        }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
        Task { await model.refreshSettings() }
    }

    override func close() {
        window?.close()
        releaseSettingsWindow()
    }

    func windowWillClose(_ notification: Notification) {
        releaseSettingsWindow()
    }

    private func loadSettingsWindow() {
        let hostingController = NSHostingController(
            rootView: SettingsView(model: model, launchAtLogin: launchAtLogin)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tokenboard Settings"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.hostingController = hostingController
        self.window = window
    }

    private func releaseSettingsWindow() {
        guard hostingController != nil || window != nil else { return }
        window?.delegate = nil
        window?.contentViewController = nil
        hostingController = nil
        window = nil
    }
}
