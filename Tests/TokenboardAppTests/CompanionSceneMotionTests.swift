import Foundation
import XCTest
@testable import TokenboardApp

/// The companion scenes are art direction, not a shared idle. These tests
/// pin down which world gets which life, that nothing runs while a scene is
/// off screen, and that everything a scene does is reproducible from the seed.
final class CompanionSceneMotionTests: XCTestCase, CompanionSceneFixtures {
    // MARK: - Animation selection

    func testEveryVisibleThemeSpeaksItsOwnMotionLanguage() {
        var signatures: Set<CompanionMotionSignature> = []
        for theme in CompanionTheme.allCases where theme != .none {
            let signature = CompanionMotionSignature.of(theme)
            XCTAssertNotEqual(signature, .none, "\(theme.title) needs a motion language")
            XCTAssertTrue(
                signatures.insert(signature).inserted,
                "\(theme.title) reuses another theme's motion language"
            )
        }
        XCTAssertEqual(CompanionMotionSignature.of(.none), .none)
    }

    func testNoTwoWorldsShareAnEffect() {
        var owners: [String: CompanionTheme] = [:]
        for theme in CompanionTheme.allCases where theme != .none {
            for stage in 0..<CompanionJourney.thresholds.count {
                let plan = plan(for: theme, stage: stage)
                XCTAssertFalse(
                    plan.effectKeys.isEmpty,
                    "\(theme.title) stage \(stage + 1) has no life at all"
                )
                for key in plan.effectKeys {
                    if let owner = owners[key] {
                        XCTAssertEqual(
                            owner, theme,
                            "\(key) is shared between \(owner.title) and \(theme.title)"
                        )
                    }
                    owners[key] = theme
                }
            }
        }
        XCTAssertGreaterThan(owners.count, 20, "the worlds should not all animate alike")
    }

    func testNoneAnimatesNothing() {
        let plan = CompanionScenePlan.make(theme: .none, stage: 0, seed: seed, layers: [])
        XCTAssertEqual(plan, .inert)
        XCTAssertTrue(plan.effectKeys.isEmpty)
        XCTAssertEqual(plan.frame(at: 12.5, isMoving: true).particles.count, 0)
    }

    func testOldSchoolWeatherFollowsTheLocationTheAdventurerIsStandingIn() {
        XCTAssertEqual(CompanionLocationWeather.forOldSchool(stage: 0), .openAir)
        XCTAssertEqual(CompanionLocationWeather.forOldSchool(stage: 1), .desert)
        XCTAssertEqual(CompanionLocationWeather.forOldSchool(stage: 8), .gloom)
        XCTAssertEqual(CompanionLocationWeather.forOldSchool(stage: 9), .snow)
        XCTAssertEqual(CompanionLocationWeather.forOldSchool(stage: 10), .crystal)
        XCTAssertEqual(CompanionLocationWeather.forOldSchool(stage: 11), .torchlit)

        // Outdoors gets weather overhead; a tomb gets torchlight instead.
        let lumbridge = plan(for: .oldSchoolRuneScape, stage: 0)
        XCTAssertTrue(lumbridge.effectKeys.contains("osrs/cloud-shadow"))
        XCTAssertTrue(lumbridge.effectKeys.contains("osrs/birds"))
        XCTAssertTrue(lumbridge.glows.isEmpty)

        let tombs = plan(for: .oldSchoolRuneScape, stage: 11)
        XCTAssertEqual(tombs.glows.count, 2, "a tomb is lit by its torches")
        XCTAssertTrue(tombs.bands.isEmpty, "no clouds pass through a sealed tomb")
        XCTAssertFalse(tombs.effectKeys.contains("osrs/birds"))

        let godWars = plan(for: .oldSchoolRuneScape, stage: 9)
        XCTAssertTrue(godWars.effectKeys.contains("osrs/snow"))
    }

    func testMinecraftEmitsTheParticleItsBiomeActuallyHas() {
        XCTAssertEqual(CompanionBiome.forMinecraft(stage: 0), .plains)
        XCTAssertEqual(CompanionBiome.forMinecraft(stage: 6), .netherWastes)
        XCTAssertEqual(CompanionBiome.forMinecraft(stage: 10), .theEnd)
        XCTAssertEqual(CompanionBiome.forMinecraft(stage: 99), .endCity)

        XCTAssertTrue(plan(for: .minecraft, stage: 4).effectKeys.contains("mc/peak-snow"))
        XCTAssertTrue(plan(for: .minecraft, stage: 6).effectKeys.contains("mc/embers"))
        XCTAssertTrue(plan(for: .minecraft, stage: 3).effectKeys.contains("mc/cave-drips"))
        XCTAssertTrue(plan(for: .minecraft, stage: 10).effectKeys.contains("mc/end-motes"))

        // Every Minecraft particle is a hard square; nothing in that world is
        // drawn with a soft falloff.
        for stage in 0..<CompanionJourney.thresholds.count {
            for field in plan(for: .minecraft, stage: stage).fields {
                XCTAssertEqual(field.shape, .pixel, "\(field.key) is not blocky")
            }
        }
    }

    func testVillageTradesChimneysAndBirdsForTrafficAndStarsAtNight() throws {
        let day = plan(for: .village, stage: 4)
        XCTAssertTrue(day.effectKeys.contains("village/birds"))
        XCTAssertFalse(day.effectKeys.contains("village/headlights"))
        XCTAssertFalse(day.effectKeys.contains("village/stars"))

        let night = plan(for: .village, stage: 10)
        XCTAssertTrue(night.effectKeys.contains("village/headlights"))
        XCTAssertTrue(night.effectKeys.contains("village/taillights"))
        XCTAssertTrue(night.effectKeys.contains("village/stars"))
        XCTAssertFalse(night.effectKeys.contains("village/birds"))

        // Smoke only ever leaves a roof the scene actually placed.
        let layers = try XCTUnwrap(villageLayers(stage: 10)).filter { $0.role == .building }
        let roofs = Set(layers.map(\.horizontalPosition))
        let smoke = night.fields.filter { $0.key.hasPrefix("village/smoke/") }
        XCTAssertFalse(smoke.isEmpty)
        for field in smoke {
            let x = (field.spawnX.lowerBound + field.spawnX.upperBound) / 2
            XCTAssertTrue(
                roofs.contains(where: { abs($0 - x) < 1e-9 }),
                "a chimney plume is rising from open ground at \(x)"
            )
        }
    }

    func testLateStagesEarnTheirOwnLight() {
        XCTAssertFalse(plan(for: .forest, stage: 3).effectKeys.contains("forest/fireflies"))
        XCTAssertTrue(plan(for: .forest, stage: 10).effectKeys.contains("forest/fireflies"))
        XCTAssertFalse(plan(for: .pokemon, stage: 3).effectKeys.contains("pokemon/sparks"))
        XCTAssertTrue(plan(for: .pokemon, stage: 10).effectKeys.contains("pokemon/sparks"))
    }

    func testOnlyTheIsometricWorldMovesItsCamera() {
        for theme in CompanionTheme.allCases where theme != .none {
            let drift = plan(for: theme, stage: 5).backgroundDrift
            if theme == .ageOfEmpiresII {
                XCTAssertEqual(drift, .isometricWander)
            } else {
                XCTAssertEqual(drift, .still, "\(theme.title) must not drift its plate")
            }
        }
        let wander = CompanionSceneMotion.background(drift: .isometricWander, elapsed: 4.2)
        XCTAssertNotEqual(wander.offsetX, 0)
        XCTAssertGreaterThan(wander.scale, 1)
    }

    func testEachWorldMovesItsSubjectsInADifferentWay() {
        let time = 2.35

        // Pokémon breathes: the partner changes shape, never its angle.
        let partner = subject(signature: .creatureIdle, role: .creature, elapsed: time)
        XCTAssertNotEqual(partner.scaleY, 1)
        XCTAssertEqual(partner.rotation, 0)

        // Forest bends: trees change angle, never their shape's width.
        let tree = subject(
            signature: .windGusts,
            role: .tree,
            elapsed: time,
            horizontalPosition: 0.5,
            relativeHeight: 0.7
        )
        XCTAssertNotEqual(tree.rotation, 0)
        XCTAssertEqual(tree.scaleX, 1)

        // Village holds still. Its life is elsewhere.
        XCTAssertEqual(
            subject(signature: .townLife, role: .building, elapsed: time),
            .still
        )

        // Minecraft steps and never deforms.
        let survivor = subject(signature: .blockyBiome, role: .survivor, elapsed: time)
        XCTAssertEqual(survivor.scaleX, 1)
        XCTAssertEqual(survivor.scaleY, 1)
        XCTAssertEqual(survivor.rotation, 0)

        // Age of Empires II has no subjects to move at all.
        XCTAssertEqual(
            subject(signature: .isometricDaylight, role: .building, elapsed: time),
            .still
        )
    }

    func testTheForestIsGenuinelyStillBetweenGusts() {
        let samples = stride(from: 0.0, through: 30.0, by: 0.1).map {
            CompanionSceneMotion.gustStrength(at: 0.5, elapsed: $0)
        }
        XCTAssertGreaterThan(try! XCTUnwrap(samples.max()), 0.8, "the wind must arrive")
        XCTAssertLessThan(try! XCTUnwrap(samples.min()), 0.05, "and it must leave again")
        for sample in samples {
            XCTAssertTrue((0...1).contains(sample))
        }
    }

    func testTheAdventurerOnlyEverChangesPoseOnAGameTick() {
        let tick = CompanionSceneMotion.gameTick
        for index in 0..<60 {
            let start = Double(index) * tick
            let pose = CompanionSceneMotion.tickIdle(seed: seed, elapsed: start + 0.01)
            let late = CompanionSceneMotion.tickIdle(seed: seed, elapsed: start + tick - 0.01)
            XCTAssertEqual(pose, late, "the pose changed inside tick \(index)")
        }
        let poses = (0..<200).map {
            CompanionSceneMotion.tickIdle(seed: seed, elapsed: Double($0) * tick)
        }
        XCTAssertGreaterThan(Set(poses).count, 2, "the idle needs more than one pose")
        XCTAssertTrue(poses.contains { $0.flipped }, "the adventurer should turn around")
    }

    func testTheSurvivorIdlesInWholeSteps() {
        let lifts = stride(from: 0.0, through: 6.0, by: 0.01)
            .map { CompanionSceneMotion.steppedIdle(elapsed: $0).offsetY }
        XCTAssertEqual(Set(lifts).count, 3, "a blocky idle has a handful of poses, not a curve")
    }

    // MARK: - Lifecycle pausing

    func testAPausedSceneIsAComposedStillThatIgnoresTheClock() {
        for theme in CompanionTheme.allCases where theme != .none {
            let plan = plan(for: theme, stage: 6)
            let first = plan.frame(at: 3.0, isMoving: false)
            let later = plan.frame(at: 918_273.5, isMoving: false)
            XCTAssertEqual(first, later, "\(theme.title) still is not stable")
            XCTAssertEqual(first.background, .still)
            XCTAssertFalse(
                first.particles.isEmpty && first.bands.isEmpty && first.glows.isEmpty,
                "\(theme.title) should still be composed when it is not moving"
            )
            // A composed still keeps the atmosphere but never a peak wash.
            XCTAssertEqual(first.wash, plan.wash?.resting ?? .none)
        }
    }

    func testNoSubjectMovesWhileTheSceneIsPaused() {
        for signature in CompanionMotionSignature.allCases {
            for role in [
                CompanionSubjectRole.creature, .adventurer, .survivor, .tree, .building
            ] {
                XCTAssertEqual(
                    subject(signature: signature, role: role, elapsed: 7.75, isMoving: false),
                    .still,
                    "\(signature.rawValue)/\(role.rawValue) moved while paused"
                )
            }
        }
    }

    func testASceneOnlyCountsAsOnScreenWhenItsWindowReallyIs() {
        func visible(
            hasWindow: Bool = true,
            windowIsVisible: Bool = true,
            isMiniaturized: Bool = false,
            occlusionIsVisible: Bool = true,
            applicationIsHidden: Bool = false
        ) -> Bool {
            CompanionSceneVisibilityPolicy.isOnScreen(
                hasWindow: hasWindow,
                windowIsVisible: windowIsVisible,
                isMiniaturized: isMiniaturized,
                occlusionIsVisible: occlusionIsVisible,
                applicationIsHidden: applicationIsHidden
            )
        }

        XCTAssertTrue(visible())
        XCTAssertFalse(visible(windowIsVisible: false))
        XCTAssertFalse(visible(isMiniaturized: true))
        XCTAssertFalse(visible(occlusionIsVisible: false))
        XCTAssertFalse(visible(applicationIsHidden: true))
        // Before the view reaches a window there is nothing to judge, and the
        // caller's own presentation flag still gates the scene.
        XCTAssertTrue(visible(hasWindow: false, windowIsVisible: false))
    }

    // MARK: - Determinism

    func testAFieldResolvesIdenticallyForTheSameSeedAndMoment() {
        let field = try! XCTUnwrap(plan(for: .minecraft, stage: 6).fields.first)
        XCTAssertEqual(
            field.particles(at: 4.25, seed: seed),
            field.particles(at: 4.25, seed: seed)
        )
        XCTAssertNotEqual(
            field.particles(at: 4.25, seed: seed).map(\.x),
            field.particles(at: 4.25, seed: seed &+ 1).map(\.x),
            "a different install should scatter its embers differently"
        )
        XCTAssertEqual(field.particles(at: 4.25, seed: seed).count, field.count)
    }

    func testNoParticleEverJumpsWhileItIsVisible() {
        for theme in CompanionTheme.allCases where theme != .none {
            for stage in 0..<CompanionJourney.thresholds.count {
                for field in plan(for: theme, stage: stage).fields {
                    let steps = 240
                    let interval = field.lifetime * 2 / Double(steps)
                    var previous = field.particles(at: 0, seed: seed)
                    for step in 1...steps {
                        let current = field.particles(
                            at: Double(step) * interval,
                            seed: seed
                        )
                        for (before, after) in zip(previous, current) {
                            guard max(before.opacity, after.opacity) > 0.02 else { continue }
                            XCTAssertLessThan(
                                abs(after.x - before.x), 0.06,
                                "\(field.key) teleports across the scene in plain sight"
                            )
                            XCTAssertLessThan(
                                abs(after.y - before.y), 0.06,
                                "\(field.key) teleports across the scene in plain sight"
                            )
                        }
                        previous = current
                    }
                }
            }
        }
    }

    func testEveryParticleStaysNearTheFrameAndInsideItsOpacityRange() {
        for theme in CompanionTheme.allCases where theme != .none {
            for stage in 0..<CompanionJourney.thresholds.count {
                for field in plan(for: theme, stage: stage).fields {
                    XCTAssertEqual(field.particles(at: 1.5, seed: seed).count, field.count)
                    for step in 0...40 {
                        let time = field.lifetime * Double(step) / 40
                        for particle in field.particles(at: time, seed: seed) {
                            XCTAssertTrue(
                                (-0.5...1.5).contains(particle.x),
                                "\(field.key) drifted out of the world at x \(particle.x)"
                            )
                            XCTAssertTrue(
                                (-0.5...1.6).contains(particle.y),
                                "\(field.key) drifted out of the world at y \(particle.y)"
                            )
                            XCTAssertGreaterThanOrEqual(particle.opacity, 0)
                            XCTAssertLessThanOrEqual(
                                particle.opacity,
                                field.opacity.upperBound + 1e-9
                            )
                        }
                    }
                }
            }
        }
    }

    func testWindowLightingIsStablePerInstallAndOnlyEverChangesSomeRooms() {
        let cell = CompanionWindowCell(x: 0.2, y: 0.3, width: 0.1, height: 0.1, bakedLit: true)
        let lit = CompanionWindowLighting.isLit(
            cell: cell, index: 3, layerID: "village-slot-4", seed: seed, elapsed: 12
        )
        XCTAssertEqual(
            lit,
            CompanionWindowLighting.isLit(
                cell: cell, index: 3, layerID: "village-slot-4", seed: seed, elapsed: 12
            )
        )

        // A window that never changes always shows exactly what was painted.
        for index in 0..<400 where !CompanionWindowLighting.animates(
            index: index, layerID: "village-slot-1", seed: seed
        ) {
            for baked in [true, false] {
                let fixed = CompanionWindowCell(
                    x: 0, y: 0, width: 0.1, height: 0.1, bakedLit: baked
                )
                XCTAssertEqual(
                    CompanionWindowLighting.isLit(
                        cell: fixed,
                        index: index,
                        layerID: "village-slot-1",
                        seed: seed,
                        elapsed: Double(index) * 3.7
                    ),
                    baked
                )
            }
        }

        let animated = (0..<600).filter {
            CompanionWindowLighting.animates(index: $0, layerID: "village-slot-2", seed: seed)
        }
        let share = Double(animated.count) / 600
        XCTAssertGreaterThan(share, 0.22, "some of the town should be awake")
        XCTAssertLessThan(share, 0.45, "but the skyline must keep the shape it was painted in")
    }

    func testAWindowActuallySwitchesOverAnEvening() {
        let cell = CompanionWindowCell(x: 0, y: 0, width: 0.1, height: 0.1, bakedLit: false)
        var changed = false
        for layer in 0..<24 where !changed {
            for index in 0..<12 {
                let states = stride(from: 0.0, through: 120.0, by: 0.5).map {
                    CompanionWindowLighting.isLit(
                        cell: cell,
                        index: index,
                        layerID: "village-slot-\(layer)",
                        seed: seed,
                        elapsed: $0
                    )
                }
                if Set(states).count > 1 { changed = true; break }
            }
        }
        XCTAssertTrue(changed, "no window in the whole town ever switched")
    }

    func testTheSceneClockIsTheSystemClock() {
        let date = Date(timeIntervalSinceReferenceDate: 1234.5)
        XCTAssertEqual(CompanionSceneMotion.elapsed(at: date), 1234.5, accuracy: 1e-9)
    }

    // MARK: - Helpers

    private func villageLayers(stage: Int) -> [CompanionSceneLayer]? {
        let layers = layers(for: .village, stage: stage)
        return layers.isEmpty ? nil : layers
    }
}
