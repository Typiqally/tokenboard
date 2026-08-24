import Foundation

/// The inhabitants of a companion scene: the villagers, animals, and birds
/// that give a world an errand of its own rather than only weather.
///
/// Nothing here is a sprite. An inhabitant is a body plan plus a route, drawn
/// procedurally at the scene's own scale, so a world can be populated without
/// shipping another frame of artwork — and every position stays a pure
/// function of the install's companion seed and the clock.

// MARK: - Vocabulary

/// A point in scene-normalized coordinates: 0...1 across and down the band.
struct CompanionScenePoint: Equatable, Sendable {
    let x: Double
    let y: Double

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    func offset(by delta: CompanionScenePoint) -> CompanionScenePoint {
        CompanionScenePoint(x + delta.x, y + delta.y)
    }

    static func lerp(
        _ start: CompanionScenePoint,
        _ end: CompanionScenePoint,
        _ t: Double
    ) -> CompanionScenePoint {
        CompanionScenePoint(
            start.x + (end.x - start.x) * t,
            start.y + (end.y - start.y) * t
        )
    }
}

/// What an inhabitant is built out of. The body plan decides how the renderer
/// draws it — never which world it belongs to.
enum CompanionActorBody: String, Equatable, Sendable, CaseIterable {
    /// Upright figure: head, torso, swinging arm, two alternating legs.
    /// Villagers, townsfolk, other players, piglins.
    case biped
    /// Low four-legged body with a head out front. Sheep, chickens, pigs,
    /// deer, a stray dog on a street.
    case quadruped
    /// A small flier whose wings beat in the air and fold when it lands.
    case flier
}

/// What an inhabitant is doing at this moment.
enum CompanionActorPose: Equatable, Sendable {
    case walking
    /// Walking home under a load — the return half of a gatherer's errand.
    case carrying
    /// Standing at a work site. `swing` runs 0..<1 over one stroke.
    case working(swing: Double)
    case idle
    case perched
    case flying
}

/// How an inhabitant spends its time. Each case is a different world's idea
/// of purposeful movement, not a different speed of one walk.
enum CompanionActorRoute: Equatable, Sendable {
    /// Walks a straight line between two points, resting `pauses` times on
    /// the way. A street, a road, a foreground tile diagonal.
    case patrol(
        from: CompanionScenePoint,
        to: CompanionScenePoint,
        period: Double,
        pauses: Int
    )
    /// Leaves home, works a site, carries the load back, repeats. The loop a
    /// gathering villager has run since 1999.
    case errand(
        home: CompanionScenePoint,
        site: CompanionScenePoint,
        period: Double,
        workShare: Double
    )
    /// One whole tile per game tick and nothing in between, inside a pen.
    case ticked(
        pen: CompanionScenePoint,
        spanX: Double,
        spanY: Double,
        tile: Double
    )
    /// Mills about inside a pen. `linger` runs 0 (an even amble) to 1 (long
    /// stillness broken by a dash).
    case wander(
        pen: CompanionScenePoint,
        spanX: Double,
        spanY: Double,
        period: Double,
        linger: Double
    )
    /// Flies in from off frame, settles somewhere the layout actually put a
    /// perch, then carries on the way it came.
    case perch(
        at: CompanionScenePoint,
        approachFrom: CompanionScenePoint,
        period: Double,
        perchShare: Double
    )
}

/// One resolved inhabitant, ready to draw.
struct CompanionActor: Equatable, Sendable {
    /// Ground contact point, scene-normalized.
    let x: Double
    let y: Double
    /// Standing height in points at the reference 84-point scene height.
    let height: Double
    /// -1 faces left, +1 faces right.
    let facing: Double
    /// 0..<1 gait cycle.
    let stride: Double
    /// 0...1 of the body's own travelling pace. Limbs swing in proportion, so
    /// something that has stopped genuinely stands still.
    let speed: Double
    /// Height above the ground contact point, in reference points.
    let lift: Double
    let pose: CompanionActorPose
    let body: CompanionActorBody
    let tint: CompanionSceneTint
    let accent: CompanionSceneTint
    let opacity: Double
    let snapsToPixelGrid: Bool
    let drawsAttention: Bool
}

/// Where the scene's subjects should be looking. A world feels inhabited when
/// the thing in the foreground notices the thing walking past it.
struct CompanionAttention: Equatable, Sendable {
    let positions: [Double]

    static let none = CompanionAttention(positions: [])

    /// The nearest thing worth watching from a given position, if any.
    func nearest(to x: Double) -> Double? {
        positions.min { abs($0 - x) < abs($1 - x) }
    }
}

// MARK: - Field

/// A declarative population. Resolving it at a moment is a pure function, so
/// the same install always sees the same villagers on the same errands.
struct CompanionActorField: Equatable, Sendable {
    let key: String
    let body: CompanionActorBody
    let count: Int
    let route: CompanionActorRoute
    /// Standing height in points at the reference 84-point scene height.
    let height: ClosedRange<Double>
    let tint: CompanionSceneTint
    let accent: CompanionSceneTint
    let opacity: Double
    /// Per-inhabitant scatter applied to the route's anchors, so a population
    /// runs its own errands instead of one path walked in lockstep.
    let spread: Double
    /// How far each inhabitant's own colour may drift from the field's, so a
    /// street reads as a crowd rather than one figure stamped four times.
    let variation: Double
    let snapsToPixelGrid: Bool
    /// Whether the world's subject should notice this population.
    let drawsAttention: Bool

    init(
        key: String,
        body: CompanionActorBody,
        count: Int,
        route: CompanionActorRoute,
        height: ClosedRange<Double>,
        tint: CompanionSceneTint,
        accent: CompanionSceneTint,
        opacity: Double = 1,
        spread: Double = 0,
        variation: Double = 0.12,
        snapsToPixelGrid: Bool = false,
        drawsAttention: Bool = false
    ) {
        self.key = key
        self.body = body
        self.count = max(0, count)
        self.route = route
        self.height = height
        self.tint = tint
        self.accent = accent
        self.opacity = opacity
        self.spread = max(0, spread)
        self.variation = max(0, variation)
        self.snapsToPixelGrid = snapsToPixelGrid
        self.drawsAttention = drawsAttention
    }

    func actors(at elapsed: Double, seed: UInt64) -> [CompanionActor] {
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            var rng = SplitMix64(
                state: seed
                    ^ CompanionHash.fnv1a(key)
                    &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15
            )
            let phase = rng.unit()
            let tempo = rng.range(0.84, 1.24)
            let height = rng.range(self.height.lowerBound, self.height.upperBound)
            let anchorJitter = CompanionScenePoint(
                rng.range(-spread, spread),
                rng.range(-spread * 0.12, spread * 0.12)
            )
            let targetJitter = CompanionScenePoint(
                rng.range(-spread, spread),
                rng.range(-spread * 0.12, spread * 0.12)
            )
            let shade = rng.range(1 - variation, 1 + variation)
            // Half a population walks the other way, so a street or a tile
            // diagonal carries traffic in both directions.
            let reversed = index % 2 == 1

            let now = CompanionActorRouting.place(
                route: route,
                elapsed: elapsed,
                phase: phase,
                tempo: tempo,
                anchorJitter: anchorJitter,
                targetJitter: targetJitter,
                reversed: reversed
            )
            let next = CompanionActorRouting.place(
                route: route,
                elapsed: elapsed + CompanionSceneMotion.frameInterval,
                phase: phase,
                tempo: tempo,
                anchorJitter: anchorJitter,
                targetJitter: targetJitter,
                reversed: reversed
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

            return CompanionActor(
                x: now.point.x,
                y: now.point.y,
                height: height,
                facing: facing,
                stride: now.stride
                    ?? CompanionMath.fraction(elapsed * body.cadence * tempo + phase),
                speed: speed,
                lift: now.lift,
                pose: now.pose,
                body: body,
                tint: tint.shaded(by: shade),
                accent: accent.shaded(by: shade),
                opacity: opacity,
                snapsToPixelGrid: snapsToPixelGrid,
                drawsAttention: drawsAttention
            )
        }
    }
}

extension CompanionActorBody {
    /// Gait cycles per second at an ordinary pace.
    var cadence: Double {
        switch self {
        case .biped: 2.1
        case .quadruped: 3.0
        case .flier: 7.5
        }
    }
}

// MARK: - Routing

/// One inhabitant's state at a moment, before the field turns it into a
/// drawable actor. `nil` fields are the ones a route leaves to be derived
/// from how far the inhabitant actually moved.
struct CompanionActorPlacement: Equatable, Sendable {
    let point: CompanionScenePoint
    let pose: CompanionActorPose
    var facing: Double?
    var speed: Double?
    var stride: Double?
    var lift: Double = 0
}

enum CompanionActorRouting {
    /// Travel that counts as full pace, in scene widths per second.
    static let referenceSpeed = 0.11

    static func place(
        route: CompanionActorRoute,
        elapsed: Double,
        phase: Double,
        tempo: Double,
        anchorJitter: CompanionScenePoint,
        targetJitter: CompanionScenePoint,
        reversed: Bool
    ) -> CompanionActorPlacement {
        switch route {
        case let .patrol(from, to, period, pauses):
            return patrol(
                from: from.offset(by: anchorJitter),
                to: to.offset(by: targetJitter),
                period: period * tempo,
                pauses: pauses,
                elapsed: elapsed,
                phase: phase,
                reversed: reversed
            )
        case let .errand(home, site, period, workShare):
            return errand(
                home: home.offset(by: anchorJitter),
                site: site.offset(by: targetJitter),
                period: period * tempo,
                workShare: workShare,
                elapsed: elapsed,
                phase: phase
            )
        case let .ticked(pen, spanX, spanY, tile):
            return ticked(
                pen: pen.offset(by: anchorJitter),
                spanX: spanX,
                spanY: spanY,
                tile: tile,
                elapsed: elapsed,
                phase: phase
            )
        case let .wander(pen, spanX, spanY, period, linger):
            return wander(
                pen: pen.offset(by: anchorJitter),
                spanX: spanX,
                spanY: spanY,
                period: period * tempo,
                linger: linger,
                elapsed: elapsed,
                phase: phase
            )
        case let .perch(at, approachFrom, period, perchShare):
            return perch(
                at: at.offset(by: anchorJitter),
                approachFrom: approachFrom.offset(by: targetJitter),
                period: period * tempo,
                perchShare: perchShare,
                elapsed: elapsed,
                phase: phase
            )
        }
    }

    // MARK: Patrol

    private static func patrol(
        from: CompanionScenePoint,
        to: CompanionScenePoint,
        period: Double,
        pauses: Int,
        elapsed: Double,
        phase: Double,
        reversed: Bool
    ) -> CompanionActorPlacement {
        let start = reversed ? to : from
        let end = reversed ? from : to
        let cycle = CompanionMath.fraction(elapsed / max(0.001, period) + phase)
        let walk = progress(along: cycle, pauses: pauses)
        // A figure that has stopped to talk keeps facing the way it was going.
        let facing: Double = end.x >= start.x ? 1 : -1
        return CompanionActorPlacement(
            point: .lerp(start, end, walk.progress),
            pose: walk.moving ? .walking : .idle,
            facing: facing,
            speed: walk.moving ? nil : 0
        )
    }

    /// Distance covered along a path that rests `pauses` times on the way.
    static func progress(along cycle: Double, pauses: Int) -> (progress: Double, moving: Bool) {
        guard pauses > 0 else { return (min(1, max(0, cycle)), true) }
        let legs = pauses + 1
        let rest = min(0.14, 0.55 / Double(pauses))
        let leg = (1 - rest * Double(pauses)) / Double(legs)
        var remaining = min(1, max(0, cycle))
        var covered = 0.0
        let step = 1 / Double(legs)
        for index in 0..<legs {
            if remaining < leg {
                return (covered + remaining / leg * step, true)
            }
            remaining -= leg
            covered += step
            if index < pauses {
                if remaining < rest { return (covered, false) }
                remaining -= rest
            }
        }
        return (1, false)
    }

    // MARK: Errand

    private static func errand(
        home: CompanionScenePoint,
        site: CompanionScenePoint,
        period: Double,
        workShare: Double,
        elapsed: Double,
        phase: Double
    ) -> CompanionActorPlacement {
        let work = min(max(workShare, 0), 0.8)
        let leg = (1 - work) / 2
        let cycle = CompanionMath.fraction(elapsed / max(0.001, period) + phase)
        let outbound: Double = site.x >= home.x ? 1 : -1

        if cycle < leg {
            return CompanionActorPlacement(
                point: .lerp(home, site, cycle / leg),
                pose: .walking,
                facing: outbound
            )
        }
        if cycle < leg + work {
            // The stroke runs on its own clock: an axe keeps its rhythm no
            // matter how long the walk to the trees was.
            return CompanionActorPlacement(
                point: site,
                pose: .working(
                    swing: CompanionMath.fraction(elapsed / 0.85 + phase)
                ),
                facing: outbound,
                speed: 0
            )
        }
        return CompanionActorPlacement(
            point: .lerp(site, home, (cycle - leg - work) / leg),
            pose: .carrying,
            facing: -outbound
        )
    }

    // MARK: Ticked

    /// A slow wander read only on tick boundaries and snapped to the tile
    /// grid. The amplitudes below keep every tick's step to at most one tile,
    /// which is what makes it read as a game world rather than a slideshow.
    private static func ticked(
        pen: CompanionScenePoint,
        spanX: Double,
        spanY: Double,
        tile: Double,
        elapsed: Double,
        phase: Double
    ) -> CompanionActorPlacement {
        let tick = floor(max(0, elapsed) / CompanionSceneMotion.gameTick)
        let periodX = 11.3 * (1 + phase * 0.6)
        let periodY = 17.9 * (1 + CompanionMath.fraction(phase * 1.7) * 0.6)
        let tileY = tile * 0.5

        func standing(at index: Double) -> CompanionScenePoint {
            let time = index * CompanionSceneMotion.gameTick
            let x = pen.x + spanX * sin(2 * .pi * time / periodX + 2 * .pi * phase)
            let y = pen.y + spanY * sin(2 * .pi * time / periodY + 4.4 * phase)
            return CompanionScenePoint(
                (x / tile).rounded() * tile,
                (y / tileY).rounded() * tileY
            )
        }

        let here = standing(at: tick)
        let before = standing(at: tick - 1)
        let earlier = standing(at: tick - 2)
        let stepped = here != before
        let facing: Double
        if here.x != before.x {
            facing = here.x > before.x ? 1 : -1
        } else if before.x != earlier.x {
            facing = before.x > earlier.x ? 1 : -1
        } else {
            facing = 1
        }

        return CompanionActorPlacement(
            point: here,
            pose: stepped ? .walking : .idle,
            facing: facing,
            speed: stepped ? 1 : 0,
            // Legs alternate once per tick and never interpolate.
            stride: CompanionMath.fraction(tick / 2)
        )
    }

    // MARK: Wander

    private static func wander(
        pen: CompanionScenePoint,
        spanX: Double,
        spanY: Double,
        period: Double,
        linger: Double,
        elapsed: Double,
        phase: Double
    ) -> CompanionActorPlacement {
        // Pushing the sine outward makes an animal spend most of its time at
        // the ends of its beat and cross between them quickly.
        let exponent = 1 - 0.8 * min(max(linger, 0), 1)
        func shaped(_ value: Double) -> Double {
            let magnitude = pow(abs(value), exponent)
            return value < 0 ? -magnitude : magnitude
        }
        let cycle = max(0.001, period)
        let x = pen.x + spanX * shaped(
            sin(2 * .pi * elapsed / cycle + 2 * .pi * phase)
        )
        let y = pen.y + spanY * shaped(
            sin(2 * .pi * elapsed / (cycle * 0.63) + 5.1 * phase)
        )
        return CompanionActorPlacement(
            point: CompanionScenePoint(x, y),
            pose: .walking
        )
    }

    // MARK: Perch

    private static func perch(
        at target: CompanionScenePoint,
        approachFrom entry: CompanionScenePoint,
        period: Double,
        perchShare: Double,
        elapsed: Double,
        phase: Double
    ) -> CompanionActorPlacement {
        let settled = min(max(perchShare, 0), 0.9)
        let leg = (1 - settled) / 2
        let cycle = CompanionMath.fraction(elapsed / max(0.001, period) + phase)
        // Leaving continues the way it arrived rather than doubling back, and
        // always clears the frame — a cycle that wrapped in view would read as
        // a bird teleporting back to where it came from.
        let heading: Double = target.x >= entry.x ? 1 : -1
        let reach = max(0.35, abs(target.x - entry.x))
        let departure = target.x + heading * reach
        // Just past the edge, never off into the far distance: the loop has to
        // be invisible, not remote.
        let exit = CompanionScenePoint(
            heading > 0
                ? min(1.35, max(1.25, departure))
                : max(-0.35, min(-0.25, departure)),
            entry.y
        )

        if cycle < leg {
            let t = cycle / leg
            return CompanionActorPlacement(
                // Smoothstep: a bird decelerates onto a branch.
                point: .lerp(entry, target, t * t * (3 - 2 * t)),
                pose: .flying,
                facing: target.x >= entry.x ? 1 : -1
            )
        }
        if cycle < leg + settled {
            return CompanionActorPlacement(
                point: target,
                pose: .perched,
                facing: target.x >= entry.x ? 1 : -1,
                speed: 0
            )
        }
        let t = (cycle - leg - settled) / leg
        return CompanionActorPlacement(
            point: .lerp(target, exit, t * t),
            pose: .flying,
            facing: exit.x >= target.x ? 1 : -1
        )
    }
}


extension CompanionSceneTint {
    /// The same colour under slightly different light. Used to tell one
    /// member of a population apart from the next without inventing a palette.
    func shaded(by factor: Double) -> CompanionSceneTint {
        guard factor != 1 else { return self }
        func channel(_ value: Double) -> Double { min(1, max(0, value * factor)) }
        return CompanionSceneTint(channel(red), channel(green), channel(blue))
    }
}
