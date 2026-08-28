import AppKit
import SwiftUI

/// Internal rather than private so a scene can be rendered at an exact moment
/// — deterministically, off the clock — for tests and for visual review.
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
            draw(background: asset, frame: frame, in: &context, size: size)
            for placement in composition.placements {
                draw(placement: placement, frame: frame, time: time, in: &context)
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
            draw(bands: frame.bands, in: &context, size: size)
            draw(glows: frame.glows, in: &context, size: size)
            CompanionParticleRenderer.draw(
                particles: frame.particles,
                artPixel: composition.artPixel,
                in: &context,
                size: size
            )
            draw(wash: frame.wash, in: &context, size: size)
        }
        // A canvas does not clip itself, and the background plate is drawn
        // wider and taller than the band on purpose.
        .clipped()
    }

    // MARK: Background

    private func draw(
        background asset: CompanionSceneAsset,
        frame: CompanionSceneFrame,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard let image = CompanionAssetImageStore.image(
            resource: asset.backgroundResource
        ) else { return }
        var rect = composition.backgroundRect
        let motion = frame.background
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
            layer.draw(resolved(image, in: layer), in: rect)
        }
    }

    // MARK: Subjects

    private func draw(
        placement: CompanionScenePlacement,
        frame: CompanionSceneFrame,
        time: Double,
        in context: inout GraphicsContext
    ) {
        let plan = composition.plan
        let motion = CompanionSceneMotion.subject(
            signature: plan.signature,
            role: placement.layer.role,
            index: placement.index,
            horizontalPosition: placement.layer.horizontalPosition,
            relativeHeight: placement.layer.relativeHeight,
            seed: plan.seed,
            elapsed: time,
            isMoving: isMoving,
            attention: frame.attention
        )
        let anchor = CGPoint(x: placement.rect.midX, y: placement.rect.maxY)

        if placement.layer.castsGroundShadow {
            drawGroundShadow(for: placement, motion: motion, anchor: anchor, in: &context)
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
            layer.draw(resolved(image, in: layer), in: placement.rect)
            drawWindows(for: placement, plan: plan, time: time, in: &layer)
        }
    }

    private func drawGroundShadow(
        for placement: CompanionScenePlacement,
        motion: CompanionSubjectMotion,
        anchor: CGPoint,
        in context: inout GraphicsContext
    ) {
        let width = min(placement.rect.width * 0.86, composition.size.height * 0.9)
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
    private func drawWindows(
        for placement: CompanionScenePlacement,
        plan: CompanionScenePlan,
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
                    color(
                        lit ? CompanionWindowLighting.litTint
                            : CompanionWindowLighting.darkTint,
                        opacity: 1
                    )
                )
            )
        }
    }

    // MARK: Atmosphere

    private func draw(
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
                            color(band.tint, opacity: 0),
                            color(band.tint, opacity: band.opacity),
                            color(band.tint, opacity: band.opacity),
                            color(band.tint, opacity: 0)
                        ]),
                        startPoint: CGPoint(x: rect.minX, y: 0),
                        endPoint: CGPoint(x: rect.maxX, y: 0)
                    )
                )
            }
        }
    }

    private func draw(
        glows: [CompanionGlow],
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard !glows.isEmpty else { return }
        let scale = size.height / TokenboardSurfaceMetrics.companionSceneHeight
        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            for glow in glows {
                let radius = max(1, glow.radius * scale)
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
                            color(glow.tint, opacity: glow.opacity),
                            color(glow.tint, opacity: 0)
                        ]),
                        center: center,
                        startRadius: 0,
                        endRadius: radius
                    )
                )
            }
        }
    }

    private func draw(
        wash: CompanionWash,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard wash.opacity > 0.001 else { return }
        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            layer.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(color(wash.tint, opacity: wash.opacity))
            )
        }
    }

    // MARK: Helpers

    private func resolved(
        _ image: NSImage,
        in context: GraphicsContext
    ) -> GraphicsContext.ResolvedImage {
        context.resolve(
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        )
    }

    private func color(_ tint: CompanionSceneTint, opacity: Double) -> Color {
        Color(
            .sRGB,
            red: tint.red,
            green: tint.green,
            blue: tint.blue,
            opacity: opacity
        )
    }
}
