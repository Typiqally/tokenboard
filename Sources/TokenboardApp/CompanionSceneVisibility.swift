import AppKit
import Combine
import SwiftUI

/// Whether the surface a companion scene lives on is genuinely on screen.
///
/// A presented popover or an open Settings window is not enough: a window can
/// be fully covered, miniaturized, or hidden with the app while its views stay
/// alive. Scenes read this to keep a menu-bar app from animating into a
/// surface nobody can see.
enum CompanionSceneVisibilityPolicy {
    static func isOnScreen(
        hasWindow: Bool,
        windowIsVisible: Bool,
        isMiniaturized: Bool,
        occlusionIsVisible: Bool,
        applicationIsHidden: Bool
    ) -> Bool {
        // Before the view is attached to a window there is nothing to judge;
        // the caller's own presentation flag still gates the scene.
        guard hasWindow else { return true }
        return windowIsVisible
            && !isMiniaturized
            && occlusionIsVisible
            && !applicationIsHidden
    }
}

@MainActor
final class CompanionSceneVisibilityModel: ObservableObject {
    @Published private(set) var isOnScreen = true

    private weak var window: NSWindow?
    private var observations: Set<AnyCancellable> = []
    private let center: NotificationCenter

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    func attach(to window: NSWindow?) {
        guard window !== self.window else {
            refresh()
            return
        }
        observations = []
        self.window = window
        guard let window else {
            refresh()
            return
        }

        let windowEvents: [Notification.Name] = [
            .init(NSWindow.didChangeOcclusionStateNotification.rawValue),
            .init(NSWindow.didMiniaturizeNotification.rawValue),
            .init(NSWindow.didDeminiaturizeNotification.rawValue)
        ]
        let applicationEvents: [Notification.Name] = [
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification
        ]
        for name in windowEvents {
            observe(center.publisher(for: name, object: window))
        }
        for name in applicationEvents {
            observe(center.publisher(for: name))
        }
        refresh()
    }

    private func observe(_ publisher: NotificationCenter.Publisher) {
        publisher
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            .store(in: &observations)
    }

    func refresh() {
        let resolved = CompanionSceneVisibilityPolicy.isOnScreen(
            hasWindow: window != nil,
            windowIsVisible: window?.isVisible ?? false,
            isMiniaturized: window?.isMiniaturized ?? false,
            occlusionIsVisible: window?.occlusionState.contains(.visible) ?? false,
            applicationIsHidden: NSApplication.shared.isHidden
        )
        guard resolved != isOnScreen else { return }
        isOnScreen = resolved
    }
}

private struct CompanionSceneOnScreenKey: EnvironmentKey {
    /// Surfaces that never opt in behave exactly as before.
    static let defaultValue = true
}

extension EnvironmentValues {
    var companionSceneOnScreen: Bool {
        get { self[CompanionSceneOnScreenKey.self] }
        set { self[CompanionSceneOnScreenKey.self] = newValue }
    }
}

extension View {
    /// Publishes whether this subtree's window is on screen, so companion
    /// scenes inside it can stop drawing when it is not.
    func tracksCompanionSceneVisibility() -> some View {
        modifier(CompanionSceneVisibilityModifier())
    }
}

private struct CompanionSceneVisibilityModifier: ViewModifier {
    @StateObject private var model = CompanionSceneVisibilityModel()

    func body(content: Content) -> some View {
        content
            .environment(\.companionSceneOnScreen, model.isOnScreen)
            .background(CompanionWindowProbe { model.attach(to: $0) })
    }
}

/// Reports the AppKit window a SwiftUI subtree is hosted in.
private struct CompanionWindowProbe: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        ProbeView(onResolve: onResolve)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ProbeView)?.onResolve = onResolve
        // Resolving during a SwiftUI update pass would publish visibility
        // from inside that pass, so the answer always lands a turn later.
        let window = nsView.window
        let onResolve = onResolve
        DispatchQueue.main.async { onResolve(window) }
    }

    private final class ProbeView: NSView {
        var onResolve: (NSWindow?) -> Void

        init(onResolve: @escaping (NSWindow?) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            let onResolve = self.onResolve
            DispatchQueue.main.async { onResolve(window) }
        }
    }
}
