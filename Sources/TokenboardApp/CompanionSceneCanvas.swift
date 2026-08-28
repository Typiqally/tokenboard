import SwiftUI

/// Internal rather than private so a scene can be rendered at an exact moment
/// — deterministically, off the clock — for tests and for visual review.
///
/// The canvas itself only sequences the passes: each concern draws through
/// its own renderer, in the same order the world composes itself — plate,
/// subjects, inhabitants, weather, particles, wash.
struct CompanionSceneCanvas: View {
    let composition: CompanionSceneComposition
    let elapsed: Double
    let isMoving: Bool

    var body: some View {
        let plan = composition.plan
        let frame = composition.resolvedPlan.frame(at: elapsed, isMoving: isMoving)
        // A paused scene is composed at its own resting moment, so subjects
        // never freeze mid-hop or mid-gust.
        let time = isMoving
            ? elapsed
            : CompanionSceneMotion.stillElapsed(for: plan.signature)

        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            guard let asset = composition.asset else { return }
            CompanionPlateRenderer.draw(
                background: asset,
                motion: frame.background,
                plateRect: composition.backgroundRect,
                in: &context
            )
            for placement in composition.placements {
                CompanionSubjectRenderer.draw(
                    placement: placement,
                    plan: plan,
                    attention: frame.attention,
                    time: time,
                    isMoving: isMoving,
                    sceneSize: composition.size,
                    in: &context
                )
            }
            // The inhabitants stand in the near foreground of their world, so
            // the weather above them still passes over them.
            CompanionActorRenderer.draw(
                actors: frame.actors,
                motion: frame.background,
                artPixel: composition.artPixel,
                in: &context,
                size: size
            )
            CompanionAtmosphereRenderer.draw(bands: frame.bands, in: &context, size: size)
            CompanionAtmosphereRenderer.draw(glows: frame.glows, in: &context, size: size)
            CompanionParticleRenderer.draw(
                particles: frame.particles,
                artPixel: composition.artPixel,
                in: &context,
                size: size
            )
            CompanionAtmosphereRenderer.draw(wash: frame.wash, in: &context, size: size)
        }
        // A canvas does not clip itself, and the background plate is drawn
        // wider and taller than the band on purpose.
        .clipped()
    }
}
