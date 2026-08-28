import Foundation

enum CompanionDailyVariantSelector {
    static func index(
        theme: CompanionTheme,
        seed: UInt64,
        date: Date,
        calendar: Calendar,
        variantCount: Int
    ) -> Int {
        index(
            key: theme.rawValue,
            seed: seed,
            date: date,
            calendar: calendar,
            variantCount: variantCount
        )
    }

    /// Deterministic daily pick from `variantCount` options for any keyed
    /// rotation. Distinct keys rotate independently, so the day's scenery
    /// never correlates with the day's Pokémon family.
    static func index(
        key: String,
        seed: UInt64,
        date: Date,
        calendar: Calendar,
        variantCount: Int
    ) -> Int {
        guard variantCount > 1 else { return 0 }
        let day = dayOrdinal(for: date, calendar: calendar)
        let position = CompanionMath.positiveModulo(day, variantCount)
        return permutation(count: variantCount, seed: seed ^ CompanionHash.fnv1a(key))[position]
    }

    private static func dayOrdinal(for date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let day = calendar.date(from: components) ?? calendar.startOfDay(for: date)
        // The reference date is 2001-01-01, so the fallback is the anchor
        // itself for any calendar that cannot compose the components.
        let anchor = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1))
            ?? Date(timeIntervalSinceReferenceDate: 0)
        return calendar.dateComponents([.day], from: anchor, to: day).day ?? 0
    }

    private static func permutation(count: Int, seed: UInt64) -> [Int] {
        var values = Array(0..<count)
        var generator = SplitMix64(state: seed)
        guard count > 1 else { return values }
        for upper in stride(from: count - 1, through: 1, by: -1) {
            let index = Int(generator.next() % UInt64(upper + 1))
            values.swapAt(upper, index)
        }
        return values
    }
}
