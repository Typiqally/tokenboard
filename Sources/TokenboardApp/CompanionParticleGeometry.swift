import CoreGraphics
import Foundation

/// The shape math of every particle: pure from a CompanionParticle to one
/// primitive. Shape is art direction, not decoration — the pixel worlds emit
/// hard squares, the photographic worlds soft motes — so this mapping is the
/// vocabulary the tests hold each world to.
enum CompanionParticleGeometry {
    static func primitive(
        for particle: CompanionParticle,
        at point: CGPoint,
        extent: CGFloat
    ) -> CompanionRenderPrimitive {
        switch particle.shape {
        case .mote:
            CompanionRenderPrimitive(
                shape: .ellipse(CGRect(
                    x: point.x - extent / 2,
                    y: point.y - extent / 2,
                    width: extent,
                    height: extent
                )),
                style: .radialFade,
                tint: particle.tint,
                opacity: particle.opacity
            )
        case .pixel:
            CompanionRenderPrimitive(
                shape: .rect(CGRect(
                    x: point.x - extent / 2,
                    y: point.y - extent / 2,
                    width: extent,
                    height: extent
                )),
                tint: particle.tint,
                opacity: particle.opacity
            )
        case .leaf:
            CompanionRenderPrimitive(
                shape: .rotatedRect(
                    CGRect(
                        x: -extent / 2,
                        y: -extent / 3,
                        width: extent,
                        height: extent * 0.66
                    ),
                    pivot: point,
                    radians: particle.rotation * .pi / 180
                ),
                tint: particle.tint,
                opacity: particle.opacity
            )
        case .ember:
            CompanionRenderPrimitive(
                shape: .ellipse(CGRect(
                    x: point.x - extent,
                    y: point.y - extent,
                    width: extent * 2,
                    height: extent * 2
                )),
                style: .additiveRadialFade,
                tint: particle.tint,
                opacity: particle.opacity
            )
        case .streak:
            // Hard-edged: a pixel town's vehicles are not rounded.
            CompanionRenderPrimitive(
                shape: .rect(CGRect(
                    x: point.x - extent * 0.7,
                    y: point.y - extent * 0.25,
                    width: extent * 1.4,
                    height: max(1, extent * 0.5)
                )),
                tint: particle.tint,
                opacity: particle.opacity
            )
        case .chevron:
            // A wingbeat: the V closes and opens on its own short cycle.
            chevron(for: particle, at: point, extent: extent)
        }
    }

    private static func chevron(
        for particle: CompanionParticle,
        at point: CGPoint,
        extent: CGFloat
    ) -> CompanionRenderPrimitive {
        let beat = 0.35 + 0.65 * abs(sin(.pi * particle.phase))
        return CompanionRenderPrimitive(
            shape: .strokedPolyline(
                [
                    CGPoint(x: point.x - extent, y: point.y),
                    CGPoint(x: point.x, y: point.y + extent * 0.62 * beat),
                    CGPoint(x: point.x + extent, y: point.y)
                ],
                lineWidth: max(0.8, extent * 0.28)
            ),
            tint: particle.tint,
            opacity: particle.opacity
        )
    }
}
