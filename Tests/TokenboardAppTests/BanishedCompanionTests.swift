import Foundation
import XCTest
@testable import TokenboardApp

/// As someone who likes Banished, I want one complete settlement journey,
/// so the companion grows from a first shelter into a town that survives winter.
final class BanishedCompanionTests: XCTestCase {
    private let seed: UInt64 = 0xBA11_15ED

    func testBanishedIsACompleteTwelveStageJourney() throws {
        XCTAssertTrue(CompanionTheme.allCases.contains(.banished))
        XCTAssertEqual(CompanionTheme.banished.title, "Banished")
        XCTAssertEqual(
            CompanionCatalog.variants(for: .banished),
            [CompanionVariant(id: "settlement", title: "Settlement")]
        )

        let expectedTitles = [
            "First shelter", "Gatherer's clearing", "First harvest",
            "Pasture raised", "Roads laid", "River crossing",
            "Trading post", "Market town", "Stone village",
            "First hard winter", "Winter endured", "Thriving township"
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let date = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 26))
        )
        let state = CompanionState(theme: .banished, showInMenuBar: false, seed: seed)

        let titles = try CompanionJourney.thresholds.map { tokens in
            try XCTUnwrap(
                CompanionPresentation.make(
                    state: state,
                    dailyTokenTotal: tokens,
                    date: date,
                    calendar: calendar
                )
            ).stageTitle
        }
        XCTAssertEqual(titles, expectedTitles)
    }

    func testEveryBanishedStageHasThreeBakedOfficialScenes() throws {
        let variant = try XCTUnwrap(CompanionCatalog.variants(for: .banished).first)
        for stage in 0..<CompanionJourney.thresholds.count {
            for scenery in 0..<3 {
                let scene = try XCTUnwrap(
                    CompanionAssetCatalog.scene(
                        theme: .banished,
                        variant: variant,
                        stage: stage,
                        scenery: scenery,
                        fraction: 0.5,
                        seed: seed
                    )
                )
                XCTAssertTrue(scene.backgroundResource.hasPrefix("Banished/scenes/"))
                XCTAssertTrue(scene.layers.isEmpty)
            }
        }
        XCTAssertEqual(CompanionAssetCatalog.sceneryCount(for: .banished), 3)
    }

    func testBanishedHasItsOwnSeasonalLifeAndAuthenticCitizens() throws {
        XCTAssertEqual(CompanionMotionSignature.of(.banished), .seasonalSettlement)
        XCTAssertEqual(CompanionActorSpriteCatalog.banishedCitizens.count, 7)
        XCTAssertTrue(
            CompanionActorSpriteCatalog.banishedCitizens.allSatisfy {
                $0.resource.hasPrefix("Banished/actors/")
            }
        )

        let first = plan(stage: 0)
        let winter = plan(stage: 9)
        let summit = plan(stage: 11)
        XCTAssertTrue(first.effectKeys.contains("banished/laborers"))
        XCTAssertFalse(first.effectKeys.contains("banished/snow"))
        XCTAssertTrue(winter.effectKeys.contains("banished/snow"))
        XCTAssertTrue(summit.effectKeys.contains("banished/chimney-smoke"))

        let firstPopulation = first.actors.reduce(0) { $0 + $1.count }
        let finalPopulation = summit.actors.reduce(0) { $0 + $1.count }
        XCTAssertGreaterThan(finalPopulation, firstPopulation)
        XCTAssertLessThanOrEqual(finalPopulation, 9)
        XCTAssertTrue(
            summit.actors.flatMap(\.sprites).allSatisfy {
                $0.resource.hasPrefix("Banished/actors/")
            },
            "Banished must never fall back to generated people"
        )
    }

    func testBanishedCitizensResolveAtMultipleDepths() {
        let actors = plan(stage: 8).frame(at: 11.5, isMoving: true).actors
        XCTAssertGreaterThan(Set(actors.map { Int(($0.y * 1_000).rounded()) }).count, 1)
        let order = CompanionSceneDepth.painterOrder(placements: [], actors: actors)
        let orderedDepths = order.compactMap { item -> Double? in
            guard case let .actor(index) = item else { return nil }
            return actors[index].y
        }
        XCTAssertEqual(orderedDepths, orderedDepths.sorted())
    }

    private func plan(stage: Int) -> CompanionScenePlan {
        CompanionScenePlan.make(
            theme: .banished,
            stage: stage,
            seed: seed,
            layers: []
        )
    }
}
