import CoreGraphics
import XCTest
@testable import TokenboardApp

/// The inhabitants are procedural anatomy, not sprites. These tests hold the
/// figure math directly — no ImageRenderer — so a change to how a villager is
/// built fails as geometry, not as a subtly different picture.
final class CompanionActorFigureTests: XCTestCase {
    private let ground = CGPoint(x: 100, y: 80)
    private let height: CGFloat = 10

    func testAStandingBipedHoldsItsLegsStillOnItsFeet() {
        let primitives = primitives(for: actor(body: .biped, speed: 0, stride: 0.25))
        let legs = rects(of: primitives, at: 1...2)
        XCTAssertEqual(legs[0].minX, ground.x - height * 0.19)
        XCTAssertEqual(legs[1].minX, ground.x + height * 0.02)
        XCTAssertEqual(legs[0].maxY, ground.y, "no bob while standing")
    }

    func testAWalkingBipedSwingsItsLegsAndRisesOnTheStep() {
        let primitives = primitives(for: actor(body: .biped, speed: 1, stride: 0.25))
        let legs = rects(of: primitives, at: 1...2)
        let swing = height * 0.15
        XCTAssertEqual(legs[0].minX, ground.x - height * 0.19 + swing * 0.5, accuracy: 1e-9)
        XCTAssertEqual(legs[1].minX, ground.x + height * 0.02 - swing * 0.5, accuracy: 1e-9)
        XCTAssertEqual(legs[0].maxY, ground.y - height * 0.03, accuracy: 1e-9, "the body rises on the step")
    }

    func testTheBipedIsShadowLegsTorsoArmHeadAndHair() {
        let primitives = primitives(for: actor(body: .biped))
        XCTAssertEqual(primitives.count, 7)
        XCTAssertEqual(primitives.first?.style, .radialFade, "the shadow paints first")
        let hair = primitives[6]
        let head = rects(of: primitives, at: 5...5)[0]
        XCTAssertEqual(hair.tint, actor(body: .biped).tint, "hair wears the clothes tint")
        if case let .rect(rect) = hair.shape {
            XCTAssertEqual(rect.minY, head.minY, "hair caps the head")
        } else {
            XCTFail("hair is a rect")
        }
    }

    func testAWorkingBipedSwingsOnlyTheToolArm() {
        let primitives = primitives(
            for: actor(body: .biped, pose: .working(swing: 0.2))
        )
        XCTAssertEqual(primitives.count, 7)
        let arms = primitives.filter {
            if case .rotatedRect = $0.shape { return true }
            return false
        }
        XCTAssertEqual(arms.count, 1)
        guard case let .rotatedRect(_, pivot, radians) = arms[0].shape else {
            return XCTFail("the tool arm rotates about the shoulder")
        }
        XCTAssertEqual(pivot.x, ground.x + height * 0.42 * 0.35, accuracy: 1e-9)
        XCTAssertEqual(radians, 1.35 - 1.9 * sin(.pi * 0.2 / 0.55), accuracy: 1e-9)
    }

    func testACarryingBipedShouldersTheLoadBehindIt() {
        let carrying = primitives(for: actor(body: .biped, pose: .carrying))
        let walking = primitives(for: actor(body: .biped))
        XCTAssertEqual(carrying.count, walking.count + 1, "the load is one extra box")
        let load = rects(of: carrying, at: 4...4)[0]
        XCTAssertLessThan(load.midX, ground.x, "the load rides opposite the facing side")
    }

    func testAQuadrupedIsFourLegsABodyAHeadAndOneMark() {
        let primitives = primitives(for: actor(body: .quadruped))
        XCTAssertEqual(primitives.count, 8)
        let mark = primitives[7]
        XCTAssertEqual(mark.tint, actor(body: .quadruped).accent)
        if case let .rect(markRect) = mark.shape {
            XCTAssertGreaterThan(
                markRect.midX,
                ground.x + height * 1.05 / 2,
                "the mark sits out front of the facing side"
            )
        } else {
            XCTFail("the mark is a rect")
        }
    }

    func testAFlierBeatsItsWingsInFlightAndFoldsThemPerched() {
        let flying = primitives(for: actor(body: .flier, pose: .flying, stride: 0.25))
        let wings = flying.filter {
            if case .polygon = $0.shape { return true }
            return false
        }
        XCTAssertEqual(wings.count, 2)
        guard case let .polygon(points) = wings[0].shape else { return }
        let center = ground.y - height * 0.35
        XCTAssertEqual(points[1].y, center - height * 0.55, accuracy: 1e-9, "wingtips follow the beat")

        let perched = primitives(for: actor(body: .flier, pose: .perched))
        XCTAssertTrue(
            perched.allSatisfy {
                if case .polygon = $0.shape { return false }
                return true
            },
            "a perched bird has no open wings"
        )
        XCTAssertNil(
            perched.first { $0.style != .flat },
            "a flier casts no contact shadow"
        )
    }

    func testAPixelWorldShadowIsAHardRowOfPixels() {
        let artPixel: CGFloat = 3
        let snapped = CompanionActorFigure.contactShadow(
            for: actor(body: .biped, snaps: true),
            at: ground,
            height: height,
            artPixel: artPixel
        )
        XCTAssertEqual(snapped.count, 1)
        XCTAssertEqual(snapped[0].style, .flat)
        if case let .rect(rect) = snapped[0].shape {
            XCTAssertEqual(rect.height, artPixel, "one row of art pixels")
        } else {
            XCTFail("a pixel shadow is a rect, never a blur")
        }

        let soft = CompanionActorFigure.contactShadow(
            for: actor(body: .biped),
            at: ground,
            height: height,
            artPixel: 1
        )
        XCTAssertEqual(soft[0].style, .radialFade)
    }

    // MARK: - Helpers

    private func primitives(for actor: CompanionActor) -> [CompanionRenderPrimitive] {
        CompanionActorFigure.primitives(
            for: actor,
            at: ground,
            height: height,
            artPixel: 1
        )
    }

    private func rects(
        of primitives: [CompanionRenderPrimitive],
        at range: ClosedRange<Int>
    ) -> [CGRect] {
        range.compactMap {
            if case let .rect(rect) = primitives[$0].shape { return rect }
            return nil
        }
    }

    private func actor(
        body: CompanionActorBody,
        pose: CompanionActorPose = .walking,
        speed: Double = 1,
        stride: Double = 0.25,
        snaps: Bool = false
    ) -> CompanionActor {
        CompanionActor(
            x: 0.5,
            y: 0.9,
            height: 10,
            facing: 1,
            stride: stride,
            speed: speed,
            lift: 0,
            pose: pose,
            body: body,
            tint: CompanionSceneTint(0.3, 0.4, 0.5),
            accent: CompanionSceneTint(0.8, 0.7, 0.6),
            opacity: 1,
            snapsToPixelGrid: snaps,
            drawsAttention: false
        )
    }
}
