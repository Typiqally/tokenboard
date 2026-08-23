import Foundation

struct CompanionAssetCrop: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    static let full = CompanionAssetCrop(x: 0, y: 0, width: 1, height: 1)
}

struct CompanionSceneLayer: Equatable, Sendable, Identifiable {
    let resource: String
    let crop: CompanionAssetCrop?
    let relativeHeight: Double
    let horizontalPosition: Double
    let bottomOffset: Double
    let usesNearestNeighbor: Bool

    var id: String {
        [
            resource,
            String(horizontalPosition),
            String(bottomOffset)
        ].joined(separator: ":")
    }
}

struct CompanionSceneAsset: Equatable, Sendable {
    let backgroundResource: String
    let backgroundCrop: CompanionAssetCrop?
    let backgroundHorizontalPosition: Double
    let layers: [CompanionSceneLayer]

    var allResources: [String] {
        [backgroundResource] + layers.map(\.resource)
    }
}

enum CompanionAssetCatalog {
    private static let pokemonEvolutionLines: [[Int]] = [
        [1, 2, 3], [4, 5, 6], [7, 8, 9],
        [152, 153, 154], [155, 156, 157], [158, 159, 160],
        [252, 253, 254], [255, 256, 257], [258, 259, 260],
        [387, 388, 389], [390, 391, 392], [393, 394, 395]
    ]

    private static let pokemonBackgrounds = (1...8).map {
        let names = [
            "pallet-town", "viridian-forest", "cerulean-city", "vermilion-city",
            "celadon-city", "fuchsia-city", "cinnabar-island", "indigo-plateau"
        ]
        return String(format: "Pokemon/Backgrounds/%02d-%@.png", $0, names[$0 - 1])
    }

    private static let towerScenes = [
        "Tower/01-house.jpg",
        "Tower/02-townhouse.jpg",
        "Tower/03-apartments.jpg",
        "Tower/04-mid-rise.jpg",
        "Tower/05-high-rise.jpg",
        "Tower/06-skyline.jpg",
        "Tower/07-city-tower.jpg",
        "Tower/08-skyscraper.jpg"
    ]

    private static let oldSchoolBackgrounds = [
        "OldSchoolRuneScape/Backgrounds/01-lumbridge.png",
        "OldSchoolRuneScape/Backgrounds/02-varrock.png",
        "OldSchoolRuneScape/Backgrounds/03-falador.png",
        "OldSchoolRuneScape/Backgrounds/04-seers-village.png",
        "OldSchoolRuneScape/Backgrounds/05-karamja.png",
        "OldSchoolRuneScape/Backgrounds/06-canifis.png",
        "OldSchoolRuneScape/Backgrounds/07-god-wars.png",
        "OldSchoolRuneScape/Backgrounds/08-tombs-of-amascut.png"
    ]

    private static let oldSchoolCharacters = [
        "OldSchoolRuneScape/Characters/01-leather.png",
        "OldSchoolRuneScape/Characters/02-studded-leather.png",
        "OldSchoolRuneScape/Characters/03-green-dhide.png",
        "OldSchoolRuneScape/Characters/04-blue-dhide.png",
        "OldSchoolRuneScape/Characters/05-red-dhide.png",
        "OldSchoolRuneScape/Characters/06-black-dhide.png",
        "OldSchoolRuneScape/Characters/07-armadyl.png",
        "OldSchoolRuneScape/Characters/08-masori.png"
    ]

    private static let ageOfEmpiresScenes = [
        "AgeOfEmpiresII/01-dark-age.webp",
        "AgeOfEmpiresII/02-growing-camp.webp",
        "AgeOfEmpiresII/03-feudal-age.webp",
        "AgeOfEmpiresII/03-feudal-age.webp",
        "AgeOfEmpiresII/05-castle-age.webp",
        "AgeOfEmpiresII/05-castle-age.webp",
        "AgeOfEmpiresII/07-imperial-age.webp",
        "AgeOfEmpiresII/07-imperial-age.webp"
    ]

    static func scene(
        theme: CompanionTheme,
        variant: CompanionVariant,
        stage: Int
    ) -> CompanionSceneAsset? {
        let stage = min(max(stage, 0), CompanionJourney.thresholds.count - 1)
        switch theme {
        case .none:
            return nil
        case .pokemon:
            return pokemonScene(variant: variant, stage: stage)
        case .tree:
            return treeScene(stage: stage)
        case .tower:
            return CompanionSceneAsset(
                backgroundResource: towerScenes[stage],
                backgroundCrop: nil,
                backgroundHorizontalPosition: towerHorizontalPosition(stage: stage),
                layers: []
            )
        case .oldSchoolRuneScape:
            return CompanionSceneAsset(
                backgroundResource: oldSchoolBackgrounds[stage],
                backgroundCrop: nil,
                backgroundHorizontalPosition: 0.5,
                layers: [
                    CompanionSceneLayer(
                        resource: oldSchoolCharacters[stage],
                        crop: nil,
                        relativeHeight: 1.46,
                        horizontalPosition: 0.5,
                        bottomOffset: -0.12,
                        usesNearestNeighbor: false
                    )
                ]
            )
        case .ageOfEmpiresII:
            return CompanionSceneAsset(
                backgroundResource: ageOfEmpiresScenes[stage],
                backgroundCrop: ageOfEmpiresCrop(stage: stage),
                backgroundHorizontalPosition: 0.5,
                layers: []
            )
        }
    }

    static func menuIconLayer(
        theme: CompanionTheme,
        variant: CompanionVariant,
        stage: Int
    ) -> CompanionSceneLayer? {
        let stage = min(max(stage, 0), CompanionJourney.thresholds.count - 1)
        if theme == .ageOfEmpiresII {
            let resources = [
                "AgeOfEmpiresII/Icons/dark-age.webp",
                "AgeOfEmpiresII/Icons/dark-age.webp",
                "AgeOfEmpiresII/Icons/feudal-age.webp",
                "AgeOfEmpiresII/Icons/feudal-age.webp",
                "AgeOfEmpiresII/Icons/castle-age.webp",
                "AgeOfEmpiresII/Icons/castle-age.webp",
                "AgeOfEmpiresII/Icons/imperial-age.webp",
                "AgeOfEmpiresII/Icons/imperial-age.webp"
            ]
            return CompanionSceneLayer(
                resource: resources[stage],
                crop: nil,
                relativeHeight: 1,
                horizontalPosition: 0.5,
                bottomOffset: 0,
                usesNearestNeighbor: false
            )
        }
        return scene(theme: theme, variant: variant, stage: stage)?.layers.last
    }

    private static func pokemonScene(
        variant: CompanionVariant,
        stage: Int
    ) -> CompanionSceneAsset? {
        guard let variantIndex = CompanionCatalog.variants(for: .pokemon)
            .firstIndex(of: variant),
              pokemonEvolutionLines.indices.contains(variantIndex) else { return nil }
        let line = pokemonEvolutionLines[variantIndex]
        let evolution = stage < 3 ? 0 : (stage < 6 ? 1 : 2)
        let identifiers = stage == 7 ? line : [line[evolution]]
        let positions: [Double] = identifiers.count == 1 ? [0.5] : [0.36, 0.5, 0.64]
        let relativeHeight = identifiers.count == 1 ? 0.92 : 0.66
        let layers = zip(identifiers, positions).map { identifier, position in
            CompanionSceneLayer(
                resource: String(format: "Pokemon/%03d.png", identifier),
                crop: nil,
                relativeHeight: relativeHeight,
                horizontalPosition: position,
                bottomOffset: 0,
                usesNearestNeighbor: true
            )
        }
        return CompanionSceneAsset(
            backgroundResource: pokemonBackgrounds[stage],
            backgroundCrop: nil,
            backgroundHorizontalPosition: 0.5,
            layers: layers
        )
    }

    private static func treeScene(stage: Int) -> CompanionSceneAsset {
        let progression = [0, 0, 1, 1, 2, 3, 3, 4]
        let crops = [
            CompanionAssetCrop(x: 0.00, y: 0, width: 0.14, height: 1),
            CompanionAssetCrop(x: 0.11, y: 0, width: 0.18, height: 1),
            CompanionAssetCrop(x: 0.25, y: 0, width: 0.23, height: 1),
            CompanionAssetCrop(x: 0.45, y: 0, width: 0.27, height: 1),
            CompanionAssetCrop(x: 0.69, y: 0, width: 0.31, height: 1)
        ]
        let step = progression[stage]
        return CompanionSceneAsset(
            backgroundResource: "Tree/woodland.jpg",
            backgroundCrop: nil,
            backgroundHorizontalPosition: 0.5,
            layers: [
                CompanionSceneLayer(
                    resource: "Tree/growing-tree.png",
                    crop: crops[step],
                    relativeHeight: 0.82,
                    horizontalPosition: 0.5,
                    bottomOffset: 0.02,
                    usesNearestNeighbor: false
                )
            ]
        )
    }

    private static func towerHorizontalPosition(stage: Int) -> Double {
        switch stage {
        case 0: 0.52
        case 1: 0.48
        case 2: 0.52
        case 3: 0.5
        case 4: 0.5
        case 5: 0.48
        case 6: 0.5
        default: 0.5
        }
    }

    private static func ageOfEmpiresCrop(stage: Int) -> CompanionAssetCrop? {
        switch stage {
        case 0, 1:
            nil
        default:
            CompanionAssetCrop(x: 0, y: 0, width: 0.235, height: 1)
        }
    }
}
