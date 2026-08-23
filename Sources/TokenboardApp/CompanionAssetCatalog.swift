import Foundation

struct CompanionAssetCrop: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    static let full = CompanionAssetCrop(x: 0, y: 0, width: 1, height: 1)
}

enum CompanionSceneBlendMode: Equatable, Sendable {
    case normal
    case multiply
}

struct CompanionSceneLayer: Equatable, Sendable, Identifiable {
    let resource: String
    let crop: CompanionAssetCrop?
    let relativeHeight: Double
    let horizontalPosition: Double
    let bottomOffset: Double
    let usesNearestNeighbor: Bool
    let blendMode: CompanionSceneBlendMode

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
                layers: []
            )
        case .oldSchoolRuneScape:
            return CompanionSceneAsset(
                backgroundResource: oldSchoolBackgrounds[stage],
                backgroundCrop: nil,
                layers: [
                    CompanionSceneLayer(
                        resource: oldSchoolCharacters[stage],
                        crop: nil,
                        relativeHeight: 1.10,
                        horizontalPosition: 0.5,
                        bottomOffset: -0.04,
                        usesNearestNeighbor: false,
                        blendMode: .normal
                    )
                ]
            )
        case .ageOfEmpiresII:
            return CompanionSceneAsset(
                backgroundResource: ageOfEmpiresScenes[stage],
                backgroundCrop: nil,
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
                usesNearestNeighbor: false,
                blendMode: .normal
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
                usesNearestNeighbor: true,
                blendMode: .normal
            )
        }
        return CompanionSceneAsset(
            backgroundResource: pokemonBackgrounds[stage],
            backgroundCrop: nil,
            layers: layers
        )
    }

    private static func treeScene(stage: Int) -> CompanionSceneAsset {
        let progression = [0, 0, 1, 1, 2, 3, 3, 4]
        let crops = [
            CompanionAssetCrop(x: 0.04, y: 0.86, width: 0.06, height: 0.11),
            CompanionAssetCrop(x: 0.18, y: 0.65, width: 0.07, height: 0.32),
            CompanionAssetCrop(x: 0.32, y: 0.38, width: 0.12, height: 0.59),
            CompanionAssetCrop(x: 0.51, y: 0.18, width: 0.18, height: 0.79),
            CompanionAssetCrop(x: 0.74, y: 0.04, width: 0.22, height: 0.93)
        ]
        let relativeHeights = [0.18, 0.24, 0.31, 0.39, 0.49, 0.60, 0.72, 0.84]
        let step = progression[stage]
        return CompanionSceneAsset(
            backgroundResource: "Tree/woodland.jpg",
            backgroundCrop: nil,
            layers: [
                CompanionSceneLayer(
                    resource: "Tree/growing-tree.png",
                    crop: crops[step],
                    relativeHeight: relativeHeights[stage],
                    horizontalPosition: 0.5,
                    bottomOffset: 0.02,
                    usesNearestNeighbor: false,
                    blendMode: .multiply
                )
            ]
        )
    }

}
