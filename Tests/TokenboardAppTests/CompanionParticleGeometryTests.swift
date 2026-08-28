import CoreGraphics
import XCTest
@testable import TokenboardApp

/// Shape is art direction: the pixel worlds emit hard squares, the
/// photographic worlds soft motes, and a bird's V beats its wings. These
/// tests hold each shape's math directly, without an ImageRenderer.
final class CompanionParticleGeometryTests: XCTestCase {
    private let point = CGPoint(x: 50, y: 20)
    private let extent: CGFloat = 4

    func testAMoteIsASoftFadedDot() {
        let primitive = primitive(shape: .mote)
        XCTAssertEqual(primitive.style, .radialFade)
        guard case let .ellipse(rect) = primitive.shape else {
            return XCTFail("a mote is round")
        }
        XCTAssertEqual(rect, CGRect(x: 48, y: 18, width: 4, height: 4))
    }

    func testAPixelIsAHardCenteredSquare() {
        let primitive = primitive(shape: .pixel)
        XCTAssertEqual(primitive.style, .flat)
        guard case let .rect(rect) = primitive.shape else {
            return XCTFail("a pixel is square")
        }
        XCTAssertEqual(rect, CGRect(x: 48, y: 18, width: 4, height: 4))
    }

    func testALeafTurnsAboutItsOwnCenterAsItFalls() {
        let primitive = primitive(shape: .leaf, rotation: 90)
        guard case let .rotatedRect(rect, pivot, radians) = primitive.shape else {
            return XCTFail("a leaf turns")
        }
        XCTAssertEqual(pivot, point)
        XCTAssertEqual(radians, .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(rect.width, extent)
        XCTAssertEqual(rect.height, extent * 0.66)
    }

    func testAnEmberGlowsAdditivelyAtTwiceItsExtent() {
        let primitive = primitive(shape: .ember)
        XCTAssertEqual(primitive.style, .additiveRadialFade)
        guard case let .ellipse(rect) = primitive.shape else {
            return XCTFail("an ember is round")
        }
        XCTAssertEqual(rect.width, extent * 2)
    }

    func testAStreakIsAHardHorizontalBar() {
        let primitive = primitive(shape: .streak)
        XCTAssertEqual(primitive.style, .flat)
        guard case let .rect(rect) = primitive.shape else {
            return XCTFail("a streak is a bar")
        }
        XCTAssertEqual(rect.width, extent * 1.4, accuracy: 1e-9)
        XCTAssertEqual(rect.height, max(1, extent * 0.5), accuracy: 1e-9)
    }

    func testAChevronBeatsItsWingsOnItsOwnCycle() {
        let open = primitive(shape: .chevron, phase: 0)
        let closed = primitive(shape: .chevron, phase: 0.5)
        guard case let .strokedPolyline(openPoints, lineWidth) = open.shape,
              case let .strokedPolyline(closedPoints, _) = closed.shape else {
            return XCTFail("a chevron is a stroked V")
        }
        XCTAssertEqual(openPoints.count, 3)
        XCTAssertEqual(openPoints[0], CGPoint(x: 46, y: 20))
        XCTAssertEqual(openPoints[2], CGPoint(x: 54, y: 20))
        XCTAssertEqual(openPoints[1].y, 20 + extent * 0.62 * 0.35, accuracy: 1e-9)
        XCTAssertEqual(closedPoints[1].y, 20 + extent * 0.62, accuracy: 1e-9, "the V is widest mid-beat")
        XCTAssertEqual(lineWidth, max(0.8, extent * 0.28), accuracy: 1e-9)
    }

    // MARK: - Helpers

    private func primitive(
        shape: CompanionParticleShape,
        phase: Double = 0,
        rotation: Double = 0
    ) -> CompanionRenderPrimitive {
        CompanionParticleGeometry.primitive(
            for: CompanionParticle(
                x: 0.5,
                y: 0.2,
                phase: phase,
                size: 4,
                opacity: 0.8,
                rotation: rotation,
                shape: shape,
                tint: CompanionSceneTint(0.2, 0.3, 0.4),
                snapsToPixelGrid: false
            ),
            at: point,
            extent: extent
        )
    }
}
