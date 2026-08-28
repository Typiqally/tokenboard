import SwiftUI

/// Thin executor over CompanionActorFigure: places each inhabitant on screen
/// — camera offset, culling, pixel snapping — then hands the anatomy to the
/// primitive renderer. All figure math lives in the pure builder.
@MainActor
enum CompanionActorRenderer {
    static func draw(
        actors: [CompanionActor],
        motion: CompanionBackgroundMotion,
        artPixel: CGFloat,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard !actors.isEmpty, size.height > 0 else { return }
        let scale = size.height / TokenboardSurfaceMetrics.companionSceneHeight
        for actor in actors where actor.opacity > 0.01 {
            var height = max(3, actor.height * scale)
            // Inhabitants stand in the world, so they travel with its camera.
            var ground = CGPoint(
                x: actor.x * size.width + motion.offsetX,
                y: actor.y * size.height - actor.lift * scale + motion.offsetY
            )
            guard ground.x > -height * 2, ground.x < size.width + height * 2 else { continue }
            if actor.snapsToPixelGrid {
                height = max(artPixel * 2, (height / artPixel).rounded() * artPixel)
                ground = CGPoint(
                    x: (ground.x / artPixel).rounded() * artPixel,
                    y: (ground.y / artPixel).rounded() * artPixel
                )
            }
            CompanionPrimitiveRenderer.draw(
                CompanionActorFigure.primitives(
                    for: actor,
                    at: ground,
                    height: height,
                    artPixel: artPixel
                ),
                in: &context
            )
        }
    }
}
