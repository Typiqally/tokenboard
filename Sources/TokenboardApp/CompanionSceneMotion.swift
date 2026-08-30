import CoreGraphics
import Foundation

// MARK: - Vocabulary

/// What a scene layer *is*, so motion can address subjects by role instead of
/// by draw order. A tree bends in the wind; a building never does.
enum CompanionSubjectRole: String, Equatable, Sendable {
    case creature
    case adventurer
    case survivor
    case tree
    case building
}

/// The motion language a theme speaks. Each signature is a different idea of
/// what "alive" means in that world — not a different amplitude of one idle.
enum CompanionMotionSignature: String, CaseIterable, Equatable, Sendable {
    case none
    /// Pokémon: a partner that breathes, and now and then hops.
    case creatureIdle
    /// Forest: the canopy is still until a gust crosses it.
    case windGusts
    /// Village: buildings never sway. Chimneys, traffic, and windows live.
    case townLife
    /// Old School RuneScape: the world advances in 0.6-second game ticks.
    case gameTick
    /// Age of Empires II: an isometric diorama under a moving sky.
    case isometricDaylight
    /// Minecraft: square particles native to the biome, and stepped motion.
    case blockyBiome
    /// Banished: the settlement breathes with work, weather, and the year.
    case seasonalSettlement
    /// Frostpunk: furnace light, relentless snow, steam, and survival shifts.
    case frozenIndustry

    static func of(_ theme: CompanionTheme) -> CompanionMotionSignature {
        switch theme {
        case .none: .none
        case .pokemon: .creatureIdle
        case .forest: .windGusts
        case .village: .townLife
        case .oldSchoolRuneScape: .gameTick
        case .ageOfEmpiresII: .isometricDaylight
        case .minecraft: .blockyBiome
        case .banished: .seasonalSettlement
        case .frostpunk: .frozenIndustry
        }
    }
}

/// Linear RGB in 0...1, kept free of SwiftUI so the motion model stays a pure
/// value layer the tests can exercise off the main actor.
struct CompanionSceneTint: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// How a particle is drawn. Shape is art direction, not decoration: the pixel
/// worlds only ever emit hard squares, the photographic worlds emit soft motes.
enum CompanionParticleShape: String, Equatable, Sendable, CaseIterable {
    /// Soft round dot with a falloff — pollen, dust, spores.
    case mote
    /// Hard axis-aligned square — every pixel-art and Minecraft particle.
    case pixel
    /// Small tilted rectangle that turns as it falls.
    case leaf
    /// Bright core with a warm halo — embers, fireflies, crystal sparks.
    case ember
    /// Short horizontal bar — vehicle lights along a street.
    case streak
    /// Two-stroke "V" — a distant bird.
    case chevron
}

/// How a particle travels over its lifetime.
enum CompanionParticleDrift: Equatable, Sendable {
    /// Constant travel across the scene with an optional lateral wobble.
    case travel(dx: Double, dy: Double, sway: Double, swayPeriod: Double)
    /// Never moves; only its opacity changes (stars, lit windows).
    case fixed
}

/// What a field answers to beyond its own lifetime.
enum CompanionParticleCoupling: String, Equatable, Sendable {
    case none
    /// Present only where the wind currently is. A canopy sheds where the
    /// gust is crossing it, never evenly across the whole wood.
    case gust
}

/// How a particle's opacity behaves over its lifetime.
enum CompanionParticleFade: Equatable, Sendable {
    /// Fades in at birth and out at death, so the loop seam is invisible.
    case inOut
    /// Full at birth, thinning toward death — smoke and embers.
    case rise
    /// Ignores lifetime and pulses on its own period.
    case twinkle(period: Double)
}

/// A declarative particle emitter. Resolving it at a time is a pure function,
/// so a field is fully reproducible from the install's companion seed.
struct CompanionParticleField: Equatable, Sendable {
    let key: String
    let shape: CompanionParticleShape
    let tint: CompanionSceneTint
    let count: Int
    /// Seconds for one particle to travel its whole path.
    let lifetime: Double
    let spawnX: ClosedRange<Double>
    let spawnY: ClosedRange<Double>
    /// Diameter in points at the reference 84-point scene height.
    let size: ClosedRange<Double>
    let opacity: ClosedRange<Double>
    let drift: CompanionParticleDrift
    let fade: CompanionParticleFade
    /// What else has to be true for this particle to be visible at all.
    let coupling: CompanionParticleCoupling
    /// Size multiplier reached at the end of life (smoke swells, sparks don't).
    let growth: Double
    /// Pixel-art worlds snap their particles to the plate's own art-pixel
    /// grid, so nothing drawn on top of them reads as a smoother resolution.
    let snapsToPixelGrid: Bool

    init(
        key: String,
        shape: CompanionParticleShape,
        tint: CompanionSceneTint,
        count: Int,
        lifetime: Double,
        spawnX: ClosedRange<Double>,
        spawnY: ClosedRange<Double>,
        size: ClosedRange<Double>,
        opacity: ClosedRange<Double>,
        drift: CompanionParticleDrift,
        fade: CompanionParticleFade = .inOut,
        coupling: CompanionParticleCoupling = .none,
        growth: Double = 1,
        snapsToPixelGrid: Bool = false
    ) {
        self.key = key
        self.shape = shape
        self.tint = tint
        self.count = max(0, count)
        self.lifetime = max(0.001, lifetime)
        self.spawnX = spawnX
        self.spawnY = spawnY
        self.size = size
        self.opacity = opacity
        self.drift = drift
        self.fade = fade
        self.coupling = coupling
        self.growth = growth
        self.snapsToPixelGrid = snapsToPixelGrid
    }

    /// The field's particles at a moment, in scene-normalized coordinates.
    /// Convenience over the resolver for tests and one-off reads; the render
    /// path resolves once and reuses `CompanionResolvedParticleField`.
    func particles(at elapsed: Double, seed: UInt64) -> [CompanionParticle] {
        var particles: [CompanionParticle] = []
        particles.reserveCapacity(count)
        CompanionResolvedParticleField(field: self, seed: seed)
            .append(at: elapsed, into: &particles)
        return particles
    }
}

/// One resolved particle, ready to draw.
struct CompanionParticle: Equatable, Sendable {
    let x: Double
    let y: Double
    /// A 0..<1 cycle the renderer can use for shape-specific animation.
    let phase: Double
    let size: Double
    let opacity: Double
    let rotation: Double
    let shape: CompanionParticleShape
    let tint: CompanionSceneTint
    let snapsToPixelGrid: Bool
}

/// A slow shadow or light band sweeping across the scene — cloud shadows over
/// an isometric map, mist rolling through a swamp.
struct CompanionShadowBandField: Equatable, Sendable {
    let key: String
    let count: Int
    let width: Double
    /// Horizontal offset between the band's top and bottom edge. Negative
    /// values lean the band along an isometric tile diagonal.
    let skew: Double
    let period: Double
    let opacity: Double
    let tint: CompanionSceneTint
    let top: Double
    let bottom: Double

    func bands(at elapsed: Double, seed: UInt64) -> [CompanionShadowBand] {
        var bands: [CompanionShadowBand] = []
        bands.reserveCapacity(count)
        CompanionResolvedBandField(field: self, seed: seed)
            .append(at: elapsed, into: &bands)
        return bands
    }
}

struct CompanionShadowBand: Equatable, Sendable {
    let centerX: Double
    let width: Double
    let skew: Double
    let opacity: Double
    let top: Double
    let bottom: Double
    let tint: CompanionSceneTint
}

/// A fixed light source in the scene that breathes — a torch in a tomb, a
/// forge in a castle town, an End crystal.
struct CompanionGlowSpec: Equatable, Sendable {
    let key: String
    let x: Double
    let y: Double
    /// Radius in points at the reference 84-point scene height.
    let radius: Double
    let tint: CompanionSceneTint
    let opacity: Double
    let flickerDepth: Double
    let flickerPeriod: Double

    func glow(at elapsed: Double, seed: UInt64) -> CompanionGlow {
        CompanionResolvedGlow(spec: self, seed: seed).glow(at: elapsed)
    }
}

struct CompanionGlow: Equatable, Sendable {
    let x: Double
    let y: Double
    let radius: Double
    let tint: CompanionSceneTint
    let opacity: Double
}

/// A whole-scene colour wash. Used sparingly: the sun warming a meadow, a
/// gust dimming a forest, a Nether cavern pulsing.
struct CompanionWashSpec: Equatable, Sendable {
    let tint: CompanionSceneTint
    let opacity: Double
    let amplitude: Double
    let period: Double

    func wash(at elapsed: Double) -> CompanionWash {
        let wave = sin(2 * .pi * CompanionMath.fraction(elapsed / period))
        return CompanionWash(
            tint: tint,
            opacity: max(0, opacity + amplitude * wave)
        )
    }

    /// The wash a still scene shows: the middle of its range, never a peak.
    var resting: CompanionWash {
        CompanionWash(tint: tint, opacity: max(0, opacity))
    }
}

struct CompanionWash: Equatable, Sendable {
    let tint: CompanionSceneTint
    let opacity: Double

    static let none = CompanionWash(tint: CompanionSceneTint(0, 0, 0), opacity: 0)
}

/// How the background plate itself moves.
enum CompanionBackgroundDrift: Equatable, Sendable {
    case still
    /// A long, non-repeating camera wander over an isometric map.
    case isometricWander
}

struct CompanionBackgroundMotion: Equatable, Sendable {
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    var scale: CGFloat = 1
    var brightness: Double = 0

    static let still = CompanionBackgroundMotion()
}

/// How one subject layer is transformed this frame.
struct CompanionSubjectMotion: Equatable, Hashable, Sendable {
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var rotation: Double = 0
    var brightness: Double = 0
    var flipped: Bool = false
    var shadowScale: CGFloat = 1
    var shadowOpacity: Double = 1

    static let still = CompanionSubjectMotion()
}

// MARK: - Plan and frame

/// Everything a scene animates, resolved once per scene rather than per frame.
struct CompanionScenePlan: Equatable, Sendable {
    let signature: CompanionMotionSignature
    let stage: Int
    let seed: UInt64
    let backgroundDrift: CompanionBackgroundDrift
    let fields: [CompanionParticleField]
    let bands: [CompanionShadowBandField]
    let glows: [CompanionGlowSpec]
    /// Who lives here. A world with weather but no inhabitants is scenery;
    /// a world with errands running through it is a place.
    let actors: [CompanionActorField]
    let wash: CompanionWashSpec?

    init(
        signature: CompanionMotionSignature,
        stage: Int,
        seed: UInt64,
        backgroundDrift: CompanionBackgroundDrift,
        fields: [CompanionParticleField],
        bands: [CompanionShadowBandField],
        glows: [CompanionGlowSpec],
        actors: [CompanionActorField] = [],
        wash: CompanionWashSpec?
    ) {
        self.signature = signature
        self.stage = stage
        self.seed = seed
        self.backgroundDrift = backgroundDrift
        self.fields = fields
        self.bands = bands
        self.glows = glows
        self.actors = actors
        self.wash = wash
    }

    static let inert = CompanionScenePlan(
        signature: .none,
        stage: 0,
        seed: 0,
        backgroundDrift: .still,
        fields: [],
        bands: [],
        glows: [],
        wash: nil
    )

    /// Resolves the plan at a moment. Convenience over the resolver for tests
    /// and one-off reads; the render path builds one CompanionResolvedScenePlan
    /// per composition and advances only time.
    func frame(at elapsed: Double, isMoving: Bool) -> CompanionSceneFrame {
        CompanionResolvedScenePlan(plan: self).frame(at: elapsed, isMoving: isMoving)
    }
}

struct CompanionSceneFrame: Equatable, Sendable {
    let particles: [CompanionParticle]
    let bands: [CompanionShadowBand]
    let glows: [CompanionGlow]
    let actors: [CompanionActor]
    /// Where the scene's own subjects should be looking this frame.
    let attention: CompanionAttention
    let wash: CompanionWash
    let background: CompanionBackgroundMotion
}

// MARK: - Resolver

enum CompanionSceneMotion {
    /// 30 Hz. Enough for drifting particles to read as continuous, cheap
    /// enough for a menu-bar app that only draws while a scene is on screen.
    static let frameInterval: Double = 1.0 / 30.0

    /// Old School RuneScape's game tick. Every pose change lands on one.
    static let gameTick: Double = 0.6

    static func elapsed(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate
    }

    /// The moment a paused or Reduced Motion scene is composed at. Chosen per
    /// world so the still still looks authored: leaves mid-fall, a cloud
    /// shadow a third of the way across, embers spread through the air.
    static func stillElapsed(for signature: CompanionMotionSignature) -> Double {
        switch signature {
        case .none: 0
        case .creatureIdle: 4.1
        case .windGusts: 6.2
        case .townLife: 11.0
        case .gameTick: 8.4
        case .isometricDaylight: 13.7
        case .blockyBiome: 5.5
        case .seasonalSettlement: 17.2
        case .frozenIndustry: 15.6
        }
    }

    static func background(
        drift: CompanionBackgroundDrift,
        elapsed: Double
    ) -> CompanionBackgroundMotion {
        switch drift {
        case .still:
            return .still
        case .isometricWander:
            // Three incommensurate periods: the camera never returns to the
            // same place twice within a session.
            let x = sin(2 * .pi * elapsed / 23.7)
            let y = sin(2 * .pi * elapsed / 17.3 + 0.9)
            let zoom = sin(2 * .pi * elapsed / 31.1)
            return CompanionBackgroundMotion(
                offsetX: 1.7 * x,
                offsetY: -0.85 * y,
                scale: 1.012 + 0.004 * zoom,
                brightness: 0.005 * zoom
            )
        }
    }

    /// How one subject layer moves this frame. `attention` carries the
    /// inhabitants worth noticing, so a world's foreground can react to what
    /// is walking through it instead of idling past it.
    static func subject(
        signature: CompanionMotionSignature,
        role: CompanionSubjectRole,
        index: Int,
        horizontalPosition: Double,
        relativeHeight: Double,
        seed: UInt64,
        elapsed: Double,
        isMoving: Bool,
        attention: CompanionAttention = .none
    ) -> CompanionSubjectMotion {
        guard isMoving else { return .still }
        let watched = attention.nearest(to: horizontalPosition)
        switch signature {
        case .none, .isometricDaylight, .seasonalSettlement, .frozenIndustry:
            return .still
        case .creatureIdle:
            return creatureIdle(
                index: index,
                seed: seed,
                elapsed: elapsed,
                notice: interest(in: watched, from: horizontalPosition, within: 0.17)
            )
        case .windGusts:
            return canopy(
                index: index,
                horizontalPosition: horizontalPosition,
                relativeHeight: relativeHeight,
                seed: seed,
                elapsed: elapsed
            )
        case .townLife:
            // Deliberately still. A building does not sway; the town's life
            // is its windows, its chimneys, and its traffic.
            return .still
        case .gameTick:
            guard role == .adventurer else { return .still }
            var pose = tickIdle(seed: seed, elapsed: elapsed)
            // The adventurer turns to whoever just walked past — on the tick,
            // like every other pose change in that world.
            if let watched, abs(watched - horizontalPosition) < 0.34 {
                pose.flipped = watched < horizontalPosition
            }
            return pose
        case .blockyBiome:
            var pose = steppedIdle(elapsed: elapsed)
            if let watched, abs(watched - horizontalPosition) < 0.42 {
                pose.flipped = watched < horizontalPosition
            }
            return pose
        }
    }

    /// How interesting something at `watched` is to a subject standing at
    /// `origin`: 1 right beside it, 0 at the edge of noticing.
    private static func interest(
        in watched: Double?,
        from origin: Double,
        within radius: Double
    ) -> Double {
        guard let watched, radius > 0 else { return 0 }
        return max(0, 1 - abs(watched - origin) / radius)
    }

    // MARK: Subject stream keys

    /// Constant subject keys, hashed once instead of per subject per frame.
    private static let pokemonIdleHash = CompanionHash.fnv1a("pokemon/idle")
    private static let forestSwayHash = CompanionHash.fnv1a("forest/sway")
    private static let osrsTickHash = CompanionHash.fnv1a("osrs/tick")

    // MARK: Pokémon — breathe, then hop

    private static let breathPeriod = 3.4
    private static let hopPeriod = 7.6
    private static let hopRise: CGFloat = 5.0

    private static func creatureIdle(
        index: Int,
        seed: UInt64,
        elapsed: Double,
        notice: Double
    ) -> CompanionSubjectMotion {
        var rng = SplitMix64(
            state: seed ^ pokemonIdleHash &+ UInt64(index) &* 977
        )
        let breathPhase = rng.unit()
        let hopPhase = rng.unit()

        // Breathing is asymmetric — a quick draw in, a longer let out — so it
        // never reads as a sine wave applied to a picture.
        let p = CompanionMath.fraction(elapsed / breathPeriod + breathPhase)
        let breath = p < 0.4
            ? sin(p / 0.4 * .pi / 2)
            : cos((p - 0.4) / 0.6 * .pi / 2)

        let u = CompanionMath.fraction(elapsed / hopPeriod + hopPhase) * hopPeriod
        var lift: CGFloat = 0
        var squash: CGFloat = 0
        if u < 0.12 {
            squash = -0.07 * CGFloat(u / 0.12)
        } else if u < 0.42 {
            let a = (u - 0.12) / 0.30
            lift = hopRise * CGFloat(sin(a * .pi))
            squash = 0.05 * CGFloat(sin(a * .pi))
        } else if u < 0.62 {
            let b = (u - 0.42) / 0.20
            squash = -0.06 * CGFloat(sin(b * .pi))
        }

        // Something crossing the meadow within reach is worth standing up
        // for: the partner perks on a quicker beat until it has passed.
        let perk = notice
            * (0.5 + 0.5 * sin(2 * .pi * CompanionMath.fraction(elapsed / 1.15)))

        let airborne = Double(lift / hopRise)
        return CompanionSubjectMotion(
            offsetX: 0,
            offsetY: -lift - 0.55 * CGFloat(breath) - 1.5 * CGFloat(perk),
            scaleX: 1 - 0.010 * CGFloat(breath) - squash * 0.6 - 0.008 * CGFloat(perk),
            scaleY: 1 + 0.018 * CGFloat(breath) + squash + 0.014 * CGFloat(perk),
            rotation: 0,
            brightness: 0,
            flipped: false,
            shadowScale: 1 - 0.30 * CGFloat(airborne),
            shadowOpacity: 1 - 0.45 * airborne
        )
    }

    // MARK: Forest — a gust crosses the canopy

    /// Forwards to CompanionWind, where the gust model lives.
    static func gustStrength(at x: Double, elapsed: Double) -> Double {
        CompanionWind.gustStrength(at: x, elapsed: elapsed)
    }

    /// Tallest sprite height a growing pixel scene ever places, used to scale
    /// how much a given tree gives to the wind.
    private static let canopyReferenceHeight = 0.81

    private static func canopy(
        index: Int,
        horizontalPosition: Double,
        relativeHeight: Double,
        seed: UInt64,
        elapsed: Double
    ) -> CompanionSubjectMotion {
        var rng = SplitMix64(
            state: seed ^ forestSwayHash &+ UInt64(index) &* 6151
        )
        let rustlePhase = rng.unit()
        let stiffness = rng.range(0.82, 1.18)

        let reach = min(1, relativeHeight / canopyReferenceHeight)
        let gust = CompanionWind.gustStrength(at: horizontalPosition, elapsed: elapsed)
        // Saplings barely notice the wind; a full-grown pine leans into it.
        let bend = gust * (0.30 + 0.70 * reach) * 4.2 * stiffness
        let rustle = (0.18 + 0.45 * reach)
            * sin(2 * .pi * CompanionMath.fraction(elapsed / 4.9 + rustlePhase))

        return CompanionSubjectMotion(
            offsetX: 0,
            offsetY: 0,
            scaleX: 1,
            scaleY: 1 - 0.004 * gust * reach,
            rotation: bend + rustle,
            brightness: -0.012 * gust,
            flipped: false,
            shadowScale: 1,
            shadowOpacity: 1
        )
    }

    // MARK: Old School RuneScape — everything lands on a tick

    /// The adventurer's pose for the current game tick. Poses change only on
    /// tick boundaries; nothing interpolates.
    static func tickIdle(seed: UInt64, elapsed: Double) -> CompanionSubjectMotion {
        let tick = Int(floor(max(0, elapsed) / gameTick))
        let beat = tick / 4
        let step = tick % 4
        var rng = SplitMix64(
            state: seed ^ osrsTickHash &+ UInt64(beat) &* 0x9E37_79B9_7F4A_7C15
        )
        let action = rng.unit()
        let direction: CGFloat = rng.unit() < 0.5 ? -1 : 1

        if action < 0.52 {
            return .still
        }
        if action < 0.74 {
            // Shift weight for the middle two ticks of the beat.
            let shifted = step == 1 || step == 2
            return CompanionSubjectMotion(
                offsetX: shifted ? direction * 1.2 : 0,
                shadowScale: shifted ? 1.02 : 1
            )
        }
        if action < 0.88 {
            // Turn around, and stay turned for the whole beat.
            return CompanionSubjectMotion(flipped: true)
        }
        // A two-tick hop, hard-cut the way the game's own animations read.
        let up = step == 0 || step == 2
        return CompanionSubjectMotion(
            offsetY: up ? -2.0 : 0,
            shadowScale: up ? 0.9 : 1,
            shadowOpacity: up ? 0.75 : 1
        )
    }

    // MARK: Minecraft — a stepped, blocky idle

    private static let blockyStep = 0.28
    private static let blockyLift: [CGFloat] = [0, -1.0, -1.8, -1.0]
    private static let blockyShadow: [CGFloat] = [1, 0.97, 0.94, 0.97]

    static func steppedIdle(elapsed: Double) -> CompanionSubjectMotion {
        let step = CompanionMath.positiveModulo(
            Int(floor(max(0, elapsed) / blockyStep)),
            blockyLift.count
        )
        // No squash, no rotation: nothing in this world deforms.
        return CompanionSubjectMotion(
            offsetY: blockyLift[step],
            shadowScale: blockyShadow[step]
        )
    }
}

// MARK: - Village window lighting

/// One window found in a building sprite, in sprite-relative coordinates.
struct CompanionWindowCell: Equatable, Sendable {
    /// Left edge, 0...1 across the sprite.
    let x: Double
    /// Top edge, 0...1 down the sprite.
    let y: Double
    let width: Double
    let height: Double
    /// Whether the baked artwork already draws this window lit.
    let bakedLit: Bool
}

/// Whether a given window is lit right now.
///
/// The town's windows are not a brightness pulse over a whole building: each
/// window is its own room with its own evening, switching on and off on its
/// own schedule. Only a share of them ever change, so the skyline keeps the
/// silhouette the artwork baked and the changes read as somebody coming home.
enum CompanionWindowLighting {
    /// Share of a building's windows that belong to somebody still awake.
    /// The rest keep exactly the light the artwork baked, so the skyline
    /// stays the one that was drawn and the changes read as rooms, not noise.
    static let animatedShare = 0.32

    /// One window's whole evening, resolved once. The composition builds a
    /// schedule per window so drawing never re-seeds a generator per frame.
    enum Schedule: Equatable, Sendable {
        /// Keeps exactly the light the artwork baked, forever.
        case baked
        case animated(period: Double, duty: Double, phase: Double)

        func isLit(bakedLit: Bool, at elapsed: Double) -> Bool {
            switch self {
            case .baked:
                return bakedLit
            case let .animated(period, duty, phase):
                return CompanionMath.fraction(elapsed / period + phase) < duty
            }
        }
    }

    static func schedule(index: Int, layerID: String, seed: UInt64) -> Schedule {
        var rng = generator(index: index, layerID: layerID, seed: seed)
        guard rng.unit() < animatedShare else { return .baked }
        let period = rng.range(16, 44)
        let duty = rng.range(0.30, 0.70)
        let phase = rng.unit()
        return .animated(period: period, duty: duty, phase: phase)
    }

    static func isLit(
        cell: CompanionWindowCell,
        index: Int,
        layerID: String,
        seed: UInt64,
        elapsed: Double
    ) -> Bool {
        schedule(index: index, layerID: layerID, seed: seed)
            .isLit(bakedLit: cell.bakedLit, at: elapsed)
    }

    /// True when a window ever changes. Windows that never change are left to
    /// the baked artwork and are never redrawn.
    static func animates(index: Int, layerID: String, seed: UInt64) -> Bool {
        schedule(index: index, layerID: layerID, seed: seed) != .baked
    }

    private static func generator(
        index: Int,
        layerID: String,
        seed: UInt64
    ) -> SplitMix64 {
        SplitMix64(
            state: seed
                ^ CompanionHash.fnv1a("village/window/\(layerID)")
                &+ UInt64(index) &* 0x94D0_49BB_1331_11EB
        )
    }

    /// The palette the generated village artwork bakes its windows in, so a
    /// switched window is indistinguishable from a painted one.
    static let litTint = CompanionSceneTint(1.0, 217.0 / 255.0, 138.0 / 255.0)
    static let darkTint = CompanionSceneTint(46.0 / 255.0, 58.0 / 255.0, 84.0 / 255.0)
}
