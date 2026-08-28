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
            draw(actors: frame.actors, motion: frame.background, in: &context, size: size)
            draw(bands: frame.bands, in: &context, size: size)
            draw(glows: frame.glows, in: &context, size: size)
            draw(particles: frame.particles, in: &context, size: size)
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

    // MARK: Inhabitants

    /// The scene's own people and animals. Nothing here is a sprite: each is
    /// built from the same handful of rectangles the worlds are drawn in, so
    /// a village can be populated without another frame of artwork.
    private func draw(
        actors: [CompanionActor],
        motion: CompanionBackgroundMotion,
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
                let grid = composition.artPixel
                height = max(grid * 2, (height / grid).rounded() * grid)
                ground = CGPoint(
                    x: (ground.x / grid).rounded() * grid,
                    y: (ground.y / grid).rounded() * grid
                )
            }
            switch actor.body {
            case .biped:
                drawContactShadow(for: actor, at: ground, height: height, in: &context)
                drawBiped(actor, at: ground, height: height, in: &context)
            case .quadruped:
                drawContactShadow(for: actor, at: ground, height: height, in: &context)
                drawQuadruped(actor, at: ground, height: height, in: &context)
            case .flier:
                drawFlier(actor, at: ground, height: height, in: &context)
            }
        }
    }

    /// A soft patch under anything standing on the ground. Without it a
    /// procedural figure floats over the plate instead of standing on it.
    private func drawContactShadow(
        for actor: CompanionActor,
        at ground: CGPoint,
        height: CGFloat,
        in context: inout GraphicsContext
    ) {
        let width = height * (actor.body == .quadruped ? 1.10 : 0.66)
        if actor.snapsToPixelGrid {
            // A pixel world's shadow is a row of darker pixels, never a blur.
            let thickness = max(1, composition.artPixel)
            context.fill(
                Path(CGRect(
                    x: ground.x - width / 2,
                    y: ground.y - thickness,
                    width: width,
                    height: thickness
                )),
                with: .color(.black.opacity(0.22 * actor.opacity))
            )
            return
        }
        let rect = CGRect(
            x: ground.x - width / 2,
            y: ground.y - height * 0.09,
            width: width,
            height: max(1, height * 0.18)
        )
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [
                    .black.opacity(0.38 * actor.opacity),
                    .black.opacity(0)
                ]),
                center: CGPoint(x: rect.midX, y: rect.midY),
                startRadius: 0,
                endRadius: max(1, width / 2)
            )
        )
    }

    private func drawBiped(
        _ actor: CompanionActor,
        at ground: CGPoint,
        height: CGFloat,
        in context: inout GraphicsContext
    ) {
        let clothes = color(actor.tint, opacity: actor.opacity)
        let skin = color(actor.accent, opacity: actor.opacity)
        let facing = CGFloat(actor.facing)
        let cycle = CGFloat(sin(2 * .pi * actor.stride))
        let pace = CGFloat(min(1, max(0, actor.speed)))
        let swing = height * 0.15 * pace * cycle
        // The whole body rises a little on each step and settles between them.
        let feet = ground.y - height * 0.03 * pace * abs(cycle)

        // Deliberately stocky: at eight points tall a realistic silhouette
        // reads as a stick, and a large head is what makes a shape this small
        // read as a person at all.
        let legHeight = height * 0.30
        let torsoHeight = height * 0.38
        let headSize = height * 0.32
        let torsoWidth = height * 0.42
        let limb = max(1, height * 0.17)

        for offset in [-height * 0.19, height * 0.02] {
            let lead: CGFloat = offset < 0 ? 1 : -1
            context.fill(
                Path(CGRect(
                    x: ground.x + offset + swing * 0.5 * lead,
                    y: feet - legHeight,
                    width: limb,
                    height: legHeight
                )),
                with: .color(clothes)
            )
        }

        let shoulder = feet - legHeight - torsoHeight
        context.fill(
            Path(CGRect(
                x: ground.x - torsoWidth / 2,
                y: shoulder,
                width: torsoWidth,
                height: torsoHeight
            )),
            with: .color(clothes)
        )

        switch actor.pose {
        case let .working(swing: stroke):
            drawWorkingArm(
                actor,
                at: CGPoint(x: ground.x + facing * torsoWidth * 0.35, y: shoulder + height * 0.05),
                height: height,
                stroke: stroke,
                in: &context
            )
        case .carrying:
            // The load rides on the shoulder all the way home.
            let load = height * 0.26
            context.fill(
                Path(CGRect(
                    x: ground.x - facing * torsoWidth * 0.55 - load / 2,
                    y: shoulder - load * 0.55,
                    width: load,
                    height: load
                )),
                with: .color(skin)
            )
            fallthrough
        default:
            context.fill(
                Path(CGRect(
                    x: ground.x + facing * torsoWidth * 0.42 - limb * 0.4 - swing * 0.4,
                    y: shoulder + height * 0.03,
                    width: max(1, limb * 0.8),
                    height: torsoHeight * 0.80
                )),
                with: .color(skin)
            )
        }

        let head = CGRect(
            x: ground.x - headSize / 2 + facing * height * 0.02,
            y: feet - height,
            width: headSize,
            height: headSize
        )
        context.fill(Path(head), with: .color(skin))
        // Hair reads as the difference between a person and a pale square.
        context.fill(
            Path(CGRect(
                x: head.minX,
                y: head.minY,
                width: head.width,
                height: max(1, head.height * 0.38)
            )),
            with: .color(clothes)
        )
    }

    /// A tool arm on a work site: up, then down through the stroke, then a
    /// beat of rest before the next swing.
    private func drawWorkingArm(
        _ actor: CompanionActor,
        at shoulder: CGPoint,
        height: CGFloat,
        stroke: Double,
        in context: inout GraphicsContext
    ) {
        let raised = stroke < 0.55
            ? sin(.pi * stroke / 0.55)
            : 0
        let angle = Double(actor.facing) * (1.35 - 1.9 * raised)
        context.drawLayer { layer in
            layer.translateBy(x: shoulder.x, y: shoulder.y)
            layer.rotate(by: .radians(angle))
            layer.fill(
                Path(CGRect(
                    x: -max(1, height * 0.07) / 2,
                    y: 0,
                    width: max(1, height * 0.07),
                    height: height * 0.52
                )),
                with: .color(color(actor.accent, opacity: actor.opacity))
            )
        }
    }

    private func drawQuadruped(
        _ actor: CompanionActor,
        at ground: CGPoint,
        height: CGFloat,
        in context: inout GraphicsContext
    ) {
        let coat = color(actor.tint, opacity: actor.opacity)
        let mark = color(actor.accent, opacity: actor.opacity)
        let facing = CGFloat(actor.facing)
        let cycle = CGFloat(sin(2 * .pi * actor.stride))
        let pace = CGFloat(min(1, max(0, actor.speed)))
        let swing = height * 0.16 * pace * cycle

        let legHeight = height * 0.44
        let bodyHeight = height * 0.46
        let bodyWidth = height * 1.05
        let feet = ground.y
        let limb = max(1, height * 0.13)

        for (index, offset) in [-0.36, -0.16, 0.16, 0.36].enumerated() {
            let lead: CGFloat = index % 2 == 0 ? 1 : -1
            context.fill(
                Path(CGRect(
                    x: ground.x + height * CGFloat(offset) + swing * 0.5 * lead,
                    y: feet - legHeight,
                    width: limb,
                    height: legHeight
                )),
                with: .color(coat)
            )
        }

        let back = feet - legHeight - bodyHeight
        context.fill(
            Path(CGRect(
                x: ground.x - bodyWidth / 2,
                y: back,
                width: bodyWidth,
                height: bodyHeight
            )),
            with: .color(coat)
        )

        let headSize = height * 0.40
        context.fill(
            Path(CGRect(
                x: ground.x + facing * (bodyWidth / 2 - headSize * 0.35) - headSize / 2,
                y: feet - height,
                width: headSize,
                height: headSize
            )),
            with: .color(coat)
        )
        // A single marked pixel — a beak, a snout, an ear tuft — is all it
        // takes for a shape this small to read as a specific animal.
        let markSize = max(1, height * 0.16)
        context.fill(
            Path(CGRect(
                x: ground.x + facing * (bodyWidth / 2 + headSize * 0.12) - markSize / 2,
                y: feet - height + headSize * 0.45,
                width: markSize,
                height: markSize
            )),
            with: .color(mark)
        )
    }

    private func drawFlier(
        _ actor: CompanionActor,
        at point: CGPoint,
        height: CGFloat,
        in context: inout GraphicsContext
    ) {
        let plumage = color(actor.tint, opacity: actor.opacity)
        let mark = color(actor.accent, opacity: actor.opacity)
        let facing = CGFloat(actor.facing)
        let grounded = actor.pose == .perched || actor.pose == .idle
        let bodyWidth = height * (grounded ? 0.90 : 1.05)
        let bodyHeight = height * (grounded ? 0.62 : 0.42)
        let center = CGPoint(
            x: point.x,
            y: grounded ? point.y - bodyHeight * 0.62 : point.y - height * 0.35
        )

        if grounded {
            // Legs, so a landed bird stands on the branch instead of hovering
            // over it, and a tail so its silhouette still points somewhere.
            let leg = max(1, height * 0.12)
            context.fill(
                Path(CGRect(
                    x: point.x - leg / 2,
                    y: point.y - height * 0.30,
                    width: leg,
                    height: height * 0.30
                )),
                with: .color(mark)
            )
            context.fill(
                Path(CGRect(
                    x: center.x - facing * bodyWidth * 0.85,
                    y: center.y - max(1, height * 0.12) / 2,
                    width: bodyWidth * 0.5,
                    height: max(1, height * 0.16)
                )),
                with: .color(plumage)
            )
        } else {
            let beat = CGFloat(sin(2 * .pi * actor.stride))
            let span = height * 1.05
            let lift = height * 0.55 * beat
            var wings = Path()
            wings.move(to: CGPoint(x: center.x - span * 0.15, y: center.y))
            wings.addLine(to: CGPoint(x: center.x - span, y: center.y - lift))
            wings.addLine(to: CGPoint(x: center.x - span * 0.35, y: center.y + bodyHeight * 0.30))
            wings.closeSubpath()
            wings.move(to: CGPoint(x: center.x + span * 0.15, y: center.y))
            wings.addLine(to: CGPoint(x: center.x + span, y: center.y - lift))
            wings.addLine(to: CGPoint(x: center.x + span * 0.35, y: center.y + bodyHeight * 0.30))
            wings.closeSubpath()
            context.fill(wings, with: .color(plumage))
        }

        context.fill(
            Path(ellipseIn: CGRect(
                x: center.x - bodyWidth / 2,
                y: center.y - bodyHeight / 2,
                width: bodyWidth,
                height: bodyHeight
            )),
            with: .color(plumage)
        )

        let headSize = height * 0.38
        let head = CGPoint(
            x: center.x + facing * bodyWidth * 0.36,
            y: center.y - bodyHeight * (grounded ? 0.55 : 0.30)
        )
        context.fill(
            Path(ellipseIn: CGRect(
                x: head.x - headSize / 2,
                y: head.y - headSize / 2,
                width: headSize,
                height: headSize
            )),
            with: .color(plumage)
        )
        let beak = max(1, height * 0.14)
        context.fill(
            Path(CGRect(
                x: head.x + facing * headSize * 0.34 - beak / 2,
                y: head.y - beak / 2,
                width: beak,
                height: beak
            )),
            with: .color(mark)
        )
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
        particles: [CompanionParticle],
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
                let grid = composition.artPixel
                extent = max(grid, (extent / grid).rounded() * grid)
                point = CGPoint(
                    x: (point.x / grid).rounded() * grid,
                    y: (point.y / grid).rounded() * grid
                )
            }
            draw(particle: particle, at: point, extent: extent, in: &context)
        }
    }

    private func draw(
        particle: CompanionParticle,
        at point: CGPoint,
        extent: CGFloat,
        in context: inout GraphicsContext
    ) {
        let fill = color(particle.tint, opacity: particle.opacity)
        switch particle.shape {
        case .mote:
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: point.x - extent / 2,
                        y: point.y - extent / 2,
                        width: extent,
                        height: extent
                    )
                ),
                with: .radialGradient(
                    Gradient(colors: [fill, color(particle.tint, opacity: 0)]),
                    center: point,
                    startRadius: 0,
                    endRadius: max(0.5, extent / 2)
                )
            )
        case .pixel:
            context.fill(
                Path(
                    CGRect(
                        x: point.x - extent / 2,
                        y: point.y - extent / 2,
                        width: extent,
                        height: extent
                    )
                ),
                with: .color(fill)
            )
        case .leaf:
            context.drawLayer { layer in
                layer.translateBy(x: point.x, y: point.y)
                layer.rotate(by: .degrees(particle.rotation))
                layer.fill(
                    Path(
                        CGRect(
                            x: -extent / 2,
                            y: -extent / 3,
                            width: extent,
                            height: extent * 0.66
                        )
                    ),
                    with: .color(fill)
                )
            }
        case .ember:
            context.drawLayer { layer in
                layer.blendMode = .plusLighter
                layer.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: point.x - extent,
                            y: point.y - extent,
                            width: extent * 2,
                            height: extent * 2
                        )
                    ),
                    with: .radialGradient(
                        Gradient(colors: [fill, color(particle.tint, opacity: 0)]),
                        center: point,
                        startRadius: 0,
                        endRadius: max(0.5, extent)
                    )
                )
            }
        case .streak:
            // Hard-edged: a pixel town's vehicles are not rounded.
            context.fill(
                Path(
                    CGRect(
                        x: point.x - extent * 0.7,
                        y: point.y - extent * 0.25,
                        width: extent * 1.4,
                        height: max(1, extent * 0.5)
                    )
                ),
                with: .color(fill)
            )
        case .chevron:
            // A wingbeat: the V closes and opens on its own short cycle.
            let beat = 0.35 + 0.65 * abs(sin(.pi * particle.phase))
            var path = Path()
            path.move(to: CGPoint(x: point.x - extent, y: point.y))
            path.addLine(to: CGPoint(x: point.x, y: point.y + extent * 0.62 * beat))
            path.addLine(to: CGPoint(x: point.x + extent, y: point.y))
            context.stroke(
                path,
                with: .color(fill),
                style: StrokeStyle(lineWidth: max(0.8, extent * 0.28), lineCap: .round)
            )
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
