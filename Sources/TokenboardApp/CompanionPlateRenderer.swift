import AppKit
import SwiftUI

/// Draws the background plate, moved by whatever camera its world runs.
@MainActor
enum CompanionPlateRenderer {
    static func draw(
        background asset: CompanionSceneAsset,
        motion: CompanionBackgroundMotion,
        plateRect: CGRect,
        in context: inout GraphicsContext
    ) {
        guard let image = CompanionAssetImageStore.image(
            resource: asset.backgroundResource
        ) else { return }
        var rect = plateRect
        if motion.scale != 1 {
            let width = rect.width * motion.scale
            let height = rect.height * motion.scale
            rect = CGRect(
                x: rect.midX - width / 2,
                y: rect.maxY - height,
                width: width,
                height: height
            )
        }
        rect = rect.offsetBy(dx: motion.offsetX, dy: motion.offsetY)

        context.drawLayer { layer in
            if motion.brightness != 0 {
                layer.addFilter(.brightness(motion.brightness))
            }
            layer.draw(layer.resolvedPlate(image), in: rect)
        }
    }
}
