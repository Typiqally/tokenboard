import Foundation

struct CompanionSceneLayer: Equatable, Sendable, Identifiable {
    let id: String
    let resource: String
    let relativeHeight: Double
    let horizontalPosition: Double
    let bottomOffset: Double
    let castsGroundShadow: Bool
    /// What this layer is, so the scene's motion can address it by role
    /// rather than by draw order.
    let role: CompanionSubjectRole
}

struct CompanionSceneAsset: Equatable, Sendable {
    let backgroundResource: String
    let layers: [CompanionSceneLayer]
    /// Scale applied to the background plate, anchored to the ground line.
    /// Themes without subject layers use a slow push-in so a stage still
    /// visibly advances between milestones.
    let backgroundZoom: Double

    init(
        backgroundResource: String,
        layers: [CompanionSceneLayer],
        backgroundZoom: Double = 1
    ) {
        self.backgroundResource = backgroundResource
        self.layers = layers
        self.backgroundZoom = backgroundZoom
    }

    var allResources: [String] {
        [backgroundResource] + layers.map(\.resource)
    }
}

/// How a growing theme's population advances across the journey: the count
/// at each stage start, interpolated within a stage by the progress
/// fraction, so new subjects keep arriving between milestones.
struct CompanionGrowthPlan: Sendable {
    /// Population at the start of each of the eight stages.
    let stageCounts: [Int]
    /// Population when the journey completes.
    let finalCount: Int

    func population(stage: Int, fraction: Double) -> Int {
        let stage = min(max(stage, 0), stageCounts.count - 1)
        let fraction = min(max(fraction, 0), 1)
        let lower = Double(stageCounts[stage])
        let upper = Double(
            stage == stageCounts.count - 1 ? finalCount : stageCounts[stage + 1]
        )
        // The epsilon keeps `appearance(of:)` and this floor in agreement:
        // a slot is visible from exactly the progress it appears at, even
        // when the interpolation lands epsilon under a whole number.
        return Int((lower + (upper - lower) * fraction + 1e-9).rounded(.down))
    }

    /// The global journey progress (0...1 across all eight stages) at which
    /// the given slot first becomes visible. Slots that only arrive at the
    /// journey's very end report 1.
    func appearance(of slot: Int) -> Double {
        let target = slot + 1
        guard target > stageCounts[0] else { return 0 }
        let stages = Double(stageCounts.count)
        for stage in 0..<stageCounts.count {
            let lower = stageCounts[stage]
            let upper = stage == stageCounts.count - 1
                ? finalCount
                : stageCounts[stage + 1]
            if target > lower, target <= upper {
                let within = Double(target - lower) / Double(upper - lower)
                return (Double(stage) + within) / stages
            }
        }
        return 1
    }

    /// Global progress for a stage and its inner fraction.
    func globalProgress(stage: Int, fraction: Double) -> Double {
        let lastStage = stageCounts.count - 1
        return (Double(min(max(stage, 0), lastStage)) + min(max(fraction, 0), 1))
            / Double(stageCounts.count)
    }
}

/// Maps every visible theme, variant, and journey stage to the bundled
/// artwork baked by `Scripts/bake-companion-assets.swift` and
/// `Scripts/generate-companion-artwork.swift`. Every background is already
/// composed at the scene's 310 x 84 point aspect, so the catalog only places
/// subjects; it never crops at runtime.
enum CompanionAssetCatalog {
    // Generation 1-4 starter families, in `CompanionCatalog.variants` order.
    private static let pokemonEvolutionLines: [[Int]] = [
        [1, 2, 3], [4, 5, 6], [7, 8, 9],
        [152, 153, 154], [155, 156, 157], [158, 159, 160],
        [252, 253, 254], [255, 256, 257], [258, 259, 260],
        [387, 388, 389], [390, 391, 392], [393, 394, 395]
    ]

    /// Scenery variants per stage: the same place on a different day. The
    /// daily rotation picks one so consecutive days never repeat a plate.
    static let sceneryVariantCount = 3

    private static let scenerySuffixes = ["a", "b", "c"]

    // One trainer's journey through Kanto, in story order.
    private static let pokemonSceneNames = [
        "01-pallet-town", "02-viridian-forest", "03-pewter-city",
        "04-cerulean-city", "05-vermilion-city", "06-lavender-town",
        "07-celadon-city", "08-saffron-city", "09-fuchsia-city",
        "10-cinnabar-island", "11-victory-road", "12-indigo-plateau"
    ]

    // MARK: Pixel-art scene geometry

    /// The generated pixel plates use one art pixel per grid cell on a
    /// 155 x 42 grid composed for the 350 x 84 point band, so a cell spans
    /// 350 / 155 points on screen. Sprite layer heights are expressed in
    /// cells and converted through this fraction so subject pixels land at
    /// exactly the same size as background pixels.
    static let pixelGridWidth = 155.0
    static let pixelGridHeight = 42.0
    private static let cellHeightFraction = (350.0 / pixelGridWidth) / 84.0

    /// On-screen shrink applied to sprites standing in the back band.
    private static let backBandScale = 0.72

    // MARK: Forest theme

    /// Sprite heights in grid cells per species and maturity level, matching
    /// `Scripts/generate-companion-artwork.swift` (verified by tests against
    /// the baked PNG dimensions).
    static let forestSpecies = ["oak", "pine", "birch"]
    static let forestSpriteCellHeights: [String: [Int]] = [
        "oak": [6, 12, 20, 28],
        "pine": [7, 14, 22, 30],
        "birch": [6, 11, 17, 23]
    ]

    // Every stage adds at least two subjects, so growth stays visible
    // between milestones rather than landing only on stage boundaries.
    static let forestGrowthPlan = CompanionGrowthPlan(
        stageCounts: [1, 3, 5, 8, 11, 14, 18, 22, 26, 31, 36, 40],
        finalCount: 44
    )

    /// A tree matures one sprite level at each of these ages, measured in
    /// global journey progress since it appeared.
    private static let forestMaturityAges = [0.10, 0.28, 0.55]

    /// Youngest stages stay saplings and groves even for the oldest trees.
    private static let forestStageLevelCaps = [1, 1, 1, 2, 2, 2, 3, 3, 3, 3, 3, 3]

    // MARK: Village theme

    static let villageStyles = ["timber", "brick", "modern"]
    static let villageSpriteCellHeights: [String: [Int]] = [
        "timber": [11, 17, 25, 31],
        "brick": [12, 18, 27, 33],
        "modern": [10, 16, 28, 35]
    ]

    static let villageGrowthPlan = CompanionGrowthPlan(
        stageCounts: [1, 3, 5, 7, 9, 11, 13, 15, 17, 20, 23, 26],
        finalCount: 28
    )

    /// A lot redevelops into the next building tier at these ages.
    private static let villageMaturityAges = [0.12, 0.30, 0.55]

    /// High-rises only appear once the journey reaches its city stages.
    private static let villageStageLevelCaps = [0, 0, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3]

    /// Windows light up from the sunset stage onward. The scene's motion
    /// reads the same threshold so lit artwork and lit windows never disagree.
    static let villageLitStageThreshold = 8
    static let villageNightStageThreshold = 9

    // MARK: Old School RuneScape

    private static let oldSchoolBackgroundNames = [
        "01-lumbridge", "02-al-kharid", "03-varrock", "04-karamja",
        "05-grand-exchange", "06-falador", "07-seers-village", "08-east-ardougne",
        "09-canifis", "10-god-wars", "11-prifddinas", "12-tombs-of-amascut"
    ]

    private static let oldSchoolCharacters = [
        "OldSchoolRuneScape/Characters/01-leather.png",
        "OldSchoolRuneScape/Characters/02-frog-leather.png",
        "OldSchoolRuneScape/Characters/03-studded-leather.png",
        "OldSchoolRuneScape/Characters/04-snakeskin.png",
        "OldSchoolRuneScape/Characters/05-green-dhide.png",
        "OldSchoolRuneScape/Characters/06-blue-dhide.png",
        "OldSchoolRuneScape/Characters/07-red-dhide.png",
        "OldSchoolRuneScape/Characters/08-black-dhide.png",
        "OldSchoolRuneScape/Characters/09-karils.png",
        "OldSchoolRuneScape/Characters/10-armadyl.png",
        "OldSchoolRuneScape/Characters/11-crystal.png",
        "OldSchoolRuneScape/Characters/12-masori.png"
    ]

    // Where the adventurer's walk through each location is anchored, and how
    // tall they are relative to the scene, so gear and scenery stay balanced.
    private static let oldSchoolPlacements: [(height: Double, x: Double)] = [
        (0.72, 0.33), (0.72, 0.60), (0.70, 0.28), (0.74, 0.34),
        (0.72, 0.30), (0.66, 0.68), (0.66, 0.62), (0.72, 0.45),
        (0.74, 0.47), (0.74, 0.22), (0.70, 0.55), (0.74, 0.50)
    ]

    /// How far the adventurer travels across a location while its stage
    /// progresses, as a fraction of the scene width.
    private static let oldSchoolWalkSpan = 0.32

    private static let ageOfEmpiresSceneNames = [
        "01-dark-age-camp", "02-dark-age-hamlet", "03-dark-age-town",
        "04-feudal-age", "05-feudal-village", "06-feudal-town",
        "07-castle-age", "08-castle-village", "09-castle-town",
        "10-imperial-age", "11-imperial-city", "12-imperial-capital"
    ]

    // MARK: Minecraft

    private static let minecraftSceneNames = [
        "01-plains", "02-forest", "03-village", "04-lush-caves",
        "05-jagged-peaks", "06-ancient-city", "07-nether-wastes",
        "08-crimson-forest", "09-nether-fortress", "10-stronghold",
        "11-the-end", "12-end-city"
    ]

    /// The survivor's gear per stage: armor upgrades land on milestones the
    /// way the game's own progression does.
    private static let minecraftGearTiers = [
        "steve", "steve", "leather", "leather", "golden", "chainmail",
        "iron", "iron", "diamond", "diamond", "netherite", "netherite"
    ]

    // Where the survivor stands in each location, and how tall they are
    // relative to the scene.
    private static let minecraftPlacements: [(height: Double, x: Double)] = [
        (0.64, 0.35), (0.64, 0.40), (0.66, 0.30), (0.66, 0.45),
        (0.62, 0.40), (0.64, 0.35), (0.66, 0.40), (0.66, 0.45),
        (0.64, 0.35), (0.68, 0.40), (0.64, 0.42), (0.62, 0.45)
    ]

    /// How far the survivor travels across a location while its stage
    /// progresses, as a fraction of the scene width.
    private static let minecraftWalkSpan = 0.3

    /// Scenery variants a theme offers per stage, for the daily rotation.
    static func sceneryCount(for theme: CompanionTheme) -> Int {
        theme == .none ? 0 : sceneryVariantCount
    }

    static func scene(
        theme: CompanionTheme,
        variant: CompanionVariant,
        stage: Int,
        scenery: Int = 0,
        fraction: Double = 0,
        seed: UInt64 = 0
    ) -> CompanionSceneAsset? {
        let stage = clamped(stage)
        let fraction = min(max(fraction, 0), 1)
        let suffix = scenerySuffix(scenery)
        switch theme {
        case .none:
            return nil
        case .pokemon:
            return pokemonScene(
                variant: variant,
                stage: stage,
                suffix: suffix,
                fraction: fraction
            )
        case .forest:
            return forestScene(
                stage: stage,
                suffix: suffix,
                fraction: fraction,
                seed: seed
            )
        case .village:
            return villageScene(
                stage: stage,
                suffix: suffix,
                fraction: fraction,
                seed: seed
            )
        case .oldSchoolRuneScape:
            let placement = oldSchoolPlacements[stage]
            let start = placement.x - oldSchoolWalkSpan / 2
            let position = min(max(start + oldSchoolWalkSpan * fraction, 0.1), 0.9)
            return CompanionSceneAsset(
                backgroundResource: "OldSchoolRuneScape/Backgrounds/\(oldSchoolBackgroundNames[stage])-\(suffix).jpg",
                layers: [
                    CompanionSceneLayer(
                        id: oldSchoolCharacters[stage],
                        resource: oldSchoolCharacters[stage],
                        relativeHeight: placement.height,
                        horizontalPosition: position,
                        bottomOffset: 0.04,
                        castsGroundShadow: true,
                        role: .adventurer
                    )
                ]
            )
        case .ageOfEmpiresII:
            return CompanionSceneAsset(
                backgroundResource: "AgeOfEmpiresII/scenes/\(ageOfEmpiresSceneNames[stage])-\(suffix).jpg",
                layers: [],
                backgroundZoom: 1 + 0.06 * fraction
            )
        case .minecraft:
            let placement = minecraftPlacements[stage]
            let start = placement.x - minecraftWalkSpan / 2
            let position = min(max(start + minecraftWalkSpan * fraction, 0.1), 0.9)
            let character = "Minecraft/characters/\(minecraftGearTiers[stage]).png"
            return CompanionSceneAsset(
                backgroundResource: "Minecraft/scenes/\(minecraftSceneNames[stage])-\(suffix).jpg",
                layers: [
                    CompanionSceneLayer(
                        id: character,
                        resource: character,
                        relativeHeight: placement.height,
                        horizontalPosition: position,
                        bottomOffset: 0.04,
                        castsGroundShadow: true,
                        role: .survivor
                    )
                ]
            )
        }
    }

    private static func scenerySuffix(_ scenery: Int) -> String {
        let remainder = scenery % scenerySuffixes.count
        return scenerySuffixes[remainder >= 0 ? remainder : remainder + scenerySuffixes.count]
    }

    /// The stage whose scene best introduces a theme on the settings shelf.
    static func shelfPreviewStage(for theme: CompanionTheme) -> Int {
        switch theme {
        case .none: 0
        case .pokemon: 9
        case .forest: 9
        case .village: 10
        case .oldSchoolRuneScape: 2
        case .ageOfEmpiresII: 8
        case .minecraft: 2
        }
    }

    /// The bundled image whose alpha channel drives the 18 x 18 menu-bar
    /// template silhouette. Age of Empires II scenes are opaque screenshots,
    /// so that theme draws a vector glyph instead (`CompanionMenuIconRenderer`).
    static func menuIconResource(
        theme: CompanionTheme,
        variant: CompanionVariant,
        stage: Int
    ) -> String? {
        let stage = clamped(stage)
        switch theme {
        case .none, .ageOfEmpiresII:
            return nil
        case .pokemon:
            guard let line = pokemonLine(for: variant) else { return nil }
            return artworkResource(line[evolutionIndex(for: stage)])
        case .forest:
            return String(format: "Forest/silhouettes/%02d.png", stage + 1)
        case .village:
            return String(format: "Village/silhouettes/%02d.png", stage + 1)
        case .oldSchoolRuneScape:
            return oldSchoolCharacters[stage]
        case .minecraft:
            return "Minecraft/characters/\(minecraftGearTiers[stage]).png"
        }
    }

    // MARK: - Growing pixel scenes

    /// One stable spot in a growing scene. Every roll is drawn up front from
    /// the user's seed, so a slot keeps its place, species, and proportions
    /// for the whole journey while only its maturity advances.
    private struct GrowthSlot {
        let index: Int
        let x: Double
        let back: Bool
        let bottomOffset: Double
        let appearance: Double
        let speciesRoll: Double
        let sizeJitter: Double
    }

    private static func growthSlots(
        plan: CompanionGrowthPlan,
        seed: UInt64,
        key: String,
        frontBottom: Double,
        backBottom: Double
    ) -> [GrowthSlot] {
        var rng = SplitMix64(state: seed ^ CompanionHash.fnv1a(key))
        let phase = rng.unit()
        return (0..<plan.finalCount).map { index in
            let golden = (phase + Double(index) * 0.618033988749895)
                .truncatingRemainder(dividingBy: 1)
            let jitter = rng.range(-0.02, 0.02)
            // The founding subject anchors the scene front and center; every
            // later arrival spreads across the ground via the golden-ratio
            // sequence so density stays even as the population grows.
            let isFounder = index == 0
            let x = isFounder
                ? 0.5 + jitter
                : min(max(0.05 + golden * 0.90 + jitter, 0.04), 0.96)
            // Bands alternate deterministically so both depths fill evenly
            // for every seed — the back band is where the village's oldest
            // lots are allowed to rise into high-rises, so it must always
            // hold early arrivals.
            let back = isFounder ? false : index % 2 == 1
            let bottom = back
                ? backBottom + rng.range(-0.012, 0.012)
                : frontBottom + rng.range(-0.015, 0.015)
            return GrowthSlot(
                index: index,
                x: x,
                back: back,
                bottomOffset: bottom,
                appearance: plan.appearance(of: index),
                speciesRoll: rng.unit(),
                sizeJitter: rng.range(0.94, 1.06)
            )
        }
    }

    /// Sprite maturity for a slot: how many age thresholds it has crossed,
    /// capped by what the current stage allows.
    private static func maturityLevel(
        slot: GrowthSlot,
        globalProgress: Double,
        ages: [Double],
        cap: Int
    ) -> Int {
        let age = globalProgress - slot.appearance
        let matured = ages.lastIndex(where: { age >= $0 }).map { $0 + 1 } ?? 0
        return min(matured, cap)
    }

    /// Back band first, then front, each deep-to-near so nearer sprites
    /// paint over farther ones.
    private static func paintersOrder(_ lhs: GrowthSlot, _ rhs: GrowthSlot) -> Bool {
        if lhs.back != rhs.back { return lhs.back }
        if lhs.bottomOffset != rhs.bottomOffset { return lhs.bottomOffset > rhs.bottomOffset }
        return lhs.index < rhs.index
    }

    private static func forestScene(
        stage: Int,
        suffix: String,
        fraction: Double,
        seed: UInt64
    ) -> CompanionSceneAsset {
        let plan = forestGrowthPlan
        let slots = growthSlots(
            plan: plan,
            seed: seed,
            key: "forest/slots",
            frontBottom: 0.11,
            backBottom: 0.175
        )
        let population = plan.population(stage: stage, fraction: fraction)
        let progress = plan.globalProgress(stage: stage, fraction: fraction)
        let layers = slots.prefix(population).sorted(by: paintersOrder).map { slot in
            // The founding tree is always an oak so the journey opens on the
            // theme's most iconic silhouette.
            let species = slot.index == 0 ? forestSpecies[0] : forestSpecies[
                slot.speciesRoll < 0.4 ? 0 : (slot.speciesRoll < 0.75 ? 1 : 2)
            ]
            let level = maturityLevel(
                slot: slot,
                globalProgress: progress,
                ages: forestMaturityAges,
                cap: forestStageLevelCaps[stage]
            )
            let cells = forestSpriteCellHeights[species]![level]
            return CompanionSceneLayer(
                id: "forest-slot-\(slot.index)",
                resource: "Forest/sprites/\(species)-\(level).png",
                relativeHeight: Double(cells) * cellHeightFraction
                    * (slot.back ? backBandScale : 1) * slot.sizeJitter,
                horizontalPosition: slot.x,
                bottomOffset: slot.bottomOffset,
                // Pixel sprites carry their own dithered contact shadow.
                castsGroundShadow: false,
                role: .tree
            )
        }
        return CompanionSceneAsset(
            backgroundResource: String(format: "Forest/scenes/%02d-%@.png", stage + 1, suffix),
            layers: layers
        )
    }

    private static func villageScene(
        stage: Int,
        suffix: String,
        fraction: Double,
        seed: UInt64
    ) -> CompanionSceneAsset {
        let plan = villageGrowthPlan
        let slots = growthSlots(
            plan: plan,
            seed: seed,
            key: "village/slots",
            frontBottom: 0.115,
            backBottom: 0.175
        )
        let population = plan.population(stage: stage, fraction: fraction)
        let progress = plan.globalProgress(stage: stage, fraction: fraction)
        let light = stage >= villageLitStageThreshold ? "lit" : "day"
        let layers = slots.prefix(population).sorted(by: paintersOrder).map { slot in
            let style = villageStyle(for: slot)
            // High-rises rise behind the streetfront: the front band keeps
            // its buildings at mid-rise scale so the skyline reads in depth.
            let cap = min(
                villageStageLevelCaps[stage],
                slot.back ? 3 : 2
            )
            let level = maturityLevel(
                slot: slot,
                globalProgress: progress,
                ages: villageMaturityAges,
                cap: cap
            )
            let cells = villageSpriteCellHeights[style]![level]
            return CompanionSceneLayer(
                id: "village-slot-\(slot.index)",
                resource: "Village/sprites/\(style)-\(level)-\(light).png",
                relativeHeight: Double(cells) * cellHeightFraction
                    * (slot.back ? backBandScale : 1) * slot.sizeJitter,
                horizontalPosition: slot.x,
                bottomOffset: slot.bottomOffset,
                castsGroundShadow: false,
                role: .building
            )
        }
        return CompanionSceneAsset(
            backgroundResource: String(format: "Village/scenes/%02d-%@.png", stage + 1, suffix),
            layers: layers
        )
    }

    /// Early lots lean timber-framed, the town's middle era favors brick,
    /// and late arrivals build modern — so the city keeps a period skyline.
    /// The founding lot is always the classic timber cottage.
    private static func villageStyle(for slot: GrowthSlot) -> String {
        guard slot.index != 0 else { return villageStyles[0] }
        let weights: [Double]
        if slot.appearance < 0.3 {
            weights = [0.6, 0.3, 0.1]
        } else if slot.appearance < 0.6 {
            weights = [0.25, 0.45, 0.3]
        } else {
            weights = [0.1, 0.3, 0.6]
        }
        var roll = slot.speciesRoll
        for (index, weight) in weights.enumerated() {
            if roll < weight { return villageStyles[index] }
            roll -= weight
        }
        return villageStyles[villageStyles.count - 1]
    }

    // MARK: - Pokémon

    private static func pokemonScene(
        variant: CompanionVariant,
        stage: Int,
        suffix: String,
        fraction: Double
    ) -> CompanionSceneAsset? {
        guard let line = pokemonLine(for: variant) else { return nil }
        let finaleStage = CompanionJourney.thresholds.count - 1
        let members = stage == finaleStage ? line : [line[evolutionIndex(for: stage)]]
        // The finale gathers the family, growing left to right. A lone
        // partner visibly grows within its stage as the next evolution nears.
        let positions: [Double] = members.count == 1 ? [0.5] : [0.22, 0.48, 0.76]
        let growth = members.count == 1 ? 0.92 + 0.14 * fraction : 1
        let relativeHeights: [Double] = members.count == 1
            ? [0.60 * growth]
            : [0.36, 0.44, 0.52]
        let layers = zip(members, zip(positions, relativeHeights)).map { identifier, placement in
            CompanionSceneLayer(
                id: artworkResource(identifier),
                resource: artworkResource(identifier),
                relativeHeight: placement.1,
                horizontalPosition: placement.0,
                bottomOffset: 0.085,
                castsGroundShadow: true,
                role: .creature
            )
        }
        return CompanionSceneAsset(
            backgroundResource: "Pokemon/scenes/\(pokemonSceneNames[stage])-\(suffix).jpg",
            layers: layers
        )
    }

    private static func pokemonLine(for variant: CompanionVariant) -> [Int]? {
        guard let index = CompanionCatalog.variants(for: .pokemon)
            .firstIndex(of: variant),
              pokemonEvolutionLines.indices.contains(index) else { return nil }
        return pokemonEvolutionLines[index]
    }

    /// The family evolves at the stage-5 and stage-9 milestones.
    private static func evolutionIndex(for stage: Int) -> Int {
        stage < 4 ? 0 : (stage < 8 ? 1 : 2)
    }

    private static func artworkResource(_ identifier: Int) -> String {
        String(format: "Pokemon/art/%03d.png", identifier)
    }

    private static func clamped(_ stage: Int) -> Int {
        min(max(stage, 0), CompanionJourney.thresholds.count - 1)
    }
}
