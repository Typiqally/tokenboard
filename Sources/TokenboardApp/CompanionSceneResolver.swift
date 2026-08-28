import Foundation

/// The motion layer's constants, drawn once per scene instead of once per
/// frame. Each resolved field freezes its emitter's seeded rolls — phases,
/// origins, jitters, shaded tints — in exactly the order the per-frame code
/// draws them, so a resolved frame is bit-identical to an unresolved one
/// (pinned by CompanionSceneFramePinTests); `frame(at:)` then computes only
/// the time-varying math into pre-sized arrays.

// MARK: - Wind

/// The forest's wind, shared by the canopy sway and the gust-coupled
/// emitters. Lives outside CompanionSceneMotion so the resolver and the
/// per-frame vocabulary depend on it without depending on each other.
enum CompanionWind {
    /// Two gust fronts on incommensurate periods, so the wind arrives at
    /// irregular intervals and the canopy is genuinely still in between.
    static func gustStrength(at x: Double, elapsed: Double) -> Double {
        func front(period: Double, offset: Double, spread: Double) -> Double {
            let travel = CompanionMath.fraction(elapsed / period + offset)
            let position = -0.45 + 1.9 * travel
            let distance = (x - position) / spread
            return exp(-distance * distance)
        }
        return min(1, front(period: 9.6, offset: 0, spread: 0.30)
            + 0.75 * front(period: 14.3, offset: 0.37, spread: 0.22))
    }
}

// MARK: - Particles

struct CompanionResolvedParticleField: Equatable, Sendable {
    struct Constants: Equatable, Sendable {
        let phase: Double
        let originX: Double
        let originY: Double
        let baseSize: Double
        let baseOpacity: Double
        let swayPhase: Double
        let spin: Double
    }

    let field: CompanionParticleField
    let constants: [Constants]

    init(field: CompanionParticleField, seed: UInt64) {
        self.field = field
        self.constants = (0..<field.count).map { index in
            var rng = SplitMix64(
                state: seed
                    ^ CompanionHash.fnv1a(field.key)
                    &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15
            )
            let phase = rng.unit()
            let originX = rng.range(field.spawnX.lowerBound, field.spawnX.upperBound)
            let originY = rng.range(field.spawnY.lowerBound, field.spawnY.upperBound)
            let baseSize = rng.range(field.size.lowerBound, field.size.upperBound)
            let baseOpacity = rng.range(field.opacity.lowerBound, field.opacity.upperBound)
            let swayPhase = rng.unit()
            let spin = rng.range(-1, 1)
            return Constants(
                phase: phase,
                originX: originX,
                originY: originY,
                baseSize: baseSize,
                baseOpacity: baseOpacity,
                swayPhase: swayPhase,
                spin: spin
            )
        }
    }

    func append(at elapsed: Double, into particles: inout [CompanionParticle]) {
        for constant in constants {
            let life = CompanionMath.fraction(elapsed / field.lifetime + constant.phase)
            var x = constant.originX
            var y = constant.originY
            if case let .travel(dx, dy, sway, swayPeriod) = field.drift {
                x += dx * life
                y += dy * life
                if sway != 0 {
                    x += sway * sin(
                        2 * .pi * CompanionMath.fraction(elapsed / swayPeriod + constant.swayPhase)
                    )
                }
            }

            var alpha: Double
            switch field.fade {
            case .inOut:
                // Flat through the middle of the path and steep at its ends,
                // so a particle is fully present for most of its life and
                // genuinely invisible where its path loops.
                alpha = constant.baseOpacity * pow(sin(.pi * life), 1.6)
            case .rise:
                // Squared ramp-in: an ember or a wisp of smoke is born
                // invisibly at its source rather than popping into view.
                let born = pow(min(1, life / 0.15), 2)
                alpha = constant.baseOpacity * born * pow(1 - life, 1.3)
            case let .twinkle(period):
                let pulse = 0.5 + 0.5 * sin(
                    2 * .pi * CompanionMath.fraction(elapsed / period + constant.swayPhase)
                )
                // A twinkle that stays put pulses forever. One that travels
                // still has to fade in and out at the ends of its path, or it
                // would jump back to its start in full view.
                let travelling = field.drift != .fixed
                alpha = constant.baseOpacity
                    * (0.25 + 0.75 * pulse)
                    * (travelling ? sin(.pi * life) : 1)
            }

            if field.coupling == .gust {
                // Barely a trickle in still air, a shower where the gust is.
                alpha *= 0.10 + 0.90 * CompanionWind.gustStrength(
                    at: x,
                    elapsed: elapsed
                )
            }

            particles.append(CompanionParticle(
                x: x,
                y: y,
                // A wingbeat runs on its own clock, not the particle's path,
                // so a bird crossing the sky still beats its wings.
                phase: CompanionMath.fraction(elapsed / 0.62 + constant.swayPhase),
                size: constant.baseSize * (1 + (field.growth - 1) * life),
                opacity: max(0, alpha),
                rotation: field.shape == .leaf
                    ? constant.spin * 55 + life * 220 * constant.spin
                    : 0,
                shape: field.shape,
                tint: field.tint,
                snapsToPixelGrid: field.snapsToPixelGrid
            ))
        }
    }
}

// MARK: - Shadow bands

struct CompanionResolvedBandField: Equatable, Sendable {
    struct Constants: Equatable, Sendable {
        let phase: Double
        /// The band's own width and opacity, jitter already applied.
        let width: Double
        let opacity: Double
    }

    let field: CompanionShadowBandField
    let constants: [Constants]

    init(field: CompanionShadowBandField, seed: UInt64) {
        self.field = field
        self.constants = (0..<field.count).map { index in
            var rng = SplitMix64(
                state: seed
                    ^ CompanionHash.fnv1a(field.key)
                    &+ UInt64(index) &* 0xBF58_476D_1CE4_E5B9
            )
            let phase = rng.unit()
            return Constants(
                phase: phase,
                width: field.width * rng.range(0.85, 1.2),
                opacity: field.opacity * rng.range(0.75, 1.15)
            )
        }
    }

    func append(at elapsed: Double, into bands: inout [CompanionShadowBand]) {
        for constant in constants {
            let travel = CompanionMath.fraction(elapsed / field.period + constant.phase)
            bands.append(CompanionShadowBand(
                // The sweep spans the field's nominal width; only the band
                // itself carries the per-index jitter.
                centerX: -0.5 - field.width / 2 + (2 + field.width) * travel,
                width: constant.width,
                skew: field.skew,
                opacity: constant.opacity,
                top: field.top,
                bottom: field.bottom,
                tint: field.tint
            ))
        }
    }
}

// MARK: - Glows

struct CompanionResolvedGlow: Equatable, Sendable {
    let spec: CompanionGlowSpec
    let phase: Double

    init(spec: CompanionGlowSpec, seed: UInt64) {
        self.spec = spec
        var rng = SplitMix64(state: seed ^ CompanionHash.fnv1a(spec.key))
        self.phase = rng.unit()
    }

    func glow(at elapsed: Double) -> CompanionGlow {
        // Two incommensurate waves so a flame never reads as a loop.
        let slow = sin(2 * .pi * CompanionMath.fraction(elapsed / spec.flickerPeriod + phase))
        let fast = sin(2 * .pi * CompanionMath.fraction(elapsed / (spec.flickerPeriod * 0.37) + phase))
        let flicker = 0.65 * slow + 0.35 * fast
        return CompanionGlow(
            x: spec.x,
            y: spec.y,
            radius: spec.radius * (1 + 0.08 * flicker),
            tint: spec.tint,
            opacity: max(0, spec.opacity * (1 + spec.flickerDepth * flicker))
        )
    }
}

// MARK: - Actors

struct CompanionResolvedActorField: Equatable, Sendable {
    struct Constants: Equatable, Sendable {
        let phase: Double
        let tempo: Double
        let height: Double
        let anchorJitter: CompanionScenePoint
        let targetJitter: CompanionScenePoint
        /// The inhabitant's own colours, shade already applied.
        let tint: CompanionSceneTint
        let accent: CompanionSceneTint
        let reversed: Bool
    }

    let field: CompanionActorField
    let constants: [Constants]

    init(field: CompanionActorField, seed: UInt64) {
        self.field = field
        self.constants = (0..<field.count).map { index in
            var rng = SplitMix64(
                state: seed
                    ^ CompanionHash.fnv1a(field.key)
                    &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15
            )
            let phase = rng.unit()
            let tempo = rng.range(0.84, 1.24)
            let height = rng.range(field.height.lowerBound, field.height.upperBound)
            let anchorJitter = CompanionScenePoint(
                rng.range(-field.spread, field.spread),
                rng.range(-field.spread * 0.12, field.spread * 0.12)
            )
            let targetJitter = CompanionScenePoint(
                rng.range(-field.spread, field.spread),
                rng.range(-field.spread * 0.12, field.spread * 0.12)
            )
            let shade = rng.range(1 - field.variation, 1 + field.variation)
            return Constants(
                phase: phase,
                tempo: tempo,
                height: height,
                anchorJitter: anchorJitter,
                targetJitter: targetJitter,
                tint: field.tint.shaded(by: shade),
                accent: field.accent.shaded(by: shade),
                // Half a population walks the other way, so a street or a
                // tile diagonal carries traffic in both directions.
                reversed: index % 2 == 1
            )
        }
    }

    func append(at elapsed: Double, into actors: inout [CompanionActor]) {
        for constant in constants {
            let now = CompanionActorRouting.place(
                route: field.route,
                elapsed: elapsed,
                phase: constant.phase,
                tempo: constant.tempo,
                anchorJitter: constant.anchorJitter,
                targetJitter: constant.targetJitter,
                reversed: constant.reversed
            )
            let next = CompanionActorRouting.place(
                route: field.route,
                elapsed: elapsed + CompanionSceneMotion.frameInterval,
                phase: constant.phase,
                tempo: constant.tempo,
                anchorJitter: constant.anchorJitter,
                targetJitter: constant.targetJitter,
                reversed: constant.reversed
            )
            let travel = CompanionScenePoint(
                next.point.x - now.point.x,
                next.point.y - now.point.y
            )
            let speed = now.speed ?? min(
                1,
                (travel.x * travel.x + travel.y * travel.y).squareRoot()
                    / CompanionSceneMotion.frameInterval
                    / CompanionActorRouting.referenceSpeed
            )
            let facing = now.facing ?? (travel.x < -1e-9 ? -1 : 1)

            actors.append(CompanionActor(
                x: now.point.x,
                y: now.point.y,
                height: constant.height,
                facing: facing,
                stride: now.stride
                    ?? CompanionMath.fraction(
                        elapsed * field.body.cadence * constant.tempo + constant.phase
                    ),
                speed: speed,
                lift: now.lift,
                pose: now.pose,
                body: field.body,
                tint: constant.tint,
                accent: constant.accent,
                opacity: field.opacity,
                snapsToPixelGrid: field.snapsToPixelGrid,
                drawsAttention: field.drawsAttention
            ))
        }
    }
}

// MARK: - Plan

/// A scene plan with every seeded constant already drawn. Built once per
/// composition; each frame only advances time.
struct CompanionResolvedScenePlan: Equatable, Sendable {
    let plan: CompanionScenePlan
    private let particleFields: [CompanionResolvedParticleField]
    private let bandFields: [CompanionResolvedBandField]
    private let glows: [CompanionResolvedGlow]
    private let actorFields: [CompanionResolvedActorField]
    private let particleCapacity: Int
    private let bandCapacity: Int
    private let actorCapacity: Int

    init(plan: CompanionScenePlan) {
        self.plan = plan
        self.particleFields = plan.fields.map {
            CompanionResolvedParticleField(field: $0, seed: plan.seed)
        }
        self.bandFields = plan.bands.map {
            CompanionResolvedBandField(field: $0, seed: plan.seed)
        }
        self.glows = plan.glows.map {
            CompanionResolvedGlow(spec: $0, seed: plan.seed)
        }
        self.actorFields = plan.actors.map {
            CompanionResolvedActorField(field: $0, seed: plan.seed)
        }
        self.particleCapacity = plan.fields.reduce(0) { $0 + $1.count }
        self.bandCapacity = plan.bands.reduce(0) { $0 + $1.count }
        self.actorCapacity = plan.actors.reduce(0) { $0 + $1.count }
    }

    /// Resolves the plan at a moment. `isMoving == false` produces the
    /// scene's deliberate still: the atmosphere and its inhabitants are
    /// composed and drawn, nothing runs.
    func frame(at elapsed: Double, isMoving: Bool) -> CompanionSceneFrame {
        let time = isMoving
            ? elapsed
            : CompanionSceneMotion.stillElapsed(for: plan.signature)

        var inhabitants: [CompanionActor] = []
        inhabitants.reserveCapacity(actorCapacity)
        for field in actorFields {
            field.append(at: time, into: &inhabitants)
        }

        var particles: [CompanionParticle] = []
        particles.reserveCapacity(particleCapacity)
        for field in particleFields {
            field.append(at: time, into: &particles)
        }

        var bands: [CompanionShadowBand] = []
        bands.reserveCapacity(bandCapacity)
        for field in bandFields {
            field.append(at: time, into: &bands)
        }

        return CompanionSceneFrame(
            particles: particles,
            bands: bands,
            glows: glows.map { $0.glow(at: time) },
            actors: inhabitants,
            attention: CompanionAttention(
                positions: inhabitants.filter(\.drawsAttention).map(\.x)
            ),
            wash: isMoving
                ? (plan.wash?.wash(at: time) ?? .none)
                : (plan.wash?.resting ?? .none),
            background: isMoving
                ? CompanionSceneMotion.background(drift: plan.backgroundDrift, elapsed: time)
                : .still
        )
    }
}
