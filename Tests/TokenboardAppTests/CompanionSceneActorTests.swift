import Foundation
import XCTest
@testable import TokenboardApp

/// A companion world is a place, not a backdrop: somebody lives in it and is
/// busy with something. These tests pin down who lives where, that they only
/// ever move in the way their world moves, and that a paused scene keeps them
/// exactly where the still composed them.
final class CompanionSceneActorTests: XCTestCase {
    private let seed: UInt64 = 0x5EED_C0FF_EE12_3456

    // MARK: - Who lives where

    func testEveryInhabitedWorldGetsAPopulationOfItsOwn() {
        var routesByTheme: [CompanionTheme: Set<String>] = [:]
        for theme in CompanionTheme.allCases where theme != .none {
            for stage in 0..<CompanionJourney.thresholds.count {
                for field in plan(for: theme, stage: stage).actors {
                    routesByTheme[theme, default: []].insert(field.route.name)
                    XCTAssertGreaterThan(
                        field.count, 0,
                        "\(field.key) declares an empty population"
                    )
                }
            }
        }
        // Every world that has inhabitants at all has them at some stage.
        for theme in CompanionTheme.allCases where theme != .none {
            XCTAssertNotNil(
                routesByTheme[theme],
                "\(theme.title) has nobody living in it"
            )
        }
        // And no world borrows another world's idea of purposeful movement as
        // its only one: an errand, a tick, a patrol and a wander are different
        // kinds of life.
        XCTAssertEqual(routesByTheme[.ageOfEmpiresII], ["errand", "wander"])
        XCTAssertEqual(routesByTheme[.oldSchoolRuneScape], ["ticked"])
        XCTAssertEqual(routesByTheme[.minecraft], ["wander"])
        XCTAssertEqual(routesByTheme[.pokemon], ["perch"])
        XCTAssertEqual(routesByTheme[.forest], ["patrol", "perch"])
        XCTAssertEqual(routesByTheme[.village], ["patrol", "perch"])
    }

    func testASettlementGetsBusierAsItAges() {
        let counts = (0..<CompanionJourney.thresholds.count).map { stage in
            plan(for: .ageOfEmpiresII, stage: stage)
                .actors
                .first { $0.key == "aoe/villagers" }?
                .count ?? 0
        }
        XCTAssertEqual(counts.first, 2, "a dark age camp still needs somebody in it")
        XCTAssertGreaterThan(
            try! XCTUnwrap(counts.last), try! XCTUnwrap(counts.first),
            "an imperial capital should be busier than a dark age camp"
        )
        for (earlier, later) in zip(counts, counts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later, earlier, "a town never loses people")
        }
        XCTAssertLessThanOrEqual(
            try! XCTUnwrap(counts.max()), 6,
            "the foreground can only hold so many"
        )

        // The herd is there from the first age to the last.
        for stage in 0..<CompanionJourney.thresholds.count {
            XCTAssertTrue(
                plan(for: .ageOfEmpiresII, stage: stage).effectKeys.contains("aoe/herd")
            )
        }
    }

    func testTheGrandExchangeIsTheBusiestPlaceInTheGame() {
        func players(stage: Int) -> Int {
            CompanionOldSchoolCrowd.population(stage: stage)
                .first { $0.key == "osrs/players" }?
                .count ?? 0
        }
        XCTAssertEqual(
            players(stage: 4),
            CompanionOldSchoolCrowd.playersByStage.max(),
            "nowhere in the game is busier than the Grand Exchange"
        )
        XCTAssertEqual(players(stage: 9), 0, "a god war is not a place to loiter")
        XCTAssertGreaterThan(players(stage: 11), 0, "a raid is run by a team")

        // Lumbridge, and only Lumbridge, has the chickens.
        for stage in 0..<CompanionJourney.thresholds.count {
            let hasChickens = plan(for: .oldSchoolRuneScape, stage: stage)
                .effectKeys
                .contains("osrs/chickens")
            XCTAssertEqual(hasChickens, stage == 0, "chickens escaped to stage \(stage + 1)")
        }
    }

    func testSomeBiomesAreEmptyOnPurpose() {
        let silent: Set<CompanionBiome> = [
            .ancientCity, .netherFortress, .theEnd, .endCity
        ]
        for biome in CompanionBiome.allCases {
            let population = biome.plan(stage: 0, seed: seed).actors
            if silent.contains(biome) {
                XCTAssertTrue(
                    population.isEmpty,
                    "\(biome.rawValue) is meant to be a place nothing wanders through"
                )
            } else {
                XCTAssertFalse(
                    population.isEmpty,
                    "\(biome.rawValue) should have its own mob"
                )
            }
        }
        // Even a silent biome is never a dead scene — its life is its light
        // and its particles.
        for biome in silent {
            XCTAssertFalse(biome.plan(stage: 0, seed: seed).effectKeys.isEmpty)
        }
    }

    func testBirdsOnlyLandOnSomethingTheLayoutActuallyBuilt() throws {
        // A grown wood: every roost sits in the crown of a tree that is there.
        let trees = layers(for: .forest, stage: 10).filter { $0.role == .tree }
        let roosts = plan(for: .forest, stage: 10).actors
            .filter { $0.key.hasPrefix("forest/roost/") }
        XCTAssertFalse(roosts.isEmpty, "an old wood should hold a roost")
        for roost in roosts {
            let perch = try XCTUnwrap(roost.route.perchPoint)
            XCTAssertTrue(
                trees.contains { abs($0.horizontalPosition - perch.x) < 1e-9 },
                "a bird is perched on thin air at \(perch.x)"
            )
            XCTAssertTrue(
                (0...1).contains(perch.y),
                "a crown outside the frame at \(perch.y)"
            )
        }

        // A lone sapling has nothing tall enough to hold a bird.
        XCTAssertTrue(
            plan(for: .forest, stage: 0).actors
                .filter { $0.key.hasPrefix("forest/roost/") }
                .isEmpty
        )

        // The town's bird lands on the ridge of a building the town built.
        let buildings = layers(for: .village, stage: 5).filter { $0.role == .building }
        let rooftop = try XCTUnwrap(
            plan(for: .village, stage: 5).actors.first { $0.key == "village/rooftop-bird" }
        )
        let ridge = try XCTUnwrap(rooftop.route.perchPoint)
        XCTAssertTrue(
            buildings.contains { abs($0.horizontalPosition - ridge.x) < 1e-9 },
            "a bird is perched over open ground at \(ridge.x)"
        )
    }

    func testDeerOnlyLiveInAWoodThatHasClosedOver() {
        for stage in 0..<CompanionJourney.thresholds.count {
            let hasDeer = plan(for: .forest, stage: stage).effectKeys.contains("forest/deer")
            XCTAssertEqual(
                hasDeer, stage >= 4,
                "deer are browsing a grove of saplings at stage \(stage + 1)"
            )
        }
    }

    func testTheVillageTradesItsStreetForANightShift() {
        let day = plan(for: .village, stage: 4).effectKeys
        XCTAssertTrue(day.contains("village/townsfolk"))
        XCTAssertTrue(day.contains("village/stray"))
        XCTAssertFalse(day.contains("village/late-walkers"))

        let night = plan(for: .village, stage: 10).effectKeys
        XCTAssertTrue(night.contains("village/late-walkers"))
        XCTAssertFalse(night.contains("village/townsfolk"))
        XCTAssertFalse(
            night.contains("village/stray"),
            "the dog goes home when the street lights come on"
        )
    }

    // MARK: - Lifecycle pausing

    func testNoInhabitantMovesWhileTheSceneIsPaused() {
        for theme in CompanionTheme.allCases where theme != .none {
            for stage in 0..<CompanionJourney.thresholds.count {
                let plan = plan(for: theme, stage: stage)
                guard !plan.actors.isEmpty else { continue }
                let first = plan.frame(at: 2.5, isMoving: false)
                let later = plan.frame(at: 654_321.75, isMoving: false)
                XCTAssertEqual(
                    first.actors, later.actors,
                    "\(theme.title) stage \(stage + 1) drifts while paused"
                )
                XCTAssertFalse(
                    first.actors.isEmpty,
                    "a paused \(theme.title) should still be a populated still"
                )
            }
        }
    }

    // MARK: - Determinism

    func testAPopulationResolvesIdenticallyForTheSameSeedAndMoment() throws {
        let field = try XCTUnwrap(
            plan(for: .ageOfEmpiresII, stage: 9).actors.first { $0.key == "aoe/villagers" }
        )
        XCTAssertEqual(field.actors(at: 8.25, seed: seed), field.actors(at: 8.25, seed: seed))
        XCTAssertEqual(field.actors(at: 8.25, seed: seed).count, field.count)
        XCTAssertNotEqual(
            field.actors(at: 8.25, seed: seed).map(\.x),
            field.actors(at: 8.25, seed: seed &+ 1).map(\.x),
            "a different install should run its errands from different places"
        )
    }

    func testEveryInhabitantStaysOnItsGroundLineAndInsideTheWorld() {
        forEveryPopulation { field, theme, stage in
            for step in 0...120 {
                let time = Double(step) * 1.7
                for actor in field.actors(at: time, seed: seed) {
                    XCTAssertTrue(
                        (-0.45...1.45).contains(actor.x),
                        "\(field.key) wandered off the map at x \(actor.x)"
                    )
                    XCTAssertTrue(
                        (-0.10...1.05).contains(actor.y),
                        "\(field.key) left the ground at y \(actor.y)"
                    )
                    XCTAssertTrue(
                        (0...1).contains(actor.speed),
                        "\(field.key) reports an impossible pace"
                    )
                    XCTAssertTrue(abs(actor.facing) == 1)
                    XCTAssertGreaterThan(actor.height, 0)
                    _ = (theme, stage)
                }
            }
        }
    }

    func testAnInhabitantOnlyEverJumpsOffScreen() {
        forEveryPopulation { field, _, _ in
            // A ticked world is meant to hard-cut; it gets its own test.
            guard field.route.name != "ticked" else { return }
            let steps = 400
            let interval = field.route.period * 2 / Double(steps)
            var previous = field.actors(at: 0, seed: seed)
            for step in 1...steps {
                let current = field.actors(at: Double(step) * interval, seed: seed)
                for (before, after) in zip(previous, current) {
                    let travelled = abs(after.x - before.x)
                    guard travelled > 0.08 else { continue }
                    // The only allowed jump is a route looping back to its
                    // start, and that has to happen out of sight.
                    XCTAssertTrue(
                        before.x < -0.05 || before.x > 1.05,
                        "\(field.key) looped back in plain sight from \(before.x)"
                    )
                }
                previous = current
            }
        }
    }

    func testATickedInhabitantMovesOneWholeTileAndOnlyOnATick() {
        forEveryPopulation { field, _, _ in
            guard case let .ticked(_, _, _, tile) = field.route else { return }
            let tick = CompanionSceneMotion.gameTick
            for index in 0..<200 {
                let start = Double(index) * tick
                let early = field.actors(at: start + 0.02, seed: seed)
                let late = field.actors(at: start + tick - 0.02, seed: seed)
                for (a, b) in zip(early, late) {
                    XCTAssertEqual(a.x, b.x, accuracy: 1e-12, "\(field.key) slid inside a tick")
                    XCTAssertEqual(a.y, b.y, accuracy: 1e-12, "\(field.key) slid inside a tick")
                }
                let next = field.actors(at: start + tick + 0.02, seed: seed)
                for (a, b) in zip(early, next) {
                    XCTAssertLessThanOrEqual(
                        abs(b.x - a.x), tile + 1e-9,
                        "\(field.key) covered more than a tile in one tick"
                    )
                    XCTAssertLessThanOrEqual(
                        abs(b.y - a.y), tile / 2 + 1e-9,
                        "\(field.key) covered more than a tile in one tick"
                    )
                }
            }
        }
    }

    func testLimbsOnlySwingWhenSomebodyIsActuallyMoving() throws {
        // A gatherer standing at a work site is not walking on the spot.
        let villagers = try XCTUnwrap(
            plan(for: .ageOfEmpiresII, stage: 6).actors.first { $0.key == "aoe/villagers" }
        )
        var sawWork = false
        var sawWalk = false
        for step in 0...600 {
            for actor in villagers.actors(at: Double(step) * 0.1, seed: seed) {
                if case .working = actor.pose {
                    XCTAssertEqual(actor.speed, 0, "a villager is jogging at the tree line")
                    sawWork = true
                }
                if actor.pose == .walking, actor.speed > 0.05 { sawWalk = true }
            }
        }
        XCTAssertTrue(sawWork, "no villager ever reached a work site")
        XCTAssertTrue(sawWalk, "no villager ever walked anywhere")
    }

    func testAGathererCarriesSomethingHomeAgain() throws {
        let villagers = try XCTUnwrap(
            plan(for: .ageOfEmpiresII, stage: 3).actors.first { $0.key == "aoe/villagers" }
        )
        var poses: Set<String> = []
        for step in 0...900 {
            for actor in villagers.actors(at: Double(step) * 0.1, seed: seed) {
                poses.insert(actor.pose.name)
            }
        }
        XCTAssertTrue(poses.isSuperset(of: ["walking", "working", "carrying"]),
                      "an errand is out, work, and back — saw \(poses.sorted())")
    }

    func testAVisitingBirdActuallyLandsAndLeavesAgain() throws {
        let visitor = try XCTUnwrap(
            plan(for: .pokemon, stage: 2).actors.first { $0.key == "pokemon/visitor" }
        )
        let perch = try XCTUnwrap(visitor.route.perchPoint)
        var landed = false
        var flew = false
        for step in 0...1200 {
            for actor in visitor.actors(at: Double(step) * 0.05, seed: seed) {
                switch actor.pose {
                case .perched:
                    landed = true
                    XCTAssertEqual(actor.speed, 0)
                    XCTAssertEqual(actor.y, perch.y, accuracy: 0.02)
                case .flying:
                    flew = true
                default:
                    break
                }
            }
        }
        XCTAssertTrue(landed, "the visitor never came down")
        XCTAssertTrue(flew, "the visitor never left")
    }

    // MARK: - Being noticed

    func testOnlyPopulationsThatAskForItDrawAttention() {
        for theme in CompanionTheme.allCases where theme != .none {
            for stage in 0..<CompanionJourney.thresholds.count {
                let plan = plan(for: theme, stage: stage)
                let expected = plan.actors
                    .filter(\.drawsAttention)
                    .reduce(0) { $0 + $1.count }
                XCTAssertEqual(
                    plan.frame(at: 3.5, isMoving: true).attention.positions.count,
                    expected,
                    "\(theme.title) stage \(stage + 1) notices the wrong things"
                )
            }
        }
        // Nothing a building does is worth a second look.
        XCTAssertEqual(
            plan(for: .village, stage: 4).frame(at: 3.5, isMoving: true).attention,
            .none
        )
    }

    func testAttentionPicksTheNearestThingWorthWatching() {
        let attention = CompanionAttention(positions: [0.1, 0.48, 0.9])
        XCTAssertEqual(attention.nearest(to: 0.5), 0.48)
        XCTAssertEqual(attention.nearest(to: 0.95), 0.9)
        XCTAssertNil(CompanionAttention.none.nearest(to: 0.5))
    }

    func testTheAdventurerTurnsTowardWhoeverWalkedPast() {
        let onTheLeft = subject(
            signature: .gameTick,
            role: .adventurer,
            elapsed: 3.0,
            attention: CompanionAttention(positions: [0.2])
        )
        let onTheRight = subject(
            signature: .gameTick,
            role: .adventurer,
            elapsed: 3.0,
            attention: CompanionAttention(positions: [0.8])
        )
        XCTAssertTrue(onTheLeft.flipped)
        XCTAssertFalse(onTheRight.flipped)

        // Somebody on the far side of the world is not worth turning for.
        let farAway = subject(
            signature: .gameTick,
            role: .adventurer,
            elapsed: 3.0,
            attention: CompanionAttention(positions: [0.02])
        )
        XCTAssertEqual(
            farAway,
            subject(signature: .gameTick, role: .adventurer, elapsed: 3.0)
        )
    }

    func testTheSurvivorTurnsTowardTheMobAndTheTownDoesNot() {
        let survivor = subject(
            signature: .blockyBiome,
            role: .survivor,
            elapsed: 1.4,
            attention: CompanionAttention(positions: [0.25])
        )
        XCTAssertTrue(survivor.flipped)

        // A building does not turn around for anybody.
        XCTAssertEqual(
            subject(
                signature: .townLife,
                role: .building,
                elapsed: 1.4,
                attention: CompanionAttention(positions: [0.4])
            ),
            .still
        )
    }

    func testThePartnerStandsUpForSomethingBesideIt() {
        let alone = subject(signature: .creatureIdle, role: .creature, elapsed: 2.2)
        let joined = subject(
            signature: .creatureIdle,
            role: .creature,
            elapsed: 2.2,
            attention: CompanionAttention(positions: [0.52])
        )
        XCTAssertNotEqual(alone, joined, "the partner ignored something at its feet")
        XCTAssertLessThan(joined.offsetY, alone.offsetY, "noticing should lift, not sink")

        // And ignores something on the far side of the route.
        XCTAssertEqual(
            subject(
                signature: .creatureIdle,
                role: .creature,
                elapsed: 2.2,
                attention: CompanionAttention(positions: [0.95])
            ),
            alone
        )
    }

    // MARK: - Weather that the world answers to

    func testTheCanopyOnlyShedsWhereTheWindIs() throws {
        let leaves = try XCTUnwrap(
            plan(for: .forest, stage: 8).fields.first { $0.key == "forest/leaves" }
        )
        XCTAssertEqual(leaves.coupling, .gust)

        var strongest = 0.0
        var calmest = Double.greatestFiniteMagnitude
        for step in 0...900 {
            let time = Double(step) * 0.05
            let gust = CompanionSceneMotion.gustStrength(at: 0.5, elapsed: time)
            let nearby = leaves.particles(at: time, seed: seed)
                .filter { abs($0.x - 0.5) < 0.08 }
                .map(\.opacity)
            guard let peak = nearby.max() else { continue }
            if gust > 0.85 { strongest = max(strongest, peak) }
            if gust < 0.05 { calmest = min(calmest, peak) }
        }
        XCTAssertGreaterThan(strongest, 0.2, "a gust should actually take leaves with it")
        XCTAssertLessThan(calmest, 0.12, "leaves are falling out of a still canopy")

        // Only the forest answers to the wind this way.
        for theme in CompanionTheme.allCases where theme != .none && theme != .forest {
            for stage in 0..<CompanionJourney.thresholds.count {
                for field in plan(for: theme, stage: stage).fields {
                    XCTAssertEqual(field.coupling, .none, "\(field.key) borrowed the forest's wind")
                }
            }
        }
    }

    func testAPerchRouteAlwaysLeavesTheFrameBeforeItLoops() {
        forEveryPopulation { field, _, _ in
            guard case let .perch(at: target, approachFrom: entry, _, _) = field.route else {
                return
            }
            XCTAssertTrue(
                entry.x < -0.05 || entry.x > 1.05,
                "\(field.key) arrives from inside the frame"
            )
            XCTAssertTrue((0...1).contains(target.x), "\(field.key) perches off frame")
        }
    }

    // MARK: - Helpers

    private func forEveryPopulation(
        _ body: (CompanionActorField, CompanionTheme, Int) -> Void
    ) {
        for theme in CompanionTheme.allCases where theme != .none {
            for stage in 0..<CompanionJourney.thresholds.count {
                for field in plan(for: theme, stage: stage).actors {
                    body(field, theme, stage)
                }
            }
        }
    }

    private func plan(for theme: CompanionTheme, stage: Int) -> CompanionScenePlan {
        CompanionScenePlan.make(
            theme: theme,
            stage: stage,
            seed: seed,
            layers: layers(for: theme, stage: stage)
        )
    }

    private func layers(for theme: CompanionTheme, stage: Int) -> [CompanionSceneLayer] {
        guard let variant = CompanionCatalog.variants(for: theme).first else { return [] }
        return CompanionAssetCatalog.scene(
            theme: theme,
            variant: variant,
            stage: stage,
            fraction: 0.5,
            seed: seed
        )?.layers ?? []
    }

    private func subject(
        signature: CompanionMotionSignature,
        role: CompanionSubjectRole,
        elapsed: Double,
        attention: CompanionAttention = .none
    ) -> CompanionSubjectMotion {
        CompanionSceneMotion.subject(
            signature: signature,
            role: role,
            index: 0,
            horizontalPosition: 0.5,
            relativeHeight: 0.6,
            stage: 5,
            seed: seed,
            elapsed: elapsed,
            isMoving: true,
            attention: attention
        )
    }
}

// MARK: - Test-only descriptions

private extension CompanionActorRoute {
    /// A stable name for the kind of life this route is, so a test can say
    /// "this world runs errands" without matching on associated values.
    var name: String {
        switch self {
        case .patrol: "patrol"
        case .errand: "errand"
        case .ticked: "ticked"
        case .wander: "wander"
        case .perch: "perch"
        }
    }

    /// How long one full loop of this route takes, before per-inhabitant
    /// tempo. Used to sample a route across its whole cycle.
    var period: Double {
        switch self {
        case let .patrol(_, _, period, _): period
        case let .errand(_, _, period, _): period
        case .ticked: 60
        case let .wander(_, _, _, period, _): period
        case let .perch(_, _, period, _): period
        }
    }

    var perchPoint: CompanionScenePoint? {
        guard case let .perch(at: point, _, _, _) = self else { return nil }
        return point
    }
}

private extension CompanionActorPose {
    var name: String {
        switch self {
        case .walking: "walking"
        case .carrying: "carrying"
        case .working: "working"
        case .idle: "idle"
        case .perched: "perched"
        case .flying: "flying"
        }
    }
}
