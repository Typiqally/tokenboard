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

/// Maps every visible theme, variant, and journey stage to the bundled
/// artwork baked by `Scripts/bake-companion-assets.swift` and
/// `Scripts/generate-companion-artwork.swift`. Every background is a Retina
/// panorama; the popover shows it whole while compact previews take a
/// bottom-aligned crop from the same plate.
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
    private static let pokemonSceneNames: CompanionStageTable<String> = [
        "01-pallet-town", "02-viridian-forest", "03-pewter-city",
        "04-cerulean-city", "05-vermilion-city", "06-lavender-town",
        "07-celadon-city", "08-saffron-city", "09-fuchsia-city",
        "10-cinnabar-island", "11-victory-road", "12-indigo-plateau"
    ]

    // MARK: Pixel-art scene geometry

    /// The generated pixel plates use one art pixel per grid cell on a
    /// 155-column grid, so a cell spans 350 / 155 points on screen. Sprite
    /// layer heights are expressed in
    /// cells and converted through this fraction so subject pixels land at
    /// exactly the same size as background pixels.
    static let pixelGridWidth = 155.0
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
    private static let forestStageLevelCaps: CompanionStageTable<Int> = [
        1, 1, 1, 2, 2, 2, 3, 3, 3, 3, 3, 3
    ]

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
    private static let villageStageLevelCaps: CompanionStageTable<Int> = [
        0, 0, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3
    ]

    /// Windows light up from the sunset stage onward. The scene's motion
    /// reads the same threshold so lit artwork and lit windows never disagree.
    static let villageLitStageThreshold = 8
    static let villageNightStageThreshold = 9

    // MARK: Old School RuneScape

    /// One location on the adventurer's journey: its backdrop, the gear worn
    /// there, and where the walk is anchored — `height` and `x` size the
    /// adventurer relative to the scene so gear and scenery stay balanced.
    private struct OldSchoolStage {
        let backgroundName: String
        let characterResource: String
        let height: Double
        let x: Double

        init(_ backgroundName: String, _ character: String, height: Double, x: Double) {
            self.backgroundName = backgroundName
            self.characterResource = "OldSchoolRuneScape/Characters/\(character).png"
            self.height = height
            self.x = x
        }
    }

    private static let oldSchoolStages: CompanionStageTable<OldSchoolStage> = [
        OldSchoolStage("01-lumbridge", "01-leather", height: 0.72, x: 0.33),
        OldSchoolStage("02-al-kharid", "02-frog-leather", height: 0.72, x: 0.60),
        OldSchoolStage("03-varrock", "03-studded-leather", height: 0.70, x: 0.28),
        OldSchoolStage("04-karamja", "04-snakeskin", height: 0.74, x: 0.34),
        OldSchoolStage("05-grand-exchange", "05-green-dhide", height: 0.72, x: 0.30),
        OldSchoolStage("06-falador", "06-blue-dhide", height: 0.66, x: 0.68),
        OldSchoolStage("07-seers-village", "07-red-dhide", height: 0.66, x: 0.62),
        OldSchoolStage("08-east-ardougne", "08-black-dhide", height: 0.72, x: 0.45),
        OldSchoolStage("09-canifis", "09-karils", height: 0.74, x: 0.47),
        OldSchoolStage("10-god-wars", "10-armadyl", height: 0.74, x: 0.22),
        OldSchoolStage("11-prifddinas", "11-crystal", height: 0.70, x: 0.55),
        OldSchoolStage("12-tombs-of-amascut", "12-masori", height: 0.74, x: 0.50)
    ]

    /// How far the adventurer travels across a location while its stage
    /// progresses, as a fraction of the scene width.
    private static let oldSchoolWalkSpan = 0.32

    private static let ageOfEmpiresSceneNames: CompanionStageTable<String> = [
        "01-dark-age-camp", "02-dark-age-hamlet", "03-dark-age-town",
        "04-feudal-age", "05-feudal-village", "06-feudal-town",
        "07-castle-age", "08-castle-village", "09-castle-town",
        "10-imperial-age", "11-imperial-city", "12-imperial-capital"
    ]

    private static let banishedSceneNames = [
        "01-first-shelter", "02-gatherers-clearing", "03-first-harvest",
        "04-pasture-raised", "05-roads-laid", "06-river-crossing",
        "07-trading-post", "08-market-town", "09-stone-village",
        "10-first-hard-winter", "11-winter-endured", "12-thriving-township"
    ]

    private static let frostpunkSceneNames = [
        "01-the-generator", "02-first-tents", "03-coal-lifeline",
        "04-workshop-district", "05-beacon-raised", "06-steam-hubs",
        "07-hothouse-harvest", "08-industrial-city", "09-automaton-age",
        "10-storm-watch", "11-the-great-storm", "12-new-london-endures"
    ]

    // MARK: Minecraft

    /// One location on the survivor's journey: its scene, the armor worn
    /// there (upgrades land on milestones the way the game's own progression
    /// does), and where the survivor stands — `height` and `x` size them
    /// relative to the scene.
    private struct MinecraftStage {
        let sceneName: String
        let gearTier: String
        let height: Double
        let x: Double

        init(_ sceneName: String, _ gearTier: String, height: Double, x: Double) {
            self.sceneName = sceneName
            self.gearTier = gearTier
            self.height = height
            self.x = x
        }
    }

    private static let minecraftStages: CompanionStageTable<MinecraftStage> = [
        MinecraftStage("01-plains", "steve", height: 0.64, x: 0.35),
        MinecraftStage("02-forest", "steve", height: 0.64, x: 0.40),
        MinecraftStage("03-village", "leather", height: 0.66, x: 0.30),
        MinecraftStage("04-lush-caves", "leather", height: 0.66, x: 0.45),
        MinecraftStage("05-jagged-peaks", "golden", height: 0.62, x: 0.40),
        MinecraftStage("06-ancient-city", "chainmail", height: 0.64, x: 0.35),
        MinecraftStage("07-nether-wastes", "iron", height: 0.66, x: 0.40),
        MinecraftStage("08-crimson-forest", "iron", height: 0.66, x: 0.45),
        MinecraftStage("09-nether-fortress", "diamond", height: 0.64, x: 0.35),
        MinecraftStage("10-stronghold", "diamond", height: 0.68, x: 0.40),
        MinecraftStage("11-the-end", "netherite", height: 0.64, x: 0.42),
        MinecraftStage("12-end-city", "netherite", height: 0.62, x: 0.45)
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
        let stage = CompanionJourney.clamped(stage: stage)
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
            let location = oldSchoolStages[stage: stage]
            let start = location.x - oldSchoolWalkSpan / 2
            let position = min(max(start + oldSchoolWalkSpan * fraction, 0.1), 0.9)
            return CompanionSceneAsset(
                backgroundResource: "OldSchoolRuneScape/Backgrounds/\(location.backgroundName)-\(suffix).jpg",
                layers: [
                    CompanionSceneLayer(
                        id: location.characterResource,
                        resource: location.characterResource,
                        relativeHeight: location.height,
                        horizontalPosition: position,
                        bottomOffset: 0.04,
                        castsGroundShadow: true,
                        role: .adventurer
                    )
                ]
            )
        case .ageOfEmpiresII:
            return CompanionSceneAsset(
                backgroundResource: "AgeOfEmpiresII/scenes/\(ageOfEmpiresSceneNames[stage: stage])-\(suffix).jpg",
                layers: [],
                backgroundZoom: 1 + 0.06 * fraction
            )
        case .minecraft:
            let location = minecraftStages[stage: stage]
            let start = location.x - minecraftWalkSpan / 2
            let position = min(max(start + minecraftWalkSpan * fraction, 0.1), 0.9)
            let character = "Minecraft/characters/\(location.gearTier).png"
            return CompanionSceneAsset(
                backgroundResource: "Minecraft/scenes/\(location.sceneName)-\(suffix).jpg",
                layers: [
                    CompanionSceneLayer(
                        id: character,
                        resource: character,
                        relativeHeight: location.height,
                        horizontalPosition: position,
                        bottomOffset: 0.04,
                        castsGroundShadow: true,
                        role: .survivor
                    )
                ]
            )
        case .banished:
            return CompanionSceneAsset(
                backgroundResource: "Banished/scenes/\(banishedSceneNames[stage])-\(suffix).jpg",
                layers: [],
                backgroundZoom: 1 + 0.035 * fraction
            )
        case .frostpunk:
            return CompanionSceneAsset(
                backgroundResource: "Frostpunk/scenes/\(frostpunkSceneNames[stage])-\(suffix).jpg",
                layers: [],
                backgroundZoom: 1 + 0.025 * fraction
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
        case .banished: 8
        case .frostpunk: 8
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
        let stage = CompanionJourney.clamped(stage: stage)
        switch theme {
        case .none, .ageOfEmpiresII, .banished, .frostpunk:
            return nil
        case .pokemon:
            guard let line = pokemonLine(for: variant) else { return nil }
            return artworkResource(line[evolutionIndex(for: stage)])
        case .forest:
            return String(format: "Forest/silhouettes/%02d.png", stage + 1)
        case .village:
            return String(format: "Village/silhouettes/%02d.png", stage + 1)
        case .oldSchoolRuneScape:
            return oldSchoolStages[stage: stage].characterResource
        case .minecraft:
            return "Minecraft/characters/\(minecraftStages[stage: stage].gearTier).png"
        }
    }

    // MARK: - Growing pixel scenes

    /// On-screen height for a sprite of `cells` grid cells standing in
    /// `slot` — the one formula both growing themes size their sprites with.
    private static func growthSpriteHeight(cells: Int, slot: CompanionGrowthSlot) -> Double {
        Double(cells) * cellHeightFraction
            * (slot.back ? backBandScale : 1) * slot.sizeJitter
    }

    private static func forestScene(
        stage: Int,
        suffix: String,
        fraction: Double,
        seed: UInt64
    ) -> CompanionSceneAsset {
        CompanionGrowthScene.make(
            spec: CompanionGrowthSceneSpec(
                plan: forestGrowthPlan,
                slotKey: "forest/slots",
                frontBottom: 0.11,
                backBottom: 0.175,
                maturityAges: forestMaturityAges,
                layerIDPrefix: "forest-slot-",
                role: .tree,
                // The founding tree is always an oak so the journey opens on
                // the theme's most iconic silhouette.
                style: { slot in
                    slot.index == 0 ? forestSpecies[0] : forestSpecies[
                        slot.speciesRoll < 0.4 ? 0 : (slot.speciesRoll < 0.75 ? 1 : 2)
                    ]
                },
                cap: { _ in forestStageLevelCaps[stage: stage] },
                cellHeights: forestSpriteCellHeights,
                relativeHeight: growthSpriteHeight,
                resource: { species, level in "Forest/sprites/\(species)-\(level).png" },
                backgroundResource: String(format: "Forest/scenes/%02d-%@.png", stage + 1, suffix)
            ),
            stage: stage,
            fraction: fraction,
            seed: seed
        )
    }

    private static func villageScene(
        stage: Int,
        suffix: String,
        fraction: Double,
        seed: UInt64
    ) -> CompanionSceneAsset {
        let light = stage >= villageLitStageThreshold ? "lit" : "day"
        return CompanionGrowthScene.make(
            spec: CompanionGrowthSceneSpec(
                plan: villageGrowthPlan,
                slotKey: "village/slots",
                frontBottom: 0.115,
                backBottom: 0.175,
                maturityAges: villageMaturityAges,
                layerIDPrefix: "village-slot-",
                role: .building,
                style: villageStyle(for:),
                // High-rises rise behind the streetfront: the front band
                // keeps its buildings at mid-rise scale so the skyline reads
                // in depth.
                cap: { slot in
                    min(villageStageLevelCaps[stage: stage], slot.back ? 3 : 2)
                },
                cellHeights: villageSpriteCellHeights,
                relativeHeight: growthSpriteHeight,
                resource: { style, level in "Village/sprites/\(style)-\(level)-\(light).png" },
                backgroundResource: String(format: "Village/scenes/%02d-%@.png", stage + 1, suffix)
            ),
            stage: stage,
            fraction: fraction,
            seed: seed
        )
    }

    /// Early lots lean timber-framed, the town's middle era favors brick,
    /// and late arrivals build modern — so the city keeps a period skyline.
    /// The founding lot is always the classic timber cottage.
    private static func villageStyle(for slot: CompanionGrowthSlot) -> String {
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
        let members = stage == CompanionJourney.finalStage
            ? line
            : [line[evolutionIndex(for: stage)]]
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
            backgroundResource: "Pokemon/scenes/\(pokemonSceneNames[stage: stage])-\(suffix).jpg",
            layers: layers
        )
    }

    private static func pokemonLine(for variant: CompanionVariant) -> [Int]? {
        guard let index = CompanionCatalog.variants(for: .pokemon)
            .firstIndex(of: variant),
              pokemonEvolutionLines.indices.contains(index) else { return nil }
        return pokemonEvolutionLines[index]
    }

    /// The family evolves at these milestones.
    private static let firstEvolutionStage = 4
    private static let finalEvolutionStage = 8

    private static func evolutionIndex(for stage: Int) -> Int {
        stage < firstEvolutionStage ? 0 : (stage < finalEvolutionStage ? 1 : 2)
    }

    private static func artworkResource(_ identifier: Int) -> String {
        String(format: "Pokemon/art/%03d.png", identifier)
    }
}
