import CoreGraphics
import Foundation

/// The procedural anatomy of a scene's inhabitants: pure math from a
/// CompanionActor to primitives in painting order. Nothing here is a sprite —
/// each figure is built from the same handful of rectangles the worlds are
/// drawn in, so a village can be populated without another frame of artwork.
enum CompanionActorFigure {
    private static let black = CompanionSceneTint(0, 0, 0)

    /// Everything to draw for one actor standing at `ground` at `height`.
    /// `artPixel` sizes the hard shadow row in pixel-art worlds.
    static func primitives(
        for actor: CompanionActor,
        at ground: CGPoint,
        height: CGFloat,
        artPixel: CGFloat
    ) -> [CompanionRenderPrimitive] {
        switch actor.body {
        case .biped:
            contactShadow(for: actor, at: ground, height: height, artPixel: artPixel)
                + biped(actor, at: ground, height: height)
        case .quadruped:
            contactShadow(for: actor, at: ground, height: height, artPixel: artPixel)
                + quadruped(actor, at: ground, height: height)
        case .flier:
            flier(actor, at: ground, height: height)
        }
    }

    /// A soft patch under anything standing on the ground. Without it a
    /// procedural figure floats over the plate instead of standing on it.
    static func contactShadow(
        for actor: CompanionActor,
        at ground: CGPoint,
        height: CGFloat,
        artPixel: CGFloat
    ) -> [CompanionRenderPrimitive] {
        let width = height * (actor.body == .quadruped ? 1.10 : 0.66)
        if actor.snapsToPixelGrid {
            // A pixel world's shadow is a row of darker pixels, never a blur.
            let thickness = max(1, artPixel)
            return [CompanionRenderPrimitive(
                shape: .rect(CGRect(
                    x: ground.x - width / 2,
                    y: ground.y - thickness,
                    width: width,
                    height: thickness
                )),
                tint: black,
                opacity: 0.22 * actor.opacity
            )]
        }
        return [CompanionRenderPrimitive(
            shape: .ellipse(CGRect(
                x: ground.x - width / 2,
                y: ground.y - height * 0.09,
                width: width,
                height: max(1, height * 0.18)
            )),
            style: .radialFade,
            tint: black,
            opacity: 0.38 * actor.opacity
        )]
    }

    private static func biped(
        _ actor: CompanionActor,
        at ground: CGPoint,
        height: CGFloat
    ) -> [CompanionRenderPrimitive] {
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

        var primitives: [CompanionRenderPrimitive] = []
        func clothes(_ shape: CompanionRenderPrimitive.Shape) -> CompanionRenderPrimitive {
            CompanionRenderPrimitive(shape: shape, tint: actor.tint, opacity: actor.opacity)
        }
        func skin(_ shape: CompanionRenderPrimitive.Shape) -> CompanionRenderPrimitive {
            CompanionRenderPrimitive(shape: shape, tint: actor.accent, opacity: actor.opacity)
        }

        for offset in [-height * 0.19, height * 0.02] {
            let lead: CGFloat = offset < 0 ? 1 : -1
            primitives.append(clothes(.rect(CGRect(
                x: ground.x + offset + swing * 0.5 * lead,
                y: feet - legHeight,
                width: limb,
                height: legHeight
            ))))
        }

        let shoulder = feet - legHeight - torsoHeight
        primitives.append(clothes(.rect(CGRect(
            x: ground.x - torsoWidth / 2,
            y: shoulder,
            width: torsoWidth,
            height: torsoHeight
        ))))

        let swingingArm = skin(.rect(CGRect(
            x: ground.x + facing * torsoWidth * 0.42 - limb * 0.4 - swing * 0.4,
            y: shoulder + height * 0.03,
            width: max(1, limb * 0.8),
            height: torsoHeight * 0.80
        )))
        switch actor.pose {
        case let .working(swing: stroke):
            primitives.append(workingArm(
                actor,
                at: CGPoint(
                    x: ground.x + facing * torsoWidth * 0.35,
                    y: shoulder + height * 0.05
                ),
                height: height,
                stroke: stroke
            ))
        case .carrying:
            // The load rides on the shoulder all the way home.
            let load = height * 0.26
            primitives.append(skin(.rect(CGRect(
                x: ground.x - facing * torsoWidth * 0.55 - load / 2,
                y: shoulder - load * 0.55,
                width: load,
                height: load
            ))))
            primitives.append(swingingArm)
        default:
            primitives.append(swingingArm)
        }

        let head = CGRect(
            x: ground.x - headSize / 2 + facing * height * 0.02,
            y: feet - height,
            width: headSize,
            height: headSize
        )
        primitives.append(skin(.rect(head)))
        // Hair reads as the difference between a person and a pale square.
        primitives.append(clothes(.rect(CGRect(
            x: head.minX,
            y: head.minY,
            width: head.width,
            height: max(1, head.height * 0.38)
        ))))
        return primitives
    }

    /// A tool arm on a work site: up, then down through the stroke, then a
    /// beat of rest before the next swing.
    private static func workingArm(
        _ actor: CompanionActor,
        at shoulder: CGPoint,
        height: CGFloat,
        stroke: Double
    ) -> CompanionRenderPrimitive {
        let raised = stroke < 0.55
            ? sin(.pi * stroke / 0.55)
            : 0
        let angle = Double(actor.facing) * (1.35 - 1.9 * raised)
        return CompanionRenderPrimitive(
            shape: .rotatedRect(
                CGRect(
                    x: -max(1, height * 0.07) / 2,
                    y: 0,
                    width: max(1, height * 0.07),
                    height: height * 0.52
                ),
                pivot: shoulder,
                radians: angle
            ),
            tint: actor.accent,
            opacity: actor.opacity
        )
    }

    private static func quadruped(
        _ actor: CompanionActor,
        at ground: CGPoint,
        height: CGFloat
    ) -> [CompanionRenderPrimitive] {
        let facing = CGFloat(actor.facing)
        let cycle = CGFloat(sin(2 * .pi * actor.stride))
        let pace = CGFloat(min(1, max(0, actor.speed)))
        let swing = height * 0.16 * pace * cycle

        let legHeight = height * 0.44
        let bodyHeight = height * 0.46
        let bodyWidth = height * 1.05
        let feet = ground.y
        let limb = max(1, height * 0.13)

        var primitives: [CompanionRenderPrimitive] = []
        func coat(_ shape: CompanionRenderPrimitive.Shape) -> CompanionRenderPrimitive {
            CompanionRenderPrimitive(shape: shape, tint: actor.tint, opacity: actor.opacity)
        }

        for (index, offset) in [-0.36, -0.16, 0.16, 0.36].enumerated() {
            let lead: CGFloat = index % 2 == 0 ? 1 : -1
            primitives.append(coat(.rect(CGRect(
                x: ground.x + height * CGFloat(offset) + swing * 0.5 * lead,
                y: feet - legHeight,
                width: limb,
                height: legHeight
            ))))
        }

        let back = feet - legHeight - bodyHeight
        primitives.append(coat(.rect(CGRect(
            x: ground.x - bodyWidth / 2,
            y: back,
            width: bodyWidth,
            height: bodyHeight
        ))))

        let headSize = height * 0.40
        primitives.append(coat(.rect(CGRect(
            x: ground.x + facing * (bodyWidth / 2 - headSize * 0.35) - headSize / 2,
            y: feet - height,
            width: headSize,
            height: headSize
        ))))
        // A single marked pixel — a beak, a snout, an ear tuft — is all it
        // takes for a shape this small to read as a specific animal.
        let markSize = max(1, height * 0.16)
        primitives.append(CompanionRenderPrimitive(
            shape: .rect(CGRect(
                x: ground.x + facing * (bodyWidth / 2 + headSize * 0.12) - markSize / 2,
                y: feet - height + headSize * 0.45,
                width: markSize,
                height: markSize
            )),
            tint: actor.accent,
            opacity: actor.opacity
        ))
        return primitives
    }

    private static func flier(
        _ actor: CompanionActor,
        at point: CGPoint,
        height: CGFloat
    ) -> [CompanionRenderPrimitive] {
        let facing = CGFloat(actor.facing)
        let grounded = actor.pose == .perched || actor.pose == .idle
        let bodyWidth = height * (grounded ? 0.90 : 1.05)
        let bodyHeight = height * (grounded ? 0.62 : 0.42)
        let center = CGPoint(
            x: point.x,
            y: grounded ? point.y - bodyHeight * 0.62 : point.y - height * 0.35
        )

        var primitives: [CompanionRenderPrimitive] = []
        func plumage(_ shape: CompanionRenderPrimitive.Shape) -> CompanionRenderPrimitive {
            CompanionRenderPrimitive(shape: shape, tint: actor.tint, opacity: actor.opacity)
        }
        func mark(_ shape: CompanionRenderPrimitive.Shape) -> CompanionRenderPrimitive {
            CompanionRenderPrimitive(shape: shape, tint: actor.accent, opacity: actor.opacity)
        }

        if grounded {
            // Legs, so a landed bird stands on the branch instead of hovering
            // over it, and a tail so its silhouette still points somewhere.
            let leg = max(1, height * 0.12)
            primitives.append(mark(.rect(CGRect(
                x: point.x - leg / 2,
                y: point.y - height * 0.30,
                width: leg,
                height: height * 0.30
            ))))
            primitives.append(plumage(.rect(CGRect(
                x: center.x - facing * bodyWidth * 0.85,
                y: center.y - max(1, height * 0.12) / 2,
                width: bodyWidth * 0.5,
                height: max(1, height * 0.16)
            ))))
        } else {
            let beat = CGFloat(sin(2 * .pi * actor.stride))
            let span = height * 1.05
            let lift = height * 0.55 * beat
            primitives.append(plumage(.polygon([
                CGPoint(x: center.x - span * 0.15, y: center.y),
                CGPoint(x: center.x - span, y: center.y - lift),
                CGPoint(x: center.x - span * 0.35, y: center.y + bodyHeight * 0.30)
            ])))
            primitives.append(plumage(.polygon([
                CGPoint(x: center.x + span * 0.15, y: center.y),
                CGPoint(x: center.x + span, y: center.y - lift),
                CGPoint(x: center.x + span * 0.35, y: center.y + bodyHeight * 0.30)
            ])))
        }

        primitives.append(plumage(.ellipse(CGRect(
            x: center.x - bodyWidth / 2,
            y: center.y - bodyHeight / 2,
            width: bodyWidth,
            height: bodyHeight
        ))))

        let headSize = height * 0.38
        let head = CGPoint(
            x: center.x + facing * bodyWidth * 0.36,
            y: center.y - bodyHeight * (grounded ? 0.55 : 0.30)
        )
        primitives.append(plumage(.ellipse(CGRect(
            x: head.x - headSize / 2,
            y: head.y - headSize / 2,
            width: headSize,
            height: headSize
        ))))
        let beak = max(1, height * 0.14)
        primitives.append(mark(.rect(CGRect(
            x: head.x + facing * headSize * 0.34 - beak / 2,
            y: head.y - beak / 2,
            width: beak,
            height: beak
        ))))
        return primitives
    }
}
