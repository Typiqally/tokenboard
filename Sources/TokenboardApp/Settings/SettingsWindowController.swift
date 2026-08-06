import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let launchAtLoginFactory: @MainActor () -> LaunchAtLoginController
    private var launchAtLogin: LaunchAtLoginController?
    private var hostingController: NSHostingController<SettingsView>?

    var isSettingsViewLoaded: Bool { hostingController != nil }
    var currentLaunchAtLoginEnabled: Bool? { launchAtLogin?.isEnabled }

    init(
        model: AppModel,
        launchAtLoginFactory: @escaping @MainActor () -> LaunchAtLoginController = {
            LaunchAtLoginController()
        }
    ) {
        self.model = model
        self.launchAtLoginFactory = launchAtLoginFactory
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func showWindow(_ sender: Any?) {
        if hostingController == nil {
            loadSettingsWindow()
        } else {
            launchAtLogin?.refreshStatus()
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
        let launchAtLogin = launchAtLoginFactory()
        launchAtLogin.refreshStatus()
        self.launchAtLogin = launchAtLogin
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
        window?.contentView = nil
        hostingController = nil
        launchAtLogin = nil
        window = nil
    }
}
