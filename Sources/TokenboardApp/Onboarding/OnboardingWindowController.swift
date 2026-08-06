import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController {
    init(model: AppModel) {
        let hostingController = NSHostingController(rootView: OnboardingView(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Set Up Tokenboard"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 410))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        showWindow(nil)
        window?.orderFrontRegardless()
    }

    func update(isRequired: Bool) {
        if isRequired {
            present()
        } else {
            window?.orderOut(nil)
        }
    }
}
