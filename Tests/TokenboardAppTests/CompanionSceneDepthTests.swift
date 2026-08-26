import CoreGraphics
import XCTest
@testable import TokenboardApp

/// As someone looking into a companion world, I want its inhabitants to pass
/// behind and in front of scene subjects according to their ground position,
/// so they feel present in the place instead of pasted over the finished art.
final class CompanionSceneDepthTests: XCTestCase {
    func testSubjectsAndActorsShareOneFarToNearPainterOrder() {
        let placements = [
            placement(id: "near-subject", groundY: 0.95),
            placement(id: "far-subject", groundY: 0.70)
        ]
        let actors = [
            actor(y: 0.80),
            actor(y: 0.97)
        ]

        XCTAssertEqual(
            CompanionSceneDepth.painterOrder(placements: placements, actors: actors),
            [
                .placement(index: 1),
                .actor(index: 0),
                .placement(index: 0),
                .actor(index: 1)
            ]
        )
    }

    func testAnActorOnTheSameGroundLinePaintsInFrontOfTheSubject() {
        XCTAssertEqual(
            CompanionSceneDepth.painterOrder(
                placements: [placement(id: "subject", groundY: 0.90)],
                actors: [actor(y: 0.90)]
            ),
            [.placement(index: 0), .actor(index: 0)]
        )
    }

    func testAPerchedBirdPaintsOnItsPerchInsteadOfBehindIt() {
        XCTAssertEqual(
            CompanionSceneDepth.painterOrder(
                placements: [placement(id: "tree", groundY: 0.82)],
                actors: [actor(y: 0.24, pose: .perched, body: .flier)]
            ),
            [.placement(index: 0), .actor(index: 0)]
        )
    }

    private func placement(id: String, groundY: Double) -> CompanionScenePlacement {
        CompanionScenePlacement(
            layer: CompanionSceneLayer(
                id: id,
                resource: "test.png",
                relativeHeight: 0.4,
                horizontalPosition: 0.5,
                bottomOffset: 1 - groundY,
                castsGroundShadow: false,
                role: .tree
            ),
            index: 0,
            rect: CGRect(x: 0, y: 0, width: 20, height: groundY * 100),
            windows: []
        )
    }

    private func actor(
        y: Double,
        pose: CompanionActorPose = .walking,
        body: CompanionActorBody = .quadruped
    ) -> CompanionActor {
        CompanionActor(
            x: 0.5,
            y: y,
            height: 8,
            facing: 1,
            stride: 0,
            speed: 0,
            lift: 0,
            pose: pose,
            body: body,
            sprite: nil,
            spriteFrame: nil,
            tint: CompanionSceneTint(1, 1, 1),
            accent: CompanionSceneTint(1, 1, 1),
            opacity: 1,
            snapsToPixelGrid: false,
            drawsAttention: false
        )
    }
}
