import Foundation
import XCTest
@testable import TokenboardApp

/// As someone who likes Frostpunk, I want New London to grow around the
/// generator, so today's tokens tell one coherent twelve-stage survival story.
final class FrostpunkCompanionTests: XCTestCase {
    private let seed: UInt64 = 0xF205_7F00

    func testFrostpunkIsACompleteTwelveStageJourney() throws {
        XCTAssertTrue(CompanionTheme.allCases.contains(.frostpunk))
        XCTAssertEqual(CompanionTheme.frostpunk.title, "Frostpunk")
        XCTAssertEqual(
            CompanionCatalog.variants(for: .frostpunk),
            [CompanionVariant(id: "new-london", title: "New London")]
        )

        let expectedTitles = [
            "The Generator", "First tents", "Coal lifeline",
            "Workshop district", "Beacon raised", "Steam hubs",
            "Hothouse harvest", "Industrial city", "Automaton age",
            "Storm watch", "The Great Storm", "New London endures"
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let date = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 26))
        )
        let state = CompanionState(theme: .frostpunk, showInMenuBar: false, seed: seed)

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

    func testEveryFrostpunkStageHasThreeBakedOfficialScenes() throws {
        let variant = try XCTUnwrap(CompanionCatalog.variants(for: .frostpunk).first)
        for stage in 0..<CompanionJourney.thresholds.count {
            for scenery in 0..<3 {
                let scene = try XCTUnwrap(
                    CompanionAssetCatalog.scene(
                        theme: .frostpunk,
                        variant: variant,
                        stage: stage,
                        scenery: scenery,
                        fraction: 0.5,
                        seed: seed
                    )
                )
                XCTAssertTrue(scene.backgroundResource.hasPrefix("Frostpunk/scenes/"))
                XCTAssertTrue(scene.layers.isEmpty)
            }
        }
        XCTAssertEqual(CompanionAssetCatalog.sceneryCount(for: .frostpunk), 3)
    }

    func testFrostpunkHasItsOwnFrozenIndustryAndNativeWorkers() {
        XCTAssertEqual(CompanionMotionSignature.of(.frostpunk), .frozenIndustry)
        XCTAssertGreaterThanOrEqual(CompanionActorSpriteCatalog.frostpunkCitizens.count, 3)
        XCTAssertTrue(
            CompanionActorSpriteCatalog.frostpunkCitizens.allSatisfy {
                $0.resource.hasPrefix("Frostpunk/actors/")
            }
        )

        let first = plan(stage: 0)
        let storm = plan(stage: 10)
        let summit = plan(stage: 11)
        XCTAssertTrue(first.effectKeys.contains("frostpunk/workers"))
        XCTAssertTrue(first.effectKeys.contains("frostpunk/generator-smoke"))
        XCTAssertTrue(storm.effectKeys.contains("frostpunk/snow"))
        XCTAssertTrue(summit.effectKeys.contains("frostpunk/generator-glow"))

        let firstPopulation = first.actors.reduce(0) { $0 + $1.count }
        let finalPopulation = summit.actors.reduce(0) { $0 + $1.count }
        XCTAssertGreaterThan(finalPopulation, firstPopulation)
        XCTAssertLessThanOrEqual(finalPopulation, 9)
        XCTAssertTrue(
            summit.actors.flatMap(\.sprites).allSatisfy {
                $0.resource.hasPrefix("Frostpunk/actors/")
            },
            "Frostpunk must never fall back to generated people"
        )
    }

    func testFrostpunkWorkersResolveAtMultipleDepths() {
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
            theme: .frostpunk,
            stage: stage,
            seed: seed,
            layers: []
        )
    }
}
