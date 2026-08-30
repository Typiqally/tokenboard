import SwiftUI

/// Thin executor over CompanionParticleGeometry: places each particle on
/// screen — scale, culling, pixel snapping — then hands its shape to the
/// primitive renderer. All shape math lives in the pure builder.
@MainActor
enum CompanionParticleRenderer {
    static func draw(
        particles: [CompanionParticle],
        artPixel: CGFloat,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard !particles.isEmpty else { return }
        let scale = size.height / TokenboardSurfaceMetrics.companionSceneHeight
        for particle in particles where particle.opacity > 0.004 {
            var point = CGPoint(x: particle.x * size.width, y: particle.y * size.height)
            var extent = max(0.5, particle.size * scale)
            guard point.x > -extent * 3, point.x < size.width + extent * 3,
                  point.y > -extent * 3, point.y < size.height + extent * 3 else { continue }
            if particle.snapsToPixelGrid {
                extent = max(artPixel, (extent / artPixel).rounded() * artPixel)
                point = CGPoint(
                    x: (point.x / artPixel).rounded() * artPixel,
                    y: (point.y / artPixel).rounded() * artPixel
                )
            }
            CompanionPrimitiveRenderer.draw(
                [CompanionParticleGeometry.primitive(for: particle, at: point, extent: extent)],
                in: &context
            )
        }
    }
}
