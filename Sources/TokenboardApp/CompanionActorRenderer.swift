import SwiftUI

/// Thin executor over CompanionActorFigure: places each inhabitant on screen
/// — camera offset, culling, pixel snapping — then hands the anatomy to the
/// primitive renderer. All figure math lives in the pure builder.
@MainActor
enum CompanionActorRenderer {
    static func draw(
        actor: CompanionActor,
        motion: CompanionBackgroundMotion,
        artPixel: CGFloat,
        effectScale: CGFloat,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard actor.opacity > 0.01, size.height > 0 else { return }
        var height = max(3, actor.height * effectScale)
        // Inhabitants stand in the world, so they travel with its camera.
        var ground = CGPoint(
            x: actor.x * size.width + motion.offsetX,
            y: actor.y * size.height - actor.lift * effectScale + motion.offsetY
        )
        guard ground.x > -height * 2, ground.x < size.width + height * 2 else { return }
        if actor.snapsToPixelGrid {
            height = max(artPixel * 2, (height / artPixel).rounded() * artPixel)
            ground = CGPoint(
                x: (ground.x / artPixel).rounded() * artPixel,
                y: (ground.y / artPixel).rounded() * artPixel
            )
        }
        if let sprite = actor.sprite,
           let image = CompanionAssetImageStore.image(resource: sprite.resource) {
            let frames = max(1, sprite.frameCount)
            let cellAspect = CompanionAssetImageStore.aspectRatio(resource: sprite.resource)
                / Double(frames)
            let width = max(1, height * cellAspect)
            let cell = CGRect(
                x: ground.x - width / 2,
                y: ground.y - height,
                width: width,
                height: height
            )
            let index = min(max(actor.spriteFrame ?? 0, 0), frames - 1)
            let sourceFacing: Double = sprite.facesRight ? 1 : -1

            context.drawLayer { layer in
                layer.clip(to: Path(cell))
                if actor.facing != sourceFacing {
                    layer.translateBy(x: ground.x, y: ground.y)
                    layer.scaleBy(x: -1, y: 1)
                    layer.translateBy(x: -ground.x, y: -ground.y)
                }
                let strip = CGRect(
                    x: cell.minX - CGFloat(index) * width,
                    y: cell.minY,
                    width: width * CGFloat(frames),
                    height: height
                )
                layer.draw(layer.resolvedPlate(image), in: strip)
            }
        } else {
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
