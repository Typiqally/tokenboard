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
    private let visibility = RichPopoverVisibility()
    private let model: AppModel?
    private let activateApplication: () -> Void
    private var stateObservation: AnyCancellable?
    private var calendarObservations: Set<AnyCancellable> = []
    private lazy var clickAwayDismissal = PopoverClickAwayDismissal(
        monitor: GlobalMouseDownMonitor(),
        dismiss: { [weak self] in self?.popover.performClose(nil) }
    )

    var renderedPopoverAnimates: Bool { popover.animates }
    var renderedPopoverSize: NSSize { popover.contentSize }
    var renderedSizingOptions: NSHostingSizingOptions? {
        (popover.contentViewController as? NSHostingController<AnyView>)?
            .sizingOptions
    }
    var renderedPopoverBehavior: NSPopover.Behavior { popover.behavior }
    var renderedAmbientMotionActive: Bool { visibility.isPresented }
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
                visibility: visibility,
                dismiss: { [weak self] in self?.popover.performClose(nil) }
            ))
        )
        stateObservation = model.$state.sink { [weak self] state in
            self?.applyPopoverSize(companionEnabled: state.companion.isVisible)
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
        let controller = NSHostingController(rootView: rootView)
        // The SwiftUI view's fixed frame is the popover's single source of
        // truth: publishing it as `preferredContentSize` lets NSPopover keep
        // its window and content view in agreement itself. Managing geometry
        // by hand here raced AppKit's own layout — NSPopover insets its
        // content view within a larger frame view, so forcing the view's
        // frame shifted the whole layout toward the bottom-left.
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
    }

    /// Redundant `contentSize` assignments relayout a shown popover and can
    /// offset its content, so only touch the popover on real changes; the
    /// hosting controller's `preferredContentSize` keeps the window and the
    /// content view in agreement at show time.
    private func applyPopoverSize(companionEnabled: Bool) {
        let size = TokenboardSurfaceMetrics.popoverSize(
            companionEnabled: companionEnabled
        )
        guard popover.contentSize != size else { return }
        popover.contentSize = size
    }

    func popoverDidShow(_ notification: Notification) {
        visibility.isPresented = true
        clickAwayDismissal.popoverDidShow()
    }

    func popoverDidClose(_ notification: Notification) {
        visibility.isPresented = false
        clickAwayDismissal.popoverDidClose()
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

        let currentDate = Date()
        let companion = model?.companionPresentation(for: state, at: currentDate)
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
                Task { @MainActor in
                    await model.refreshForCalendarChange(.current)
                }
            }
            .store(in: &calendarObservations)
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
