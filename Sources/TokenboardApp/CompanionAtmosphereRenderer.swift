import SwiftUI

/// Draws the weather over a scene: sweeping shadow bands, breathing glows,
/// and the whole-scene colour wash.
@MainActor
enum CompanionAtmosphereRenderer {
    static func draw(
        bands: [CompanionShadowBand],
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard !bands.isEmpty, size.height > 0 else { return }
        for band in bands {
            let width = band.width * size.width
            let rect = CGRect(
                x: band.centerX * size.width - width / 2,
                y: band.top * size.height,
                width: width,
                height: max(1, (band.bottom - band.top) * size.height)
            )
            guard rect.maxX > 0, rect.minX < size.width else { continue }
            let shear = -band.skew * size.width / size.height
            context.drawLayer { layer in
                layer.concatenate(
                    CGAffineTransform(
                        a: 1, b: 0,
                        c: shear, d: 1,
                        tx: band.skew * size.width / 2, ty: 0
                    )
                )
                layer.fill(
                    Path(rect),
                    with: .linearGradient(
                        Gradient(colors: [
                            band.tint.color(opacity: 0),
                            band.tint.color(opacity: band.opacity),
                            band.tint.color(opacity: band.opacity),
                            band.tint.color(opacity: 0)
                        ]),
                        startPoint: CGPoint(x: rect.minX, y: 0),
                        endPoint: CGPoint(x: rect.maxX, y: 0)
                    )
                )
            }
        }
    }

    static func draw(
        glows: [CompanionGlow],
        effectScale: CGFloat,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard !glows.isEmpty else { return }
        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            for glow in glows {
                let radius = max(1, glow.radius * effectScale)
                let center = CGPoint(x: glow.x * size.width, y: glow.y * size.height)
                layer.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: center.x - radius,
                            y: center.y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )
                    ),
                    with: .radialGradient(
                        Gradient(colors: [
                            glow.tint.color(opacity: glow.opacity),
                            glow.tint.color(opacity: 0)
                        ]),
                        center: center,
                        startRadius: 0,
                        endRadius: radius
                    )
                )
            }
        }
    }

    static func draw(
        wash: CompanionWash,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard wash.opacity > 0.001 else { return }
        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            layer.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(wash.tint.color(opacity: wash.opacity))
            )
        }
    }
}
