import AppKit
import Combine
import SwiftUI

@MainActor
final class RichPopoverController: NSObject, NSPopoverDelegate {
    private static let statusButtonActionMask: NSEvent.EventTypeMask = .leftMouseDown

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model: AppModel?
    private let activateApplication: () -> Void
    private var stateObservation: AnyCancellable?

    var renderedPopoverAnimates: Bool { popover.animates }
    var renderedPopoverSize: NSSize { popover.contentSize }
    var renderedPopoverBehavior: NSPopover.Behavior { popover.behavior }
    var renderedStatusButtonActionMask: NSEvent.EventTypeMask {
        Self.statusButtonActionMask
    }

    init(
        model: AppModel,
        activateApplication: @escaping () -> Void = { NSApplication.shared.activate() }
    ) {
        self.model = model
        self.activateApplication = activateApplication
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusButton()
        configurePopover(
            rootView: AnyView(RichUsagePopoverView(
                model: model,
                dismiss: { [weak self] in self?.popover.performClose(nil) }
            ))
        )
        stateObservation = model.$state.sink { [weak self] state in
            self?.updateStatus(for: state)
        }
        updateStatus(for: model.state)
    }

    init(startupError: Error) {
        model = nil
        activateApplication = { NSApplication.shared.activate() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusButton()
        let message = "Startup paused: \(String(describing: startupError))"
        configurePopover(rootView: AnyView(StartupFailurePopoverView(message: message)))
        updateStatus(
            title: "Unavailable",
            systemImageName: "exclamationmark.triangle",
            accessibilityLabel: "Tokenboard is unavailable"
        )
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: Self.statusButtonActionMask)
    }

    private func configurePopover(rootView: AnyView) {
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentSize = TokenboardSurfaceMetrics.popoverSize
        popover.contentViewController = NSHostingController(rootView: rootView)
    }

    private func updateStatus(for state: AppPublishedState) {
        let presentation = RichPopoverPresentation.make(
            state: state,
            startupError: nil,
            relativeTo: Date()
        )
        updateStatus(
            title: presentation.statusTitle,
            systemImageName: presentation.statusSystemImageName,
            accessibilityLabel: presentation.statusAccessibilityLabel
        )
    }

    private func updateStatus(
        title: String,
        systemImageName: String?,
        accessibilityLabel: String
    ) {
        guard let button = statusItem.button else { return }
        button.title = title
        button.setAccessibilityLabel(accessibilityLabel)
        if let systemImageName {
            let image = NSImage(
                systemSymbolName: systemImageName,
                accessibilityDescription: accessibilityLabel
            )
            image?.isTemplate = true
            button.image = image
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        } else {
            button.image = nil
            button.imagePosition = .noImage
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            activateApplication()
            popover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY
            )
        }
    }
}
