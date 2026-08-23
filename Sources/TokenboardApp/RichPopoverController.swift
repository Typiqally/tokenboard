import AppKit
import Combine
import SwiftUI

@MainActor
final class GlobalMouseDownMonitor {
    typealias Installer = (
        NSEvent.EventTypeMask,
        @escaping () -> Void
    ) -> Any?

    private static let mouseDownMask: NSEvent.EventTypeMask = [
        .leftMouseDown,
        .rightMouseDown,
    ]

    private let install: Installer
    private let remove: (Any) -> Void
    private var token: Any?

    init(
        install: @escaping Installer = { mask, click in
            NSEvent.addGlobalMonitorForEvents(matching: mask) { _ in click() }
        },
        remove: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) }
    ) {
        self.install = install
        self.remove = remove
    }

    func start(click: @escaping () -> Void) {
        guard token == nil else { return }
        token = install(Self.mouseDownMask, click)
    }

    func stop() {
        guard let token else { return }
        remove(token)
        self.token = nil
    }
}

@MainActor
final class PopoverClickAwayDismissal {
    private let monitor: GlobalMouseDownMonitor
    private let dismiss: () -> Void

    init(monitor: GlobalMouseDownMonitor, dismiss: @escaping () -> Void) {
        self.monitor = monitor
        self.dismiss = dismiss
    }

    func popoverDidShow() {
        monitor.start(click: dismiss)
    }

    func popoverDidClose() {
        monitor.stop()
    }
}

@MainActor
final class RichPopoverController: NSObject, NSPopoverDelegate {
    private static let statusButtonActionMask: NSEvent.EventTypeMask = .leftMouseDown

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model: AppModel?
    private let activateApplication: () -> Void
    private var stateObservation: AnyCancellable?
    private var calendarObservations: Set<AnyCancellable> = []
    private var milestoneAcknowledgementTask: Task<Void, Never>?
    private lazy var clickAwayDismissal = PopoverClickAwayDismissal(
        monitor: GlobalMouseDownMonitor(),
        dismiss: { [weak self] in self?.popover.performClose(nil) }
    )

    var renderedPopoverAnimates: Bool { popover.animates }
    var renderedPopoverSize: NSSize { popover.contentSize }
    var renderedPopoverBehavior: NSPopover.Behavior { popover.behavior }
    var renderedStatusImage: NSImage? { statusItem.button?.image }
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
            self?.popover.contentSize = TokenboardSurfaceMetrics.popoverSize(
                companionEnabled: state.companion.isVisible
            )
            self?.updateStatus(for: state)
        }
        observeCalendarChanges()
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
        popover.contentSize = TokenboardSurfaceMetrics.popoverSize(
            companionEnabled: model?.state.companion.isVisible == true
        )
        popover.contentViewController = NSHostingController(rootView: rootView)
    }

    func popoverDidShow(_ notification: Notification) {
        clickAwayDismissal.popoverDidShow()
        scheduleMilestoneAcknowledgement()
    }

    func popoverDidClose(_ notification: Notification) {
        clickAwayDismissal.popoverDidClose()
        milestoneAcknowledgementTask?.cancel()
        milestoneAcknowledgementTask = nil
    }

    private func updateStatus(for state: AppPublishedState) {
        let presentation = RichPopoverPresentation.make(
            state: state,
            startupError: nil,
            relativeTo: Date()
        )
        if let systemImageName = presentation.statusSystemImageName {
            updateStatus(
                title: presentation.statusTitle,
                image: NSImage(
                    systemSymbolName: systemImageName,
                    accessibilityDescription: presentation.statusAccessibilityLabel
                ),
                accessibilityLabel: presentation.statusAccessibilityLabel
            )
            return
        }

        let companion = CompanionPresentation.make(
            state: state.companion,
            date: Date(),
            calendar: .current
        )
        let image: NSImage? = companion.flatMap { companion -> NSImage? in
            guard state.companion.showInMenuBar else { return nil }
            return CompanionMenuIconRenderer.image(
                theme: companion.theme,
                variant: companion.variant,
                stage: companion.stage
            )
        }
        let accessibilityLabel: String = companion.flatMap { companion -> String? in
            state.companion.showInMenuBar
                ? "\(presentation.statusAccessibilityLabel). \(companion.accessibilityLabel)"
                : nil
        } ?? presentation.statusAccessibilityLabel
        updateStatus(
            title: presentation.statusTitle,
            image: image,
            accessibilityLabel: accessibilityLabel
        )
    }

    private func updateStatus(
        title: String,
        systemImageName: String?,
        accessibilityLabel: String
    ) {
        let image = systemImageName.flatMap {
            NSImage(
                systemSymbolName: $0,
                accessibilityDescription: accessibilityLabel
            )
        }
        updateStatus(title: title, image: image, accessibilityLabel: accessibilityLabel)
    }

    private func updateStatus(
        title: String,
        image: NSImage?,
        accessibilityLabel: String
    ) {
        guard let button = statusItem.button else { return }
        button.title = title
        button.setAccessibilityLabel(accessibilityLabel)
        image?.isTemplate = true
        button.image = image
        button.imagePosition = image == nil ? .noImage : (title.isEmpty ? .imageOnly : .imageLeading)
    }

    private func observeCalendarChanges() {
        let center = NotificationCenter.default
        center.publisher(for: .NSCalendarDayChanged)
            .merge(with: center.publisher(for: .NSSystemTimeZoneDidChange))
            .sink { [weak self] _ in
                guard let self, let model = self.model else { return }
                self.updateStatus(for: model.state)
            }
            .store(in: &calendarObservations)
    }

    private func scheduleMilestoneAcknowledgement() {
        milestoneAcknowledgementTask?.cancel()
        guard let model,
              model.companionState.isVisible,
              model.companionState.progress?.hasUnacknowledgedMilestone == true else { return }
        milestoneAcknowledgementTask = Task { @MainActor [weak self, weak model] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, self?.popover.isShown == true else { return }
            model?.acknowledgeCompanionMilestone()
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
