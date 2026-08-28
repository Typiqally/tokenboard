import Foundation

/// Raw values persist in UserDefaults under `selectedCompanionTheme`, so they
/// must never be renamed. The `pokemon` vs `old_school_runescape` casing
/// inconsistency is deliberately kept: a migration would cost more than the
/// inconsistency does.
enum CompanionTheme: String, CaseIterable, Identifiable, Sendable {
    case none
    case pokemon
    case forest
    case village
    case oldSchoolRuneScape = "old_school_runescape"
    case ageOfEmpiresII = "age_of_empires_ii"
    case minecraft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .pokemon: "Pokémon"
        case .forest: "Forest"
        case .village: "Village"
        case .oldSchoolRuneScape: "Old School RuneScape"
        case .ageOfEmpiresII: "Age of Empires II"
        case .minecraft: "Minecraft"
        }
    }

    var subtitle: String {
        switch self {
        case .none: "Keep Tokenboard clean and compact"
        case .pokemon: "A starter and its evolution family"
        case .forest: "A lone sapling growing into an ancient pixel forest"
        case .village: "A pixel hamlet rising into a high-rise skyline"
        case .oldSchoolRuneScape: "An adventurer upgrading through classic gear"
        case .ageOfEmpiresII: "Town centers advancing through the ages"
        case .minecraft: "A survivor gearing up from spawn to the End"
        }
    }
}

struct CompanionVariant: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
}

enum CompanionCatalog {
    static func variants(for theme: CompanionTheme) -> [CompanionVariant] {
        switch theme {
        case .none:
            []
        case .pokemon:
            named([
                "Bulbasaur", "Charmander", "Squirtle",
                "Chikorita", "Cyndaquil", "Totodile",
                "Treecko", "Torchic", "Mudkip",
                "Turtwig", "Chimchar", "Piplup"
            ])
        case .forest:
            named(["Wildwood"])
        case .village:
            named(["Riverstead"])
        case .oldSchoolRuneScape:
            named(["Ranger"])
        case .ageOfEmpiresII:
            named(["Town Center"])
        case .minecraft:
            named(["Steve"])
        }
    }

    static func variant(
        for theme: CompanionTheme,
        seed: UInt64,
        date: Date,
        calendar: Calendar
    ) -> CompanionVariant? {
        let variants = variants(for: theme)
        guard !variants.isEmpty else { return nil }
        let index = CompanionDailyVariantSelector.index(
            theme: theme,
            seed: seed,
            date: date,
            calendar: calendar,
            variantCount: variants.count
        )
        return variants[index]
    }

    private static func named(_ titles: [String]) -> [CompanionVariant] {
        titles.map { title in
            CompanionVariant(
                id: title.lowercased().replacingOccurrences(of: " ", with: "-"),
                title: title
            )
        }
    }
}
