import Foundation

/// The art direction for every companion world: which atmosphere, weather,
/// and light each theme — and, where the journey passes through genuinely
/// different places, each stage — is allowed to run.
///
/// Nothing here is generic. A world only gets an effect if that effect is
/// something that world actually does.
extension CompanionScenePlan {
    static func make(
        theme: CompanionTheme,
        stage: Int,
        seed: UInt64,
        layers: [CompanionSceneLayer]
    ) -> CompanionScenePlan {
        let signature = CompanionMotionSignature.of(theme)
        let stage = min(max(stage, 0), CompanionJourney.thresholds.count - 1)
        switch signature {
        case .none:
            return .inert
        case .creatureIdle:
            return meadow(stage: stage, seed: seed)
        case .windGusts:
            return woodland(stage: stage, seed: seed, layers: layers)
        case .townLife:
            return town(stage: stage, seed: seed, layers: layers)
        case .gameTick:
            return CompanionLocationWeather.forOldSchool(stage: stage).plan(stage: stage, seed: seed)
        case .isometricDaylight:
            return diorama(stage: stage, seed: seed)
        case .blockyBiome:
            return CompanionBiome.forMinecraft(stage: stage).plan(stage: stage, seed: seed)
        }
    }

    /// Every emitter, band, light, and population this plan owns. Used by
    /// tests to prove no two worlds animate with the same set of effects.
    var effectKeys: Set<String> {
        Set(fields.map(\.key))
            .union(bands.map(\.key))
            .union(glows.map(\.key))
            .union(actors.map(\.key))
    }
}

// MARK: - Pokémon: a warm afternoon meadow

private extension CompanionScenePlan {
    static func meadow(stage: Int, seed: UInt64) -> CompanionScenePlan {
        var fields: [CompanionParticleField] = [
            CompanionParticleField(
                key: "pokemon/pollen",
                shape: .mote,
                tint: CompanionSceneTint(1.0, 0.96, 0.80),
                count: 15,
                lifetime: 11,
                spawnX: 0.02...0.98,
                spawnY: 0.42...0.96,
                size: 1.8...3.4,
                opacity: 0.28...0.55,
                drift: .travel(dx: 0.10, dy: -0.45, sway: 0.020, swayPeriod: 5.3)
            ),
            // Something is always crossing the sky over a Kanto route.
            CompanionParticleField(
                key: "pokemon/flight",
                shape: .chevron,
                tint: CompanionSceneTint(0.22, 0.24, 0.30),
                count: 3,
                lifetime: 21,
                spawnX: -0.18...(-0.04),
                spawnY: 0.06...0.26,
                size: 2.6...3.8,
                opacity: 0.40...0.65,
                drift: .travel(dx: 1.34, dy: 0.05, sway: 0.018, swayPeriod: 4.9)
            )
        ]
        // Victory Road and the Plateau catch the light differently: the air
        // itself starts to sparkle as the journey closes.
        if stage >= 9 {
            fields.append(
                CompanionParticleField(
                    key: "pokemon/sparks",
                    shape: .ember,
                    tint: CompanionSceneTint(1.0, 0.93, 0.62),
                    count: 6,
                    lifetime: 4.2,
                    spawnX: 0.05...0.95,
                    spawnY: 0.14...0.70,
                    size: 1.4...2.6,
                    opacity: 0.30...0.60,
                    drift: .fixed,
                    fade: .twinkle(period: 2.6)
                )
            )
        }
        return CompanionScenePlan(
            signature: .creatureIdle,
            stage: stage,
            seed: seed,
            backgroundDrift: .still,
            fields: fields,
            bands: [],
            glows: [],
            actors: [
                // A route is never empty for long. Something small glides in,
                // lands in the grass beside the partner, and moves on — and
                // the partner stands up to watch it while it is there.
                CompanionActorField(
                    key: "pokemon/visitor",
                    body: .flier,
                    count: 1,
                    route: .perch(
                        at: CompanionScenePoint(0.30, 0.925),
                        approachFrom: CompanionScenePoint(-0.20, 0.42),
                        period: 27,
                        perchShare: 0.44
                    ),
                    height: 5.0...5.8,
                    tint: CompanionSceneTint(0.20, 0.22, 0.28),
                    accent: CompanionSceneTint(0.94, 0.78, 0.32),
                    opacity: 0.92,
                    spread: 0.12,
                    drawsAttention: true
                )
            ],
            wash: CompanionWashSpec(
                tint: CompanionSceneTint(1.0, 0.86, 0.62),
                opacity: 0.012,
                amplitude: 0.012,
                period: 24
            )
        )
    }
}

// MARK: - Forest: wind, and what the wind carries

private extension CompanionScenePlan {
    static func woodland(
        stage: Int,
        seed: UInt64,
        layers: [CompanionSceneLayer]
    ) -> CompanionScenePlan {
        // The plates warm from spring green toward a golden old-growth
        // evening, so what falls out of the canopy warms with them.
        let leaf: CompanionSceneTint
        switch stage {
        case 0...5: leaf = CompanionSceneTint(0.44, 0.62, 0.30)
        case 6...8: leaf = CompanionSceneTint(0.36, 0.54, 0.26)
        default: leaf = CompanionSceneTint(0.80, 0.62, 0.26)
        }

        var fields: [CompanionParticleField] = [
            CompanionParticleField(
                key: "forest/leaves",
                shape: .leaf,
                tint: leaf,
                count: 12,
                lifetime: 8.5,
                spawnX: 0.02...0.98,
                spawnY: 0.26...0.62,
                size: 1.8...3.0,
                opacity: 0.55...0.92,
                drift: .travel(dx: 0.16, dy: 0.36, sway: 0.045, swayPeriod: 3.1),
                // The canopy sheds where the wind is, not evenly over the
                // whole wood: a gust arrives and takes leaves with it.
                coupling: .gust,
                snapsToPixelGrid: true
            ),
            CompanionParticleField(
                key: "forest/seeds",
                shape: .pixel,
                tint: CompanionSceneTint(1.0, 0.98, 0.86),
                count: 10,
                lifetime: 13,
                spawnX: 0.0...1.0,
                spawnY: 0.50...0.96,
                size: 1.0...1.8,
                opacity: 0.18...0.38,
                drift: .travel(dx: 0.08, dy: -0.18, sway: 0.020, swayPeriod: 6.7),
                snapsToPixelGrid: true
            ),
            CompanionParticleField(
                key: "forest/flock",
                shape: .chevron,
                tint: CompanionSceneTint(0.20, 0.26, 0.22),
                count: 4,
                lifetime: 23,
                spawnX: -0.22...(-0.02),
                spawnY: 0.05...0.30,
                size: 2.4...3.4,
                opacity: 0.50...0.80,
                drift: .travel(dx: 1.36, dy: 0.06, sway: 0.020, swayPeriod: 5.1),
                snapsToPixelGrid: true
            )
        ]
        // The ancient stages hold their light late; that is when the clearing
        // fills with fireflies.
        if stage >= 9 {
            fields.append(
                CompanionParticleField(
                    key: "forest/fireflies",
                    shape: .ember,
                    tint: CompanionSceneTint(1.0, 0.94, 0.55),
                    count: 9,
                    lifetime: 9,
                    spawnX: 0.05...0.95,
                    spawnY: 0.62...0.94,
                    size: 1.4...2.4,
                    opacity: 0.45...0.85,
                    drift: .travel(dx: 0.05, dy: -0.06, sway: 0.030, swayPeriod: 4.1),
                    fade: .twinkle(period: 2.2),
                    snapsToPixelGrid: true
                )
            )
        }
        return CompanionScenePlan(
            signature: .windGusts,
            stage: stage,
            seed: seed,
            backgroundDrift: .still,
            fields: fields,
            bands: [],
            glows: [],
            actors: roosts(in: layers) + deer(stage: stage),
            wash: nil
        )
    }

    /// Birds land in the crowns the layout actually grew, so a roost can
    /// never hang in open sky — and a young grove has nothing tall enough
    /// to hold one.
    static func roosts(in layers: [CompanionSceneLayer]) -> [CompanionActorField] {
        let crowns = layers
            .filter { $0.role == .tree && $0.bottomOffset < 0.145 && $0.relativeHeight > 0.42 }
            .sorted { $0.relativeHeight > $1.relativeHeight }
            .prefix(2)
        return crowns.enumerated().map { index, tree in
            let crown = (1 - tree.bottomOffset) - tree.relativeHeight * 0.86
            return CompanionActorField(
                key: "forest/roost/\(index)",
                body: .flier,
                count: 1,
                route: .perch(
                    at: CompanionScenePoint(tree.horizontalPosition, crown),
                    approachFrom: CompanionScenePoint(
                        index.isMultiple(of: 2) ? -0.18 : 1.18,
                        0.16
                    ),
                    period: 23 + Double(index) * 7,
                    perchShare: 0.52
                ),
                height: 4.4...5.2,
                tint: CompanionSceneTint(0.16, 0.20, 0.17),
                accent: CompanionSceneTint(0.62, 0.42, 0.22),
                opacity: 0.95,
                spread: 0.012,
                snapsToPixelGrid: true
            )
        }
    }

    /// Deer only work a wood that has closed over: a grove of saplings has
    /// nothing to browse and nowhere to hide.
    static func deer(stage: Int) -> [CompanionActorField] {
        guard stage >= 4 else { return [] }
        return [
            CompanionActorField(
                key: "forest/deer",
                body: .quadruped,
                count: stage >= 8 ? 2 : 1,
                route: .patrol(
                    from: CompanionScenePoint(-0.14, 0.930),
                    to: CompanionScenePoint(1.14, 0.930),
                    period: 62,
                    pauses: 3
                ),
                height: 7.0...8.4,
                tint: CompanionSceneTint(0.46, 0.31, 0.19),
                accent: CompanionSceneTint(0.62, 0.45, 0.29),
                opacity: 0.96,
                spread: 0.02,
                snapsToPixelGrid: true
            )
        ]
    }
}

// MARK: - Village: chimneys by day, traffic and stars by night

private extension CompanionScenePlan {
    static func town(
        stage: Int,
        seed: UInt64,
        layers: [CompanionSceneLayer]
    ) -> CompanionScenePlan {
        let night = stage >= CompanionAssetCatalog.villageNightStageThreshold
        var fields = chimneys(over: layers, night: night)

        if night {
            fields.append(contentsOf: [
                CompanionParticleField(
                    key: "village/stars",
                    shape: .pixel,
                    tint: CompanionSceneTint(1.0, 1.0, 0.95),
                    count: 14,
                    lifetime: 10,
                    spawnX: 0.02...0.98,
                    spawnY: 0.03...0.32,
                    size: 1.0...1.8,
                    opacity: 0.35...0.75,
                    drift: .fixed,
                    fade: .twinkle(period: 3.4),
                    snapsToPixelGrid: true
                ),
                // Headlights run with the near lane, tail lights against it.
                CompanionParticleField(
                    key: "village/headlights",
                    shape: .streak,
                    tint: CompanionSceneTint(1.0, 0.98, 0.90),
                    count: 3,
                    lifetime: 9.5,
                    spawnX: -0.12...(-0.08),
                    spawnY: 0.898...0.906,
                    size: 2.6...3.6,
                    opacity: 0.70...0.95,
                    drift: .travel(dx: 1.28, dy: 0, sway: 0, swayPeriod: 1),
                    snapsToPixelGrid: true
                ),
                CompanionParticleField(
                    key: "village/taillights",
                    shape: .streak,
                    tint: CompanionSceneTint(1.0, 0.26, 0.20),
                    count: 3,
                    lifetime: 11.5,
                    spawnX: 1.08...1.12,
                    spawnY: 0.952...0.960,
                    size: 2.2...3.0,
                    opacity: 0.65...0.90,
                    drift: .travel(dx: -1.28, dy: 0, sway: 0, swayPeriod: 1),
                    snapsToPixelGrid: true
                )
            ])
        } else {
            fields.append(
                CompanionParticleField(
                    key: "village/birds",
                    shape: .chevron,
                    tint: CompanionSceneTint(0.22, 0.24, 0.28),
                    count: 3,
                    lifetime: 26,
                    spawnX: -0.14...(-0.04),
                    spawnY: 0.10...0.24,
                    size: 2.8...3.8,
                    opacity: 0.42...0.68,
                    drift: .travel(dx: 1.3, dy: 0.04, sway: 0.012, swayPeriod: 5.5)
                )
            )
        }

        return CompanionScenePlan(
            signature: .townLife,
            stage: stage,
            seed: seed,
            backgroundDrift: .still,
            fields: fields,
            bands: night
                ? []
                : [CompanionShadowBandField(
                    key: "village/cloud-shadow",
                    count: 1,
                    width: 0.5,
                    skew: 0.06,
                    period: 44,
                    opacity: 0.10,
                    tint: CompanionSceneTint(0.10, 0.14, 0.24),
                    top: 0.55,
                    bottom: 1
                )],
            glows: [],
            actors: night ? nightStreet(stage: stage) : dayStreet(over: layers),
            wash: nil
        )
    }

    /// Daytime belongs to the street: people running errands along the front,
    /// a stray working the same route, and a bird that keeps coming back to
    /// the same roof.
    static func dayStreet(over layers: [CompanionSceneLayer]) -> [CompanionActorField] {
        var population: [CompanionActorField] = [
            CompanionActorField(
                key: "village/townsfolk",
                body: .biped,
                count: 4,
                route: .patrol(
                    from: CompanionScenePoint(-0.12, 0.952),
                    to: CompanionScenePoint(1.12, 0.952),
                    period: 34,
                    pauses: 1
                ),
                height: 8.6...10.2,
                tint: CompanionSceneTint(0.36, 0.32, 0.46),
                accent: CompanionSceneTint(0.86, 0.70, 0.55),
                opacity: 1,
                spread: 0.05,
                snapsToPixelGrid: true
            ),
            CompanionActorField(
                key: "village/stray",
                body: .quadruped,
                count: 1,
                route: .patrol(
                    from: CompanionScenePoint(1.10, 0.962),
                    to: CompanionScenePoint(-0.10, 0.962),
                    period: 27,
                    pauses: 2
                ),
                height: 4.2...4.8,
                tint: CompanionSceneTint(0.44, 0.34, 0.24),
                accent: CompanionSceneTint(0.58, 0.47, 0.34),
                opacity: 1,
                spread: 0.01,
                snapsToPixelGrid: true
            )
        ]
        if let roof = rooftop(over: layers) {
            population.append(roof)
        }
        return population
    }

    /// A bird that lands on a roof the scene actually built.
    static func rooftop(over layers: [CompanionSceneLayer]) -> CompanionActorField? {
        guard let building = layers
            .filter({ $0.role == .building && $0.bottomOffset < 0.145 })
            .max(by: { $0.relativeHeight < $1.relativeHeight })
        else { return nil }
        let ridge = max(0.04, (1 - building.bottomOffset) - building.relativeHeight)
        return CompanionActorField(
            key: "village/rooftop-bird",
            body: .flier,
            count: 1,
            route: .perch(
                at: CompanionScenePoint(building.horizontalPosition, ridge),
                approachFrom: CompanionScenePoint(1.18, 0.12),
                period: 31,
                perchShare: 0.5
            ),
            height: 4.2...5.0,
            tint: CompanionSceneTint(0.22, 0.24, 0.30),
            accent: CompanionSceneTint(0.80, 0.66, 0.30),
            opacity: 0.95,
            spread: 0.015,
            snapsToPixelGrid: true
        )
    }

    /// After dark the street empties out. What is left walks home under the
    /// lights, and the traffic has the road to itself.
    static func nightStreet(stage: Int) -> [CompanionActorField] {
        [
            CompanionActorField(
                key: "village/late-walkers",
                body: .biped,
                count: stage >= 10 ? 3 : 2,
                route: .patrol(
                    from: CompanionScenePoint(-0.12, 0.952),
                    to: CompanionScenePoint(1.12, 0.952),
                    period: 30,
                    pauses: 0
                ),
                height: 9.0...10.6,
                // Lit from the street rather than the sun, but still legible
                // against a dark road.
                tint: CompanionSceneTint(0.34, 0.33, 0.44),
                accent: CompanionSceneTint(0.74, 0.63, 0.52),
                opacity: 0.95,
                spread: 0.05,
                snapsToPixelGrid: true
            )
        ]
    }

    /// Smoke rises from the roofs the scene actually placed, so a chimney
    /// plume can never appear over open ground.
    static func chimneys(
        over layers: [CompanionSceneLayer],
        night: Bool
    ) -> [CompanionParticleField] {
        let streetfront = layers
            .filter { $0.role == .building && $0.bottomOffset < 0.145 }
            .sorted { $0.horizontalPosition < $1.horizontalPosition }
        guard !streetfront.isEmpty else { return [] }

        let wanted = min(3, streetfront.count)
        let chosen = (0..<wanted).map { index -> CompanionSceneLayer in
            let position = wanted == 1
                ? streetfront.count / 2
                : index * (streetfront.count - 1) / max(1, wanted - 1)
            return streetfront[position]
        }

        return chosen.enumerated().map { index, layer in
            let roof = max(0.02, (1 - layer.bottomOffset) - layer.relativeHeight)
            return CompanionParticleField(
                key: "village/smoke/\(index)",
                shape: .pixel,
                tint: night
                    ? CompanionSceneTint(0.46, 0.45, 0.55)
                    : CompanionSceneTint(0.60, 0.60, 0.64),
                count: 9,
                lifetime: 6.4,
                spawnX: (layer.horizontalPosition - 0.006)...(layer.horizontalPosition + 0.006),
                spawnY: max(0.0, roof - 0.02)...roof,
                size: 1.6...2.6,
                opacity: night ? 0.24...0.38 : 0.40...0.60,
                drift: .travel(dx: 0.075, dy: -0.34, sway: 0.014, swayPeriod: 4.3),
                fade: .rise,
                growth: 2.2,
                snapsToPixelGrid: true
            )
        }
    }
}

// MARK: - Age of Empires II: a diorama under a moving sky

private extension CompanionScenePlan {
    static func diorama(stage: Int, seed: UInt64) -> CompanionScenePlan {
        CompanionScenePlan(
            signature: .isometricDaylight,
            stage: stage,
            seed: seed,
            backgroundDrift: .isometricWander,
            fields: [
                CompanionParticleField(
                    key: "aoe/dust",
                    shape: .mote,
                    tint: CompanionSceneTint(1.0, 0.93, 0.72),
                    count: 16,
                    lifetime: 15,
                    spawnX: 0.0...1.0,
                    spawnY: 0.20...0.96,
                    size: 1.2...2.6,
                    opacity: 0.13...0.26,
                    drift: .travel(dx: 0.10, dy: -0.16, sway: 0.020, swayPeriod: 7.3)
                ),
                // Two flocks at different heights and speeds: the map is
                // read from above, so birds crossing it are the one moving
                // thing an isometric town always has.
                CompanionParticleField(
                    key: "aoe/birds",
                    shape: .chevron,
                    tint: CompanionSceneTint(0.14, 0.14, 0.12),
                    count: 4,
                    lifetime: 24,
                    spawnX: -0.22...(-0.04),
                    spawnY: 0.10...0.42,
                    size: 3.0...4.2,
                    opacity: 0.50...0.75,
                    drift: .travel(dx: 1.40, dy: 0.10, sway: 0.024, swayPeriod: 6.4)
                ),
                CompanionParticleField(
                    key: "aoe/birds-high",
                    shape: .chevron,
                    tint: CompanionSceneTint(0.18, 0.18, 0.16),
                    count: 3,
                    lifetime: 37,
                    spawnX: 1.06...1.22,
                    spawnY: 0.04...0.20,
                    size: 2.0...2.8,
                    opacity: 0.30...0.48,
                    drift: .travel(dx: -1.40, dy: 0.06, sway: 0.018, swayPeriod: 8.1)
                )
            ],
            bands: [
                // Leaning along the tile diagonal, the way anything that
                // crosses an isometric map has to.
                CompanionShadowBandField(
                    key: "aoe/cloud-shadows",
                    count: 2,
                    width: 0.55,
                    skew: -0.30,
                    period: 38,
                    opacity: 0.115,
                    tint: CompanionSceneTint(0.04, 0.05, 0.09),
                    top: 0,
                    bottom: 1
                )
            ],
            glows: [],
            actors: settlement(stage: stage),
            wash: CompanionWashSpec(
                tint: CompanionSceneTint(1.0, 0.88, 0.62),
                opacity: 0.010,
                amplitude: 0.014,
                period: 41
            )
        )
    }

    /// The near foreground of an isometric map is the one band a unit can
    /// cross without walking through a building, so that is where the town's
    /// own people work. A settlement gets busier as it ages.
    static func settlement(stage: Int) -> [CompanionActorField] {
        [
            // The loop every Age of Empires villager has run since 1999:
            // out to the trees, chop, carry it home, go again.
            CompanionActorField(
                key: "aoe/villagers",
                body: .biped,
                count: min(6, 2 + stage / 2),
                route: .errand(
                    home: CompanionScenePoint(0.36, 0.958),
                    site: CompanionScenePoint(0.72, 0.918),
                    period: 24,
                    workShare: 0.34
                ),
                height: 9.5...11.5,
                tint: CompanionSceneTint(0.40, 0.26, 0.58),
                accent: CompanionSceneTint(0.78, 0.62, 0.47),
                opacity: 0.94,
                spread: 0.22
            ),
            // A herd stays near the town centre and never gets anywhere.
            CompanionActorField(
                key: "aoe/herd",
                body: .quadruped,
                count: 3,
                route: .wander(
                    pen: CompanionScenePoint(0.16, 0.950),
                    spanX: 0.075,
                    spanY: 0.012,
                    period: 31,
                    linger: 0.62
                ),
                height: 7.0...8.5,
                tint: CompanionSceneTint(0.90, 0.87, 0.80),
                accent: CompanionSceneTint(0.36, 0.31, 0.27),
                opacity: 0.94,
                spread: 0.09
            )
        ]
    }
}

// MARK: - Old School RuneScape: the weather of each location

/// The adventurer always moves on the game tick; what surrounds them belongs
/// to where they are standing. A desert does not get cloud shadows and a tomb
/// does not get birds.
enum CompanionLocationWeather: String, CaseIterable, Equatable, Sendable {
    case openAir
    case desert
    case gloom
    case snow
    case crystal
    case torchlit

    /// Stage order: Lumbridge, Al Kharid, Varrock, Karamja, Grand Exchange,
    /// Falador, Seers' Village, East Ardougne, Canifis, God Wars, Prifddinas,
    /// Tombs of Amascut.
    static func forOldSchool(stage: Int) -> CompanionLocationWeather {
        switch stage {
        case 1: .desert
        case 8: .gloom
        case 9: .snow
        case 10: .crystal
        case 11: .torchlit
        default: .openAir
        }
    }

    func plan(stage: Int, seed: UInt64) -> CompanionScenePlan {
        CompanionScenePlan(
            signature: .gameTick,
            stage: stage,
            seed: seed,
            backgroundDrift: .still,
            fields: fields,
            bands: bands,
            glows: glows,
            actors: CompanionOldSchoolCrowd.population(stage: stage),
            wash: wash
        )
    }

    private var fields: [CompanionParticleField] {
        switch self {
        case .openAir:
            [CompanionParticleField(
                key: "osrs/birds",
                shape: .chevron,
                tint: CompanionSceneTint(0.18, 0.18, 0.16),
                count: 2,
                lifetime: 24,
                spawnX: -0.16...(-0.05),
                spawnY: 0.08...0.30,
                size: 2.6...3.6,
                opacity: 0.45...0.72,
                drift: .travel(dx: 1.32, dy: 0.06, sway: 0.015, swayPeriod: 6.1)
            )]
        case .desert:
            [CompanionParticleField(
                key: "osrs/sand",
                shape: .mote,
                tint: CompanionSceneTint(0.92, 0.82, 0.58),
                count: 14,
                lifetime: 7.5,
                spawnX: -0.10...0.55,
                spawnY: 0.35...0.96,
                size: 1.4...2.8,
                opacity: 0.16...0.32,
                drift: .travel(dx: 0.62, dy: -0.05, sway: 0.020, swayPeriod: 3.3)
            )]
        case .gloom:
            [CompanionParticleField(
                key: "osrs/gloom",
                shape: .mote,
                tint: CompanionSceneTint(0.72, 0.78, 0.90),
                count: 9,
                lifetime: 12,
                spawnX: 0.05...0.95,
                spawnY: 0.50...0.96,
                size: 1.4...2.6,
                opacity: 0.18...0.34,
                drift: .travel(dx: 0.04, dy: -0.12, sway: 0.030, swayPeriod: 5.9)
            )]
        case .snow:
            [CompanionParticleField(
                key: "osrs/snow",
                shape: .pixel,
                tint: CompanionSceneTint(1.0, 1.0, 1.0),
                count: 22,
                lifetime: 6.4,
                spawnX: -0.05...1.05,
                spawnY: -0.06...0.08,
                size: 1.2...2.2,
                opacity: 0.35...0.75,
                drift: .travel(dx: 0.12, dy: 1.08, sway: 0.035, swayPeriod: 3.7)
            )]
        case .crystal:
            [CompanionParticleField(
                key: "osrs/crystal",
                shape: .ember,
                tint: CompanionSceneTint(0.75, 0.92, 1.0),
                count: 12,
                lifetime: 6.8,
                spawnX: 0.05...0.95,
                spawnY: 0.55...0.98,
                size: 1.4...2.6,
                opacity: 0.35...0.70,
                drift: .travel(dx: 0.02, dy: -0.35, sway: 0.020, swayPeriod: 4.4)
            )]
        case .torchlit:
            [CompanionParticleField(
                key: "osrs/tomb-dust",
                shape: .mote,
                tint: CompanionSceneTint(0.95, 0.86, 0.70),
                count: 12,
                lifetime: 11,
                spawnX: 0.05...0.95,
                spawnY: 0.30...0.96,
                size: 1.2...2.4,
                opacity: 0.14...0.28,
                drift: .travel(dx: 0.05, dy: -0.20, sway: 0.025, swayPeriod: 6.3)
            )]
        }
    }

    private var bands: [CompanionShadowBandField] {
        switch self {
        case .openAir:
            [CompanionShadowBandField(
                key: "osrs/cloud-shadow",
                count: 1,
                width: 0.62,
                skew: 0.08,
                period: 34,
                opacity: 0.13,
                tint: CompanionSceneTint(0.02, 0.03, 0.06),
                top: 0,
                bottom: 1
            )]
        case .gloom:
            [CompanionShadowBandField(
                key: "osrs/mist",
                count: 2,
                width: 0.60,
                skew: 0,
                period: 41,
                opacity: 0.12,
                tint: CompanionSceneTint(0.74, 0.72, 0.88),
                top: 0.45,
                bottom: 1
            )]
        case .desert, .snow, .crystal, .torchlit:
            []
        }
    }

    private var glows: [CompanionGlowSpec] {
        guard self == .torchlit else { return [] }
        return [
            CompanionGlowSpec(
                key: "osrs/torch-left",
                x: 0.12,
                y: 0.42,
                radius: 22,
                tint: CompanionSceneTint(1.0, 0.72, 0.34),
                opacity: 0.21,
                flickerDepth: 0.45,
                flickerPeriod: 2.3
            ),
            CompanionGlowSpec(
                key: "osrs/torch-right",
                x: 0.88,
                y: 0.40,
                radius: 22,
                tint: CompanionSceneTint(1.0, 0.72, 0.34),
                opacity: 0.21,
                flickerDepth: 0.45,
                flickerPeriod: 2.9
            )
        ]
    }

    private var wash: CompanionWashSpec? {
        switch self {
        case .desert:
            CompanionWashSpec(
                tint: CompanionSceneTint(1.0, 0.86, 0.55),
                opacity: 0.020,
                amplitude: 0.012,
                period: 19
            )
        case .crystal:
            CompanionWashSpec(
                tint: CompanionSceneTint(0.70, 0.90, 1.0),
                opacity: 0.012,
                amplitude: 0.012,
                period: 17
            )
        case .openAir, .gloom, .snow, .torchlit:
            nil
        }
    }
}

// MARK: - Minecraft: the particle the biome actually emits

/// Every Minecraft particle is a hard square. What kind of square depends
/// entirely on where the survivor is standing.
enum CompanionBiome: String, CaseIterable, Equatable, Sendable {
    case plains
    case forest
    case village
    case lushCaves
    case jaggedPeaks
    case ancientCity
    case netherWastes
    case crimsonForest
    case netherFortress
    case stronghold
    case theEnd
    case endCity

    static func forMinecraft(stage: Int) -> CompanionBiome {
        let order: [CompanionBiome] = [
            .plains, .forest, .village, .lushCaves,
            .jaggedPeaks, .ancientCity, .netherWastes, .crimsonForest,
            .netherFortress, .stronghold, .theEnd, .endCity
        ]
        return order[min(max(stage, 0), order.count - 1)]
    }

    func plan(stage: Int, seed: UInt64) -> CompanionScenePlan {
        CompanionScenePlan(
            signature: .blockyBiome,
            stage: stage,
            seed: seed,
            backgroundDrift: .still,
            fields: fields,
            bands: [],
            glows: glows,
            actors: mobs,
            wash: wash
        )
    }

    /// The mob that actually spawns here. Three of these biomes are silent on
    /// purpose — an ancient city, the End, and a fortress corridor are places
    /// whose whole character is that nothing is wandering through them.
    private var mobs: [CompanionActorField] {
        switch self {
        case .plains:
            [mob(
                key: "mc/chickens",
                body: .quadruped,
                count: 3,
                height: 4.6...5.4,
                tint: CompanionSceneTint(0.94, 0.94, 0.92),
                accent: CompanionSceneTint(0.95, 0.68, 0.18),
                pen: CompanionScenePoint(0.66, 0.944),
                spanX: 0.11,
                period: 15,
                spread: 0.12
            )]
        case .forest:
            [mob(
                key: "mc/pigs",
                body: .quadruped,
                count: 2,
                height: 9.0...10.5,
                tint: CompanionSceneTint(0.93, 0.62, 0.64),
                accent: CompanionSceneTint(0.78, 0.44, 0.47),
                pen: CompanionScenePoint(0.68, 0.936),
                spanX: 0.13,
                period: 21,
                spread: 0.14
            )]
        case .village:
            [mob(
                key: "mc/villagers",
                body: .biped,
                count: 3,
                height: 12.0...13.6,
                tint: CompanionSceneTint(0.45, 0.32, 0.24),
                accent: CompanionSceneTint(0.76, 0.60, 0.49),
                pen: CompanionScenePoint(0.62, 0.944),
                spanX: 0.12,
                period: 24,
                spread: 0.18
            )]
        case .lushCaves:
            [mob(
                key: "mc/bats",
                body: .flier,
                count: 3,
                height: 4.0...5.0,
                tint: CompanionSceneTint(0.28, 0.22, 0.24),
                accent: CompanionSceneTint(0.42, 0.34, 0.36),
                pen: CompanionScenePoint(0.5, 0.42),
                spanX: 0.24,
                spanY: 0.14,
                period: 13,
                linger: 0.2,
                spread: 0.16,
                drawsAttention: false
            )]
        case .jaggedPeaks:
            [mob(
                key: "mc/goats",
                body: .quadruped,
                count: 1,
                height: 9.5...11.0,
                tint: CompanionSceneTint(0.92, 0.90, 0.86),
                accent: CompanionSceneTint(0.55, 0.50, 0.46),
                pen: CompanionScenePoint(0.72, 0.932),
                spanX: 0.10,
                period: 26,
                spread: 0.05
            )]
        case .netherWastes:
            [mob(
                key: "mc/piglins",
                body: .biped,
                count: 2,
                height: 12.0...13.6,
                tint: CompanionSceneTint(0.55, 0.34, 0.26),
                accent: CompanionSceneTint(0.92, 0.63, 0.60),
                pen: CompanionScenePoint(0.62, 0.944),
                spanX: 0.11,
                period: 22,
                spread: 0.16
            )]
        case .crimsonForest:
            [mob(
                key: "mc/hoglins",
                body: .quadruped,
                count: 2,
                height: 10.5...12.0,
                tint: CompanionSceneTint(0.62, 0.27, 0.24),
                accent: CompanionSceneTint(0.40, 0.17, 0.16),
                pen: CompanionScenePoint(0.64, 0.936),
                spanX: 0.12,
                period: 19,
                spread: 0.15
            )]
        case .stronghold:
            [mob(
                key: "mc/silverfish",
                body: .quadruped,
                count: 2,
                height: 3.4...4.0,
                tint: CompanionSceneTint(0.55, 0.57, 0.62),
                accent: CompanionSceneTint(0.34, 0.36, 0.40),
                pen: CompanionScenePoint(0.72, 0.952),
                spanX: 0.14,
                period: 11,
                linger: 0.85,
                spread: 0.12
            )]
        case .ancientCity, .netherFortress, .theEnd, .endCity:
            []
        }
    }

    /// One wandering population, described the way a biome differs from its
    /// neighbours: what lives here, how many, how big, and how restless.
    private func mob(
        key: String,
        body: CompanionActorBody,
        count: Int,
        height: ClosedRange<Double>,
        tint: CompanionSceneTint,
        accent: CompanionSceneTint,
        pen: CompanionScenePoint,
        spanX: Double,
        spanY: Double = 0.012,
        period: Double,
        linger: Double = 0.55,
        spread: Double,
        drawsAttention: Bool = true
    ) -> CompanionActorField {
        CompanionActorField(
            key: key,
            body: body,
            count: count,
            route: .wander(
                pen: pen,
                spanX: spanX,
                spanY: spanY,
                period: period,
                linger: linger
            ),
            height: height,
            tint: tint,
            accent: accent,
            opacity: 1,
            spread: spread,
            drawsAttention: drawsAttention
        )
    }

    private var fields: [CompanionParticleField] {
        switch self {
        case .plains:
            [pollen(key: "mc/plains-pollen", count: 12)]
        case .forest:
            [falling(
                key: "mc/forest-leaves",
                tint: CompanionSceneTint(0.30, 0.55, 0.22),
                count: 14,
                lifetime: 7,
                opacity: 0.40...0.75
            )]
        case .village:
            [
                pollen(key: "mc/village-pollen", count: 9),
                falling(
                    key: "mc/village-leaves",
                    tint: CompanionSceneTint(0.42, 0.62, 0.26),
                    count: 6,
                    lifetime: 8.5,
                    opacity: 0.30...0.55
                )
            ]
        case .lushCaves:
            [
                CompanionParticleField(
                    key: "mc/cave-drips",
                    shape: .pixel,
                    tint: CompanionSceneTint(0.35, 0.62, 0.95),
                    count: 14,
                    lifetime: 2.6,
                    spawnX: 0.03...0.97,
                    spawnY: -0.02...0.25,
                    size: 1.2...1.8,
                    opacity: 0.45...0.80,
                    drift: .travel(dx: 0, dy: 1.05, sway: 0, swayPeriod: 1)
                ),
                CompanionParticleField(
                    key: "mc/glow-berries",
                    shape: .pixel,
                    tint: CompanionSceneTint(1.0, 0.72, 0.28),
                    count: 8,
                    lifetime: 9,
                    spawnX: 0.03...0.97,
                    spawnY: 0.02...0.35,
                    size: 1.4...2.2,
                    opacity: 0.30...0.60,
                    drift: .fixed,
                    fade: .twinkle(period: 3.1)
                )
            ]
        case .jaggedPeaks:
            [CompanionParticleField(
                key: "mc/peak-snow",
                shape: .pixel,
                tint: CompanionSceneTint(1.0, 1.0, 1.0),
                count: 34,
                lifetime: 6.2,
                spawnX: -0.06...1.06,
                spawnY: -0.06...0.06,
                size: 1.6...2.8,
                opacity: 0.40...0.85,
                drift: .travel(dx: 0.18, dy: 1.10, sway: 0.05, swayPeriod: 4.1)
            )]
        case .ancientCity:
            [CompanionParticleField(
                key: "mc/sculk",
                shape: .pixel,
                tint: CompanionSceneTint(0.20, 0.85, 0.80),
                count: 12,
                lifetime: 9,
                spawnX: 0.04...0.96,
                spawnY: 0.45...0.98,
                size: 1.2...2.4,
                opacity: 0.35...0.68,
                drift: .travel(dx: 0.02, dy: -0.50, sway: 0.020, swayPeriod: 5.2)
            )]
        case .netherWastes, .netherFortress:
            [
                CompanionParticleField(
                    key: "mc/embers",
                    shape: .pixel,
                    tint: CompanionSceneTint(1.0, 0.55, 0.18),
                    count: 22,
                    lifetime: 7.5,
                    spawnX: 0.02...0.98,
                    spawnY: 0.60...1.02,
                    size: 1.2...2.6,
                    opacity: 0.50...0.95,
                    drift: .travel(dx: 0.05, dy: -0.85, sway: 0.030, swayPeriod: 3.9),
                    fade: .rise
                ),
                CompanionParticleField(
                    key: "mc/ash",
                    shape: .pixel,
                    tint: CompanionSceneTint(0.42, 0.32, 0.28),
                    count: 12,
                    lifetime: 11,
                    spawnX: 0.02...0.98,
                    spawnY: -0.05...0.30,
                    size: 1.2...2.0,
                    opacity: 0.32...0.60,
                    drift: .travel(dx: -0.06, dy: 1.10, sway: 0.040, swayPeriod: 5.5)
                )
            ]
        case .crimsonForest:
            [CompanionParticleField(
                key: "mc/crimson-spores",
                shape: .pixel,
                tint: CompanionSceneTint(0.85, 0.22, 0.30),
                count: 20,
                lifetime: 9.5,
                spawnX: 0.02...0.98,
                spawnY: -0.05...0.40,
                size: 1.2...2.4,
                opacity: 0.45...0.82,
                drift: .travel(dx: 0.05, dy: 1.05, sway: 0.050, swayPeriod: 4.7)
            )]
        case .stronghold:
            [CompanionParticleField(
                key: "mc/stronghold-dust",
                shape: .pixel,
                tint: CompanionSceneTint(0.90, 0.85, 0.70),
                count: 12,
                lifetime: 13,
                spawnX: 0.03...0.97,
                spawnY: 0.25...0.96,
                size: 1.2...2.0,
                opacity: 0.20...0.40,
                drift: .travel(dx: 0.05, dy: -0.15, sway: 0.030, swayPeriod: 6.6)
            )]
        case .theEnd:
            [endMotes(key: "mc/end-motes", count: 16)]
        case .endCity:
            [
                endMotes(key: "mc/end-city-motes", count: 12),
                CompanionParticleField(
                    key: "mc/end-rods",
                    shape: .pixel,
                    tint: CompanionSceneTint(1.0, 0.98, 0.94),
                    count: 8,
                    lifetime: 8,
                    spawnX: 0.05...0.95,
                    spawnY: 0.18...0.70,
                    size: 1.2...2.0,
                    opacity: 0.30...0.60,
                    drift: .fixed,
                    fade: .twinkle(period: 2.8)
                )
            ]
        }
    }

    private var glows: [CompanionGlowSpec] {
        switch self {
        case .ancientCity:
            [CompanionGlowSpec(
                key: "mc/lava-fall",
                x: 0.5,
                y: 0.86,
                radius: 26,
                tint: CompanionSceneTint(1.0, 0.45, 0.12),
                opacity: 0.10,
                flickerDepth: 0.35,
                flickerPeriod: 3.4
            )]
        case .netherFortress:
            [CompanionGlowSpec(
                key: "mc/fortress-fire",
                x: 0.5,
                y: 0.90,
                radius: 30,
                tint: CompanionSceneTint(1.0, 0.52, 0.16),
                opacity: 0.12,
                flickerDepth: 0.40,
                flickerPeriod: 2.6
            )]
        case .stronghold:
            [
                CompanionGlowSpec(
                    key: "mc/torch-left",
                    x: 0.18,
                    y: 0.45,
                    radius: 16,
                    tint: CompanionSceneTint(1.0, 0.68, 0.30),
                    opacity: 0.14,
                    flickerDepth: 0.50,
                    flickerPeriod: 1.9
                ),
                CompanionGlowSpec(
                    key: "mc/torch-right",
                    x: 0.82,
                    y: 0.45,
                    radius: 16,
                    tint: CompanionSceneTint(1.0, 0.68, 0.30),
                    opacity: 0.14,
                    flickerDepth: 0.50,
                    flickerPeriod: 2.4
                )
            ]
        case .plains, .forest, .village, .lushCaves, .jaggedPeaks,
             .netherWastes, .crimsonForest, .theEnd, .endCity:
            []
        }
    }

    private var wash: CompanionWashSpec? {
        switch self {
        case .netherWastes, .netherFortress, .crimsonForest:
            CompanionWashSpec(
                tint: CompanionSceneTint(1.0, 0.42, 0.18),
                opacity: 0.014,
                amplitude: 0.014,
                period: 15
            )
        case .theEnd, .endCity:
            CompanionWashSpec(
                tint: CompanionSceneTint(0.55, 0.42, 0.75),
                opacity: 0.012,
                amplitude: 0.014,
                period: 21
            )
        case .plains, .forest, .village, .lushCaves, .jaggedPeaks,
             .ancientCity, .stronghold:
            nil
        }
    }

    private func pollen(key: String, count: Int) -> CompanionParticleField {
        CompanionParticleField(
            key: key,
            shape: .pixel,
            tint: CompanionSceneTint(0.95, 0.95, 0.62),
            count: count,
            lifetime: 12,
            spawnX: 0.02...0.98,
            spawnY: 0.30...0.96,
            size: 1.2...2.2,
            opacity: 0.22...0.45,
            drift: .travel(dx: 0.12, dy: -0.10, sway: 0.030, swayPeriod: 5.5)
        )
    }

    private func falling(
        key: String,
        tint: CompanionSceneTint,
        count: Int,
        lifetime: Double,
        opacity: ClosedRange<Double>
    ) -> CompanionParticleField {
        CompanionParticleField(
            key: key,
            shape: .pixel,
            tint: tint,
            count: count,
            lifetime: lifetime,
            spawnX: 0.02...0.98,
            spawnY: -0.05...0.35,
            size: 1.6...2.4,
            opacity: opacity,
            drift: .travel(dx: 0.08, dy: 1.10, sway: 0.040, swayPeriod: 3.3)
        )
    }

    private func endMotes(key: String, count: Int) -> CompanionParticleField {
        CompanionParticleField(
            key: key,
            shape: .pixel,
            tint: CompanionSceneTint(0.72, 0.55, 0.95),
            count: count,
            lifetime: 11,
            spawnX: 0.02...0.98,
            spawnY: 0.15...0.96,
            size: 1.2...2.6,
            opacity: 0.35...0.72,
            drift: .travel(dx: 0.03, dy: -0.28, sway: 0.035, swayPeriod: 6.1)
        )
    }
}


/// Who else is standing around. Old School's world is other players: a bank
/// is shoulder to shoulder and a god war is not, and everybody moves one
/// whole tile per tick or not at all.
enum CompanionOldSchoolCrowd {
    /// One tile, as a fraction of the scene's width.
    static let tile = 0.028

    /// Players per location, in stage order. The Grand Exchange is packed,
    /// a starting field is quiet, and nobody idles inside a raid.
    static let playersByStage = [3, 2, 4, 2, 6, 3, 2, 3, 2, 0, 2, 2]

    static func population(stage: Int) -> [CompanionActorField] {
        let stage = min(max(stage, 0), playersByStage.count - 1)
        var crowd: [CompanionActorField] = []
        let players = playersByStage[stage]
        if players > 0 {
            crowd.append(
                CompanionActorField(
                    key: "osrs/players",
                    body: .biped,
                    count: players,
                    route: .ticked(
                        pen: CompanionScenePoint(0.52, 0.936),
                        // Kept under one tile per tick on purpose: a step is
                        // a whole tile or it is nothing.
                        spanX: 0.070,
                        spanY: 0.020,
                        tile: tile
                    ),
                    height: 7.0...9.0,
                    tint: CompanionSceneTint(0.30, 0.34, 0.44),
                    accent: CompanionSceneTint(0.84, 0.68, 0.52),
                    opacity: 0.94,
                    spread: 0.24,
                    drawsAttention: true
                )
            )
        }
        // Lumbridge has had the same chickens in the same field for decades.
        if stage == 0 {
            crowd.append(
                CompanionActorField(
                    key: "osrs/chickens",
                    body: .quadruped,
                    count: 3,
                    route: .ticked(
                        pen: CompanionScenePoint(0.78, 0.944),
                        spanX: 0.045,
                        spanY: 0.014,
                        tile: 0.020
                    ),
                    height: 3.6...4.2,
                    tint: CompanionSceneTint(0.93, 0.90, 0.84),
                    accent: CompanionSceneTint(0.85, 0.26, 0.20),
                    opacity: 0.95,
                    spread: 0.10
                )
            )
        }
        return crowd
    }
}
