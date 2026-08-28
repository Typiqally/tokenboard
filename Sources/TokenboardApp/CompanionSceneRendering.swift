import CoreGraphics
import SwiftUI

/// The one drawing vocabulary the procedural figures and particles compile
/// to. Geometry builders are pure — CompanionActor in, primitives out — so
/// anatomy and shape math is testable without an ImageRenderer; only
/// CompanionPrimitiveRenderer touches a GraphicsContext.
struct CompanionRenderPrimitive: Equatable, Sendable {
    enum Shape: Equatable, Sendable {
        case rect(CGRect)
        /// A rect in pivot-relative coordinates, rotated about the pivot —
        /// a leaf mid-turn, a working arm mid-stroke.
        case rotatedRect(CGRect, pivot: CGPoint, radians: Double)
        case ellipse(CGRect)
        case polygon([CGPoint])
        case strokedPolyline([CGPoint], lineWidth: CGFloat)
    }

    enum Style: Equatable, Sendable {
        case flat
        /// Solid at the center fading to clear at the shape's edge — soft
        /// shadows and motes.
        case radialFade
        /// The same fade drawn additively — embers, sparks, anything lit.
        case additiveRadialFade
    }

    let shape: Shape
    let style: Style
    let tint: CompanionSceneTint
    let opacity: Double

    init(
        shape: Shape,
        style: Style = .flat,
        tint: CompanionSceneTint,
        opacity: Double
    ) {
        self.shape = shape
        self.style = style
        self.tint = tint
        self.opacity = opacity
    }
}

extension CompanionSceneTint {
    /// The tint as a SwiftUI colour, in the sRGB space every plate is baked in.
    func color(opacity: Double) -> Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}

/// Executes primitives into a canvas. The one place shape becomes pixels.
@MainActor
enum CompanionPrimitiveRenderer {
    static func draw(
        _ primitives: [CompanionRenderPrimitive],
        in context: inout GraphicsContext
    ) {
        for primitive in primitives {
            draw(primitive, in: &context)
        }
    }

    private static func draw(
        _ primitive: CompanionRenderPrimitive,
        in context: inout GraphicsContext
    ) {
        switch primitive.shape {
        case let .rect(rect):
            fill(Path(rect), bounds: rect, as: primitive, in: &context)
        case let .rotatedRect(rect, pivot, radians):
            context.drawLayer { layer in
                layer.translateBy(x: pivot.x, y: pivot.y)
                layer.rotate(by: .radians(radians))
                layer.fill(
                    Path(rect),
                    with: .color(primitive.tint.color(opacity: primitive.opacity))
                )
            }
        case let .ellipse(rect):
            fill(Path(ellipseIn: rect), bounds: rect, as: primitive, in: &context)
        case let .polygon(points):
            guard let first = points.first else { return }
            var path = Path()
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
            fill(path, bounds: path.boundingRect, as: primitive, in: &context)
        case let .strokedPolyline(points, lineWidth):
            guard let first = points.first else { return }
            var path = Path()
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            context.stroke(
                path,
                with: .color(primitive.tint.color(opacity: primitive.opacity)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
        }
    }

    private static func fill(
        _ path: Path,
        bounds: CGRect,
        as primitive: CompanionRenderPrimitive,
        in context: inout GraphicsContext
    ) {
        switch primitive.style {
        case .flat:
            context.fill(
                path,
                with: .color(primitive.tint.color(opacity: primitive.opacity))
            )
        case .radialFade:
            context.fill(path, with: radialFade(of: primitive, bounds: bounds))
        case .additiveRadialFade:
            context.drawLayer { layer in
                layer.blendMode = .plusLighter
                layer.fill(path, with: radialFade(of: primitive, bounds: bounds))
            }
        }
    }

    private static func radialFade(
        of primitive: CompanionRenderPrimitive,
        bounds: CGRect
    ) -> GraphicsContext.Shading {
        .radialGradient(
            Gradient(colors: [
                primitive.tint.color(opacity: primitive.opacity),
                primitive.tint.color(opacity: 0)
            ]),
            center: CGPoint(x: bounds.midX, y: bounds.midY),
            startRadius: 0,
            endRadius: max(0.5, bounds.width / 2)
        )
    }
}
