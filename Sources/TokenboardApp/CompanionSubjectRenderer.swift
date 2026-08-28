import AppKit
import SwiftUI

/// Draws one subject sprite: its ground shadow, its transformed artwork, and
/// the windows whose light differs from what the plate baked.
@MainActor
enum CompanionSubjectRenderer {
    static func draw(
        placement: CompanionScenePlacement,
        plan: CompanionScenePlan,
        attention: CompanionAttention,
        time: Double,
        isMoving: Bool,
        sceneSize: CGSize,
        in context: inout GraphicsContext
    ) {
        let motion = CompanionSceneMotion.subject(
            signature: plan.signature,
            role: placement.layer.role,
            index: placement.index,
            horizontalPosition: placement.layer.horizontalPosition,
            relativeHeight: placement.layer.relativeHeight,
            seed: plan.seed,
            elapsed: time,
            isMoving: isMoving,
            attention: attention
        )
        let anchor = CGPoint(x: placement.rect.midX, y: placement.rect.maxY)

        if placement.layer.castsGroundShadow {
            drawGroundShadow(
                for: placement,
                motion: motion,
                anchor: anchor,
                sceneSize: sceneSize,
                in: &context
            )
        }

        guard let image = CompanionAssetImageStore.image(
            resource: placement.layer.resource
        ) else { return }

        context.drawLayer { layer in
            layer.translateBy(x: motion.offsetX, y: motion.offsetY)
            layer.translateBy(x: anchor.x, y: anchor.y)
            if motion.rotation != 0 {
                layer.rotate(by: .degrees(motion.rotation))
            }
            layer.scaleBy(
                x: motion.scaleX * (motion.flipped ? -1 : 1),
                y: motion.scaleY
            )
            layer.translateBy(x: -anchor.x, y: -anchor.y)
            if motion.brightness != 0 {
                layer.addFilter(.brightness(motion.brightness))
            }
            layer.addFilter(.shadow(color: .black.opacity(0.18), radius: 1.5, x: 0, y: 1))
            layer.draw(layer.resolvedPlate(image), in: placement.rect)
            drawWindows(for: placement, time: time, in: &layer)
        }
    }

    private static func drawGroundShadow(
        for placement: CompanionScenePlacement,
        motion: CompanionSubjectMotion,
        anchor: CGPoint,
        sceneSize: CGSize,
        in context: inout GraphicsContext
    ) {
        let width = min(placement.rect.width * 0.86, sceneSize.height * 0.9)
        let height = max(4, placement.rect.height * 0.075)
        let scaled = width * motion.shadowScale
        let rect = CGRect(
            x: anchor.x - scaled / 2 + motion.offsetX,
            y: anchor.y - height * 0.3 - height / 2,
            width: scaled,
            height: height
        )
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [
                    .black.opacity(0.30 * motion.shadowOpacity),
                    .black.opacity(0)
                ]),
                center: CGPoint(x: rect.midX, y: rect.midY),
                startRadius: 0,
                endRadius: max(1, scaled / 2)
            )
        )
    }

    /// Repaints only the windows whose light differs from the baked artwork,
    /// so a night town keeps the silhouette it was drawn with while rooms
    /// still switch on and off.
    private static func drawWindows(
        for placement: CompanionScenePlacement,
        time: Double,
        in context: inout GraphicsContext
    ) {
        guard !placement.windows.isEmpty else { return }
        for (index, cell) in placement.windows.enumerated() {
            let schedule = placement.windowSchedules[index]
            guard schedule != .baked else { continue }
            let lit = schedule.isLit(bakedLit: cell.bakedLit, at: time)
            guard lit != cell.bakedLit else { continue }
            let rect = CGRect(
                x: placement.rect.minX + placement.rect.width * cell.x,
                y: placement.rect.minY + placement.rect.height * cell.y,
                width: placement.rect.width * cell.width,
                height: placement.rect.height * cell.height
            )
            context.fill(
                Path(rect),
                with: .color(
                    (lit ? CompanionWindowLighting.litTint
                         : CompanionWindowLighting.darkTint)
                        .color(opacity: 1)
                )
            )
        }
    }
}
