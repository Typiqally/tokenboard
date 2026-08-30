/// The one home for the companion feature's deterministic math: every
/// rotation, layout draw, and motion constant derives from these primitives,
/// so two call sites given the same seed can never drift apart.

/// Duplicated in Scripts/generate-companion-artwork.swift, which cannot import
/// this module; CompanionRandomTests and the script's
/// verifyDeterminismContract() pin both copies to the same output vectors.
struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    /// Uniform value in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func range(_ low: Double, _ high: Double) -> Double {
        low + unit() * (high - low)
    }
}

/// One FNV-1a implementation for every deterministic companion rotation, so
/// seeds derived from a key never drift apart between call sites. Duplicated
/// as stableHash in Scripts/generate-companion-artwork.swift; both copies are
/// pinned to the same vectors by CompanionRandomTests and the script's
/// verifyDeterminismContract().
enum CompanionHash {
    static func fnv1a(_ string: String) -> UInt64 {
        string.utf8.reduce(14_695_981_039_346_656_037) { value, byte in
            (value ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}

enum CompanionMath {
    /// Fractional part in 0..<1 for any sign of input.
    static func fraction(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }

    static func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        guard modulus > 0 else { return 0 }
        let remainder = value % modulus
        return remainder >= 0 ? remainder : remainder + modulus
    }
}
