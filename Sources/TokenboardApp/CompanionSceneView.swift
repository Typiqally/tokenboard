import SwiftUI

/// A companion scene, drawn as one canvas so the world's own life — a lit
/// window, a chimney's smoke, a cloud shadow crossing the map — paints in the
/// same order as the artwork it belongs to.
struct CompanionSceneView: View {
    let presentation: CompanionPresentation
    let isAmbientMotionActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionSceneOnScreen) private var sceneOnScreen

    init(
        presentation: CompanionPresentation,
        isAmbientMotionActive: Bool = false
    ) {
        self.presentation = presentation
        self.isAmbientMotionActive = isAmbientMotionActive
    }

    /// Motion runs only when the caller says this scene is presented, the
    /// window it lives in is genuinely on screen, and the system has not asked
    /// for reduced motion.
    private var isMoving: Bool {
        isAmbientMotionActive && sceneOnScreen && !reduceMotion
    }

    var body: some View {
        GeometryReader { proxy in
            // Composed outside the timeline: the scene's artwork, layout, and
            // effect plan depend on the journey, never on the clock.
            let composition = CompanionSceneComposition.make(
                presentation: presentation,
                size: proxy.size
            )
            // A still scene carries no timeline at all, so a companion that
            // is not on screen costs exactly nothing.
            if isMoving {
                TimelineView(
                    .animation(minimumInterval: CompanionSceneMotion.frameInterval)
                ) { context in
                    CompanionSceneCanvas(
                        composition: composition,
                        elapsed: CompanionSceneMotion.elapsed(at: context.date),
                        isMoving: true
                    )
                }
            } else {
                CompanionSceneCanvas(
                    composition: composition,
                    elapsed: 0,
                    isMoving: false
                )
            }
        }
        // Purely decorative. `.clipped()` clips drawing but not hit testing,
        // so without this the oversized fill image would swallow clicks for
        // neighboring controls (for example the settings shelf's None tile).
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}
