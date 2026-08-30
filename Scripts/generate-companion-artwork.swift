#!/usr/bin/env swift
// Development-time generator for the original Forest and Village companion
// artwork — chunky pixel art drawn on a fixed cell grid.
//
// Usage: swift Scripts/generate-companion-artwork.swift [output-root]
//
// The output root defaults to Resources/Companions relative to the repository
// root. Every image is deterministic for a given script revision, so the
// bundled artwork can be regenerated and reviewed from source control alone.
//
// Geometry contract with `CompanionAssetCatalog`:
// - Scenes are a 155 x 42 cell grid, exported at 8 image pixels per cell
//   (1240 x 336), matching the 310 x 84 point scene composition.
// - Sprites are exported at the same 8 pixels per cell with no trimming, so
//   the PNG pixel height equals `cells * 8` and the catalog can size layers
//   in whole cells. The catalog's cell-height tables are verified against
//   these files by `CompanionArtworkAssetTests`.

import AppKit

// MARK: - Shared drawing infrastructure

let cellScale = 8
let sceneGridWidth = 155
let sceneGridHeight = 42
let stageCount = 12

// Each stage ships three scenery variants — the same place on a different
// day: clouds, birds, stars, flowers, and light vary; the terrain does not.
// The app rotates them from its daily seed.
let sceneryVariantSuffixes = ["a", "b", "c"]

struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func range(_ low: Double, _ high: Double) -> Double {
        low + unit() * (high - low)
    }

    mutating func int(_ low: Int, _ high: Int) -> Int {
        low + Int(next() % UInt64(high - low + 1))
    }
}

func stableHash(_ string: String) -> UInt64 {
    string.utf8.reduce(14_695_981_039_346_656_037) { value, byte in
        (value ^ UInt64(byte)) &* 1_099_511_628_211
    }
}

/// This script's SplitMix64 and stableHash must produce the exact streams the
/// app produces (SplitMix64 / CompanionHash.fnv1a), or baked artwork and
/// runtime layout silently disagree. The literals below are the same vectors
/// CompanionRandomTests pins on the app side; change one copy and both
/// harnesses fail until the other follows.
func verifyDeterminismContract() {
    var zero = SplitMix64(state: 0)
    precondition(zero.next() == 16_294_208_416_658_607_535, "SplitMix64 drifted from the app implementation")
    precondition(zero.next() == 7_960_286_522_194_355_700, "SplitMix64 drifted from the app implementation")
    precondition(zero.next() == 487_617_019_471_545_679, "SplitMix64 drifted from the app implementation")
    precondition(zero.next() == 17_909_611_376_780_542_444, "SplitMix64 drifted from the app implementation")
    var seeded = SplitMix64(state: 0x5EED_C0FF_EE12_3456)
    precondition(seeded.next() == 18_353_202_869_249_109_356, "SplitMix64 drifted from the app implementation")
    precondition(seeded.next() == 5_283_367_462_885_150_505, "SplitMix64 drifted from the app implementation")
    var one = SplitMix64(state: 1)
    precondition(one.unit() == 0.5665615751722809, "SplitMix64.unit drifted from the app implementation")
    precondition(one.range(-3, 7) == 4.457817572627011, "SplitMix64.range drifted from the app implementation")
    precondition(stableHash("") == 14_695_981_039_346_656_037, "stableHash drifted from CompanionHash.fnv1a")
    precondition(stableHash("forest/slots") == 16_912_484_999_438_345_198, "stableHash drifted from CompanionHash.fnv1a")
    precondition(stableHash("village/slots") == 9_601_084_288_157_441_201, "stableHash drifted from CompanionHash.fnv1a")
    precondition(stableHash("oak-3") == 15_916_341_269_509_778_426, "stableHash drifted from CompanionHash.fnv1a")
    precondition(stableHash("pokemon") == 9_996_402_097_866_326_110, "stableHash drifted from CompanionHash.fnv1a")
}

/// Packs an 0xRRGGBB color and alpha into the canvas's 0xRRGGBBAA format.
func pack(_ rgb: UInt32, _ alpha: Double = 1) -> UInt32 {
    (rgb << 8) | UInt32(max(0, min(255, Int(alpha * 255))))
}

func mixRGB(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
    let t = max(0, min(1, t))
    func channel(_ shift: UInt32) -> UInt32 {
        let x = Double((a >> shift) & 0xFF)
        let y = Double((b >> shift) & 0xFF)
        return UInt32((x + (y - x) * t).rounded()) << shift
    }
    return channel(16) | channel(8) | channel(0)
}

/// A y-up pixel buffer holding straight (non-premultiplied) RGBA cells.
final class PixelCanvas {
    let width: Int
    let height: Int
    private(set) var pixels: [UInt32]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = Array(repeating: 0, count: width * height)
    }

    func set(_ x: Int, _ y: Int, _ color: UInt32) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let index = y * width + x
        let sourceAlpha = Double(color & 0xFF) / 255
        if sourceAlpha >= 0.999 {
            pixels[index] = color
            return
        }
        guard sourceAlpha > 0 else { return }
        let destination = pixels[index]
        let destinationAlpha = Double(destination & 0xFF) / 255
        let outAlpha = sourceAlpha + destinationAlpha * (1 - sourceAlpha)
        guard outAlpha > 0 else { return }
        func blend(_ shift: UInt32) -> UInt32 {
            let s = Double((color >> shift) & 0xFF)
            let d = Double((destination >> shift) & 0xFF)
            let value = (s * sourceAlpha + d * destinationAlpha * (1 - sourceAlpha)) / outAlpha
            return UInt32(max(0, min(255, value.rounded()))) << shift
        }
        pixels[index] = blend(24) | blend(16) | blend(8)
            | UInt32(max(0, min(255, (outAlpha * 255).rounded())))
    }

    func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: UInt32) {
        for py in y..<(y + h) {
            for px in x..<(x + w) {
                set(px, py, color)
            }
        }
    }

    func disc(cx: Int, cy: Int, rx: Double, ry: Double, _ color: UInt32) {
        guard rx > 0, ry > 0 else { return }
        let spanX = Int(rx.rounded(.up))
        let spanY = Int(ry.rounded(.up))
        for dy in -spanY...spanY {
            for dx in -spanX...spanX {
                let nx = Double(dx) / rx
                let ny = Double(dy) / ry
                if nx * nx + ny * ny <= 1.05 {
                    set(cx + dx, cy + dy, color)
                }
            }
        }
    }

    /// Nearest-neighbor export at `cellScale`, flipped into bitmap row order.
    func writePNG(to url: URL) throws {
        let outWidth = width * cellScale
        let outHeight = height * cellScale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: outWidth,
            pixelsHigh: outHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: outWidth * 4,
            bitsPerPixel: 32
        ), let data = rep.bitmapData else {
            throw NSError(domain: "generate-companion-artwork", code: 1)
        }
        for y in 0..<height {
            for x in 0..<width {
                let cellColor = pixels[y * width + x]
                let alpha = cellColor & 0xFF
                // The bitmap is premultiplied; scenes are opaque and sprites
                // only carry translucency in their baked shadows.
                let scale = Double(alpha) / 255
                let red = UInt8((Double((cellColor >> 24) & 0xFF) * scale).rounded())
                let green = UInt8((Double((cellColor >> 16) & 0xFF) * scale).rounded())
                let blue = UInt8((Double((cellColor >> 8) & 0xFF) * scale).rounded())
                for subY in 0..<cellScale {
                    let row = (height - 1 - y) * cellScale + subY
                    for subX in 0..<cellScale {
                        let offset = (row * outWidth + x * cellScale + subX) * 4
                        data[offset] = red
                        data[offset + 1] = green
                        data[offset + 2] = blue
                        data[offset + 3] = UInt8(alpha)
                    }
                }
            }
        }
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "generate-companion-artwork", code: 2)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: url, options: .atomic)
    }
}

/// Fills the whole canvas with a banded, dithered vertical sky gradient.
func drawSky(
    _ canvas: PixelCanvas,
    horizon: UInt32,
    zenith: UInt32,
    horizonRow: Int
) {
    let top = canvas.height - 1
    for y in 0...top {
        let t = Double(max(0, y - horizonRow)) / Double(max(1, top - horizonRow))
        let scaled = t * 7
        let lowColor = pack(mixRGB(horizon, zenith, floor(scaled) / 7))
        let highColor = pack(mixRGB(horizon, zenith, min(1, (floor(scaled) + 1) / 7)))
        let frac = scaled - floor(scaled)
        for x in 0..<canvas.width {
            let useHigh: Bool = if frac < 0.25 {
                false
            } else if frac < 0.75 {
                (x + y) % 2 == 0
            } else {
                true
            }
            canvas.set(x, y, useHigh ? highColor : lowColor)
        }
    }
}

func drawPuffCloud(_ canvas: PixelCanvas, x: Int, y: Int, w: Int, color: UInt32) {
    canvas.rect(x, y, w, 1, color)
    canvas.rect(x + 1, y + 1, max(2, w - 3), 1, color)
    if w >= 7 {
        canvas.rect(x + 3, y + 2, w - 6, 1, color)
    }
}

func drawBird(_ canvas: PixelCanvas, x: Int, y: Int, color: UInt32) {
    canvas.set(x, y + 1, color)
    canvas.set(x + 1, y, color)
    canvas.set(x + 2, y + 1, color)
}

func writeCanvas(_ canvas: PixelCanvas, into root: URL, path: String) throws {
    try canvas.writePNG(to: root.appending(path: path))
}

// MARK: - Forest artwork

enum ForestArtwork {
    // The forest keeps daylight (its sprites are shared by every stage) but
    // the season deepens across the journey: pale spring, lush summer, then
    // a golden late-summer glow for the ancient forest. Each palette is a
    // smooth arc between its spring and late-summer endpoints.
    static func seasonProgress(_ stage: Int) -> Double {
        Double(stage) / Double(stageCount - 1)
    }

    static func skyZenith(_ stage: Int) -> UInt32 {
        mixRGB(0xA7CBE8, 0x93A3B8, seasonProgress(stage))
    }
    static func skyHorizon(_ stage: Int) -> UInt32 {
        mixRGB(0xEDEBDD, 0xF2CC8E, seasonProgress(stage))
    }
    static func groundFront(_ stage: Int) -> UInt32 {
        mixRGB(0x8CBB66, 0x588745, seasonProgress(stage))
    }
    static func groundBack(_ stage: Int) -> UInt32 {
        mixRGB(0x79A85C, 0x4B7441, seasonProgress(stage))
    }
    static func treelineNear(_ stage: Int) -> UInt32 {
        mixRGB(0x6F9B6E, 0x466B46, seasonProgress(stage))
    }
    static func treelineFar(_ stage: Int) -> UInt32 {
        mixRGB(0x92B295, 0x688967, seasonProgress(stage))
    }

    static func generate(into root: URL) throws {
        for stage in 0..<stageCount {
            for (variant, suffix) in sceneryVariantSuffixes.enumerated() {
                try writeCanvas(
                    drawScene(stage: stage, variant: variant),
                    into: root,
                    path: String(format: "Forest/scenes/%02d-%@.png", stage + 1, suffix)
                )
            }
            try writeCanvas(
                drawSilhouette(stage: stage),
                into: root,
                path: String(format: "Forest/silhouettes/%02d.png", stage + 1)
            )
        }
        for (species, heights) in TreeSprites.cellHeights {
            for (level, _) in heights.enumerated() {
                try writeCanvas(
                    TreeSprites.draw(species: species, level: level),
                    into: root,
                    path: "Forest/sprites/\(species)-\(level).png"
                )
            }
        }
        print("Forest artwork generated")
    }

    static func drawScene(stage: Int, variant: Int) -> PixelCanvas {
        let canvas = PixelCanvas(width: sceneGridWidth, height: sceneGridHeight)
        let variantSalt = UInt64(variant) &* 0x9E37
        let horizonRow = 8

        drawSky(
            canvas,
            horizon: skyHorizon(stage),
            zenith: skyZenith(stage),
            horizonRow: horizonRow
        )

        // Low sun, drifting a little per variant, warming across the arc.
        let sunX = Int(Double(canvas.width) * (0.80 + [0.0, -0.09, 0.05][variant]))
        let sunY = 31 + [0, 2, -1][variant]
        let sunColor = mixRGB(0xFFF4CE, 0xFFE9AC, seasonProgress(stage))
        canvas.disc(cx: sunX, cy: sunY, rx: 3.4, ry: 3.4, pack(sunColor))
        canvas.disc(cx: sunX, cy: sunY, rx: 5.2, ry: 5.2, pack(sunColor, 0.25))

        var cloudRNG = SplitMix64(state: 0xA11CE &+ UInt64(stage) &+ variantSalt)
        for _ in 0..<[3, 2, 4][variant] {
            let x = cloudRNG.int(6, canvas.width - 22)
            let y = cloudRNG.int(26, 38)
            let w = cloudRNG.int(9, 16)
            drawPuffCloud(canvas, x: x, y: y, w: w, color: pack(0xFFFFFF, 0.62))
        }

        // Birds arrive once the forest can host them.
        if stage >= 6 {
            var birdRNG = SplitMix64(state: 0xB1AD &+ UInt64(stage) &+ variantSalt)
            for _ in 0..<(1 + stage / 3) {
                drawBird(
                    canvas,
                    x: birdRNG.int(8, canvas.width - 40),
                    y: birdRNG.int(28, 37),
                    color: pack(0x44525A, 0.85)
                )
            }
        }

        // Backdrop treelines thicken as the forest matures: a hazy far rank
        // and a nearer, darker rank sitting on the horizon.
        var treelineRNG = SplitMix64(state: 0xD157 &+ UInt64(stage))
        for _ in 0..<(8 + stage * 2) {
            let x = treelineRNG.int(0, canvas.width - 1)
            let r = treelineRNG.range(1.6, 3.4)
            canvas.disc(
                cx: x,
                cy: horizonRow + 3,
                rx: r,
                ry: r * 1.1,
                pack(treelineFar(stage), 0.9)
            )
        }
        for _ in 0..<(6 + stage * 2) {
            let x = treelineRNG.int(0, canvas.width - 1)
            let r = treelineRNG.range(1.8, 3.8)
            canvas.disc(
                cx: x,
                cy: horizonRow + 1,
                rx: r,
                ry: r * 1.2,
                pack(treelineNear(stage))
            )
        }

        // Ground bands: near meadow, far meadow, and a haze seam under the
        // treeline so the horizon sits back.
        canvas.rect(0, 0, canvas.width, horizonRow, pack(groundBack(stage)))
        canvas.rect(0, 0, canvas.width, 5, pack(groundFront(stage)))
        canvas.rect(0, horizonRow - 1, canvas.width, 1, pack(0xFFFFFF, 0.18))

        // Meadow texture: grass flecks, plus flowers whose petals fade as
        // the season turns.
        var detailRNG = SplitMix64(state: 0xF10CA &+ variantSalt &+ UInt64(stage))
        let darkGrass = mixRGB(groundFront(stage), 0x2F5430, 0.45)
        let lightGrass = mixRGB(groundFront(stage), 0xD9E8A8, 0.4)
        for _ in 0..<60 {
            let x = detailRNG.int(0, canvas.width - 1)
            let y = detailRNG.int(0, horizonRow - 2)
            canvas.set(x, y, pack(detailRNG.unit() < 0.5 ? darkGrass : lightGrass, 0.8))
        }
        let petals: [UInt32] = stage < 6
            ? [0xF2EBC9, 0xE9C7CF, 0xF3F3F3]
            : [0xE8D6A0, 0xD9B98A, 0xF2EBC9]
        for _ in 0..<[10, 8, 12][variant] {
            let x = detailRNG.int(1, canvas.width - 2)
            let y = detailRNG.int(1, 5)
            canvas.set(x, y, pack(petals[detailRNG.int(0, petals.count - 1)]))
        }
        return canvas
    }

    /// The 18 x 18 menu-bar silhouette: the same forest, reduced to black
    /// alpha shapes, gaining trees as the journey advances. Shapes stay
    /// narrow and separated so the count reads even at menu-bar size.
    static func drawSilhouette(stage: Int) -> PixelCanvas {
        let canvas = PixelCanvas(width: 18, height: 18)
        let black = pack(0x000000)
        canvas.rect(1, 0, 16, 1, black)

        func oak(_ cx: Int, _ h: Int, _ half: Int) {
            canvas.rect(cx, 1, 1, max(1, h / 3), black)
            let r = Double(half)
            canvas.disc(cx: cx, cy: 1 + h / 3 + Int(r * 0.8), rx: r, ry: r, black)
        }
        func pine(_ cx: Int, _ h: Int, _ half: Int) {
            canvas.rect(cx, 1, 1, 1, black)
            for row in 0..<h {
                let width = max(0, (h - row) * half / h)
                canvas.rect(cx - width, 2 + row, width * 2 + 1, 1, black)
            }
        }

        switch stage {
        case 0: oak(9, 5, 2)
        case 1: oak(6, 5, 2); pine(12, 6, 2)
        case 2: oak(5, 5, 2); pine(12, 7, 2)
        case 3: pine(3, 6, 2); oak(9, 7, 3); pine(15, 5, 2)
        case 4: oak(2, 5, 2); pine(7, 8, 2); oak(13, 6, 3)
        case 5: oak(2, 5, 2); pine(7, 9, 2); oak(13, 7, 3)
        case 6: pine(2, 7, 2); oak(7, 9, 3); pine(13, 11, 3)
        case 7: oak(2, 7, 2); pine(7, 11, 3); oak(13, 9, 3)
        case 8: oak(2, 7, 2); pine(7, 12, 3); oak(13, 10, 3)
        case 9: pine(2, 9, 2); oak(7, 12, 3); pine(13, 14, 3)
        case 10: pine(2, 10, 2); oak(7, 13, 3); pine(13, 14, 3)
        default: oak(2, 9, 2); pine(8, 15, 4); oak(14, 11, 3)
        }
        return canvas
    }
}

/// Individual tree sprites: three species, four maturity levels each, drawn
/// at exact cell sizes so the catalog can place them without trimming.
enum TreeSprites {
    // Heights must match `CompanionAssetCatalog.forestSpriteCellHeights`.
    static let cellHeights: [String: [Int]] = [
        "oak": [6, 12, 20, 28],
        "pine": [7, 14, 22, 30],
        "birch": [6, 11, 17, 23]
    ]
    static let cellWidths: [String: [Int]] = [
        "oak": [5, 9, 15, 23],
        "pine": [5, 9, 13, 17],
        "birch": [4, 7, 9, 12]
    ]

    static let oakLeafDark: UInt32 = 0x3E6B33
    static let oakLeafMid: UInt32 = 0x568F43
    static let oakLeafLight: UInt32 = 0x77AC59
    static let pineDark: UInt32 = 0x2F5E3A
    static let pineMid: UInt32 = 0x417C4A
    static let pineLight: UInt32 = 0x5E9C5D
    static let birchLeafMid: UInt32 = 0x8FBB6A
    static let birchLeafLight: UInt32 = 0xA9CC7F
    static let trunkDark: UInt32 = 0x543D28
    static let trunkMid: UInt32 = 0x6B4E33
    static let birchBark: UInt32 = 0xE3E3D5
    static let birchTick: UInt32 = 0x3A3A34

    static func draw(species: String, level: Int) -> PixelCanvas {
        let canvas = PixelCanvas(
            width: cellWidths[species]![level],
            height: cellHeights[species]![level]
        )
        drawShadow(canvas)
        switch species {
        case "oak": drawOak(canvas, level: level)
        case "pine": drawPine(canvas, level: level)
        default: drawBirch(canvas, level: level)
        }
        return canvas
    }

    /// A one-cell dithered contact shadow baked into the sprite's feet.
    private static func drawShadow(_ canvas: PixelCanvas) {
        let width = max(2, canvas.width * 3 / 4)
        let start = (canvas.width - width) / 2
        for x in start..<(start + width) {
            canvas.set(x, 0, pack(0x14280F, x % 2 == 0 ? 0.4 : 0.25))
        }
    }

    private static func drawOak(_ canvas: PixelCanvas, level: Int) {
        let cx = canvas.width / 2
        let rng = SplitMix64(state: stableHash("oak-\(level)"))
        var blobRNG = rng
        switch level {
        case 0:
            canvas.rect(cx, 0, 1, 3, pack(trunkMid))
            canvas.disc(cx: cx, cy: 4, rx: 1.7, ry: 1.5, pack(oakLeafMid))
            canvas.set(cx - 1, 4, pack(oakLeafLight))
        case 1:
            canvas.rect(cx, 0, 1, 4, pack(trunkMid))
            canvas.set(cx + 1, 1, pack(trunkDark))
            canvas.disc(cx: cx, cy: 8, rx: 3.6, ry: 3.4, pack(oakLeafDark))
            canvas.disc(cx: cx - 1, cy: 8, rx: 2.6, ry: 2.4, pack(oakLeafMid))
            canvas.set(cx - 2, 9, pack(oakLeafLight))
            canvas.set(cx - 1, 10, pack(oakLeafLight))
        default:
            let trunkWidth = level == 2 ? 2 : 3
            let trunkHeight = level == 2 ? 7 : 10
            canvas.rect(cx - trunkWidth / 2, 0, trunkWidth, trunkHeight, pack(trunkMid))
            canvas.rect(cx + trunkWidth / 2, 0, 1, trunkHeight - 2, pack(trunkDark))
            // Root flare.
            canvas.set(cx - trunkWidth / 2 - 1, 0, pack(trunkMid))
            canvas.set(cx + trunkWidth / 2 + 1, 0, pack(trunkDark))
            let lobes = level == 2 ? 2 : 3
            let crownY = trunkHeight + (canvas.height - trunkHeight) / 2 - 1
            let radius = Double(canvas.height - trunkHeight) * 0.52
            for lobe in 0..<lobes {
                let offset = lobes == 1 ? 0.0 : (Double(lobe) / Double(lobes - 1) - 0.5)
                let lx = cx + Int((offset * Double(canvas.width) * 0.52).rounded())
                let ly = crownY - Int(abs(offset) * radius * 0.5)
                    + blobRNG.int(-1, 1)
                canvas.disc(cx: lx, cy: ly, rx: radius * 0.72, ry: radius * 0.62, pack(oakLeafDark))
            }
            for lobe in 0..<lobes {
                let offset = lobes == 1 ? 0.0 : (Double(lobe) / Double(lobes - 1) - 0.5)
                let lx = cx + Int((offset * Double(canvas.width) * 0.52).rounded()) - 1
                let ly = crownY - Int(abs(offset) * radius * 0.5) + 1
                canvas.disc(cx: lx, cy: ly, rx: radius * 0.5, ry: radius * 0.42, pack(oakLeafMid))
            }
            canvas.disc(
                cx: cx - canvas.width / 5,
                cy: crownY + Int(radius * 0.35),
                rx: radius * 0.32,
                ry: radius * 0.26,
                pack(oakLeafLight)
            )
        }
    }

    private static func drawPine(_ canvas: PixelCanvas, level: Int) {
        let cx = canvas.width / 2
        let trunkHeight = [1, 2, 3, 3][level]
        canvas.rect(cx, 0, 1, trunkHeight + 1, pack(trunkDark))
        let crownHeight = canvas.height - trunkHeight - 1
        let maxHalf = canvas.width / 2
        for row in 0..<crownHeight {
            let t = Double(row) / Double(max(1, crownHeight - 1))
            // Tiered taper: saw-tooth ledges over a linear shrink.
            let taper = (1 - t) * Double(maxHalf)
            let ledge = Double((crownHeight - row) % 3 == 0 ? 1 : 0) * (level >= 2 ? 1.0 : 0.0)
            let half = max(0, Int((taper + ledge).rounded()) - (row == crownHeight - 1 ? maxHalf - 1 : 0))
            let y = trunkHeight + 1 + row
            canvas.rect(cx - half, y, half * 2 + 1, 1, pack(row % 2 == 0 ? pineDark : pineMid))
            if half > 0 {
                canvas.set(cx - half, y, pack(pineLight))
            }
        }
    }

    private static func drawBirch(_ canvas: PixelCanvas, level: Int) {
        let cx = canvas.width / 2
        let trunkHeight = [3, 5, 8, 11][level]
        let trunkWidth = level >= 2 ? 2 : 1
        canvas.rect(cx - trunkWidth / 2, 0, trunkWidth, trunkHeight + 2, pack(birchBark))
        // Bark ticks alternate sides so the trunk reads as birch, not dashes.
        for (index, y) in stride(from: 1, through: trunkHeight, by: 2).enumerated() {
            canvas.set(cx - trunkWidth / 2 + (index % 2 == 0 ? 0 : trunkWidth - 1), y, pack(birchTick))
        }
        // An airy crown; grown trees get a lopsided second mass while young
        // ones keep a centered tuft so nothing clips off the narrow canvas.
        let crownY = trunkHeight + (canvas.height - trunkHeight) / 2
        let radius = Double(canvas.height - trunkHeight) * 0.5
        if level < 2 {
            canvas.disc(cx: cx, cy: crownY, rx: radius * 0.8, ry: radius * 0.75, pack(birchLeafMid))
            canvas.disc(
                cx: cx,
                cy: crownY + Int(radius * 0.3),
                rx: radius * 0.5,
                ry: radius * 0.45,
                pack(birchLeafLight)
            )
        } else {
            canvas.disc(
                cx: cx + 1,
                cy: crownY - Int(radius * 0.3),
                rx: radius * 0.7,
                ry: radius * 0.6,
                pack(birchLeafMid)
            )
            canvas.disc(
                cx: cx - canvas.width / 4,
                cy: crownY + Int(radius * 0.1),
                rx: radius * 0.6,
                ry: radius * 0.55,
                pack(birchLeafMid)
            )
            canvas.disc(
                cx: cx - 1,
                cy: crownY + Int(radius * 0.35),
                rx: radius * 0.5,
                ry: radius * 0.45,
                pack(birchLeafLight)
            )
        }
    }
}

// MARK: - Village artwork

enum VillageArtwork {
    // One day across the whole journey: dawn over the first cottage, night
    // over the finished skyline.
    static let skyZenith: [UInt32] = [
        0x6E7BB8, 0x7A9BD0, 0x7FA8D8, 0x76A6DC, 0x6FA3DC, 0x6EA0D6,
        0x6E9FD4, 0x8492C4, 0x5D5E9E, 0x3A3E74, 0x2A2F5C, 0x1A2145
    ]
    static let skyHorizon: [UInt32] = [
        0xF7C9A0, 0xF0D4AC, 0xEAE2C8, 0xDCE3E0, 0xCFE4EE, 0xDCE0D2,
        0xE8DDB8, 0xF4C078, 0xEE9A6A, 0xB06A88, 0x6B5578, 0x3E4878
    ]

    /// How far the day has fallen toward night at each stage; drives hill,
    /// ground, and window light.
    static let duskiness: [Double] = [
        0.12, 0.05, 0.0, 0.0, 0.02, 0.08, 0.18, 0.32, 0.55, 0.75, 0.9, 1.0
    ]

    static func hillFar(_ stage: Int) -> UInt32 {
        mixRGB(0xAFC0B8, 0x2C3158, duskiness[stage])
    }
    static func hillNear(_ stage: Int) -> UInt32 {
        mixRGB(0x92AC8C, 0x232849, duskiness[stage])
    }

    /// How urban the ground reads at each stage: 0 meadow, 1 dirt road,
    /// 2 cobbles, 3 asphalt.
    static let groundKind = [0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3]

    static func generate(into root: URL) throws {
        for stage in 0..<stageCount {
            for (variant, suffix) in sceneryVariantSuffixes.enumerated() {
                try writeCanvas(
                    drawScene(stage: stage, variant: variant),
                    into: root,
                    path: String(format: "Village/scenes/%02d-%@.png", stage + 1, suffix)
                )
            }
            try writeCanvas(
                drawSilhouette(stage: stage),
                into: root,
                path: String(format: "Village/silhouettes/%02d.png", stage + 1)
            )
        }
        for (style, heights) in BuildingSprites.cellHeights {
            for (level, _) in heights.enumerated() {
                for lit in [false, true] {
                    try writeCanvas(
                        BuildingSprites.draw(style: style, level: level, lit: lit),
                        into: root,
                        path: "Village/sprites/\(style)-\(level)-\(lit ? "lit" : "day").png"
                    )
                }
            }
        }
        print("Village artwork generated")
    }

    static func drawScene(stage: Int, variant: Int) -> PixelCanvas {
        let canvas = PixelCanvas(width: sceneGridWidth, height: sceneGridHeight)
        let variantSalt = UInt64(variant) &* 0x9E37
        let horizonRow = 8
        let night = stage >= 9

        drawSky(
            canvas,
            horizon: skyHorizon[stage],
            zenith: skyZenith[stage],
            horizonRow: horizonRow
        )

        if night {
            var starRNG = SplitMix64(state: 0x57A2 &+ UInt64(stage) &+ variantSalt)
            for _ in 0..<(stage >= 11 ? 34 : (stage == 10 ? 24 : 12)) {
                let x = starRNG.int(0, canvas.width - 1)
                let y = starRNG.int(16, canvas.height - 1)
                let bright = starRNG.unit()
                canvas.set(x, y, pack(bright < 0.15 ? 0xFFE8C0 : 0xF4F4FF, bright < 0.4 ? 1 : 0.55))
            }
            // Crescent moon: outer disc minus an offset bite, drawn cell by
            // cell so the sky behind stays untouched.
            let moonX = Int(Double(canvas.width) * (0.18 + [0.0, 0.08, -0.05][variant]))
            let moonY = 33 + [0, -2, 1][variant]
            for dy in -3...3 {
                for dx in -3...3 {
                    let outer = Double(dx * dx + dy * dy)
                    let biteX = Double(dx - 2)
                    let biteY = Double(dy - 1)
                    let bite = biteX * biteX + biteY * biteY
                    if outer <= 8.5, bite > 5.5 {
                        canvas.set(moonX + dx, moonY + dy, pack(0xEDEBD8))
                    }
                }
            }
        } else {
            // Sun sliding from dawn-low toward sunset-low across the stages.
            let arc = Double(stage) / 8
            let sunX = Int(Double(canvas.width) * (0.2 + arc * 0.6 + [0.0, -0.05, 0.05][variant]))
            let sunY = Int(30 + sin(arc * .pi) * 7) + [0, 1, -1][variant]
            let sunColor = mixRGB(0xFFEFC4, 0xFFC470, abs(arc - 0.5) * 2)
            canvas.disc(cx: sunX, cy: sunY, rx: 3.2, ry: 3.2, pack(sunColor))
            canvas.disc(cx: sunX, cy: sunY, rx: 5.0, ry: 5.0, pack(sunColor, 0.25))

            var cloudRNG = SplitMix64(state: 0xC10D &+ UInt64(stage) &+ variantSalt)
            let cloudColor = duskiness[stage] > 0.25 ? pack(0xF2D0A8, 0.55) : pack(0xFFFFFF, 0.6)
            for _ in 0..<[3, 2, 4][variant] {
                drawPuffCloud(
                    canvas,
                    x: cloudRNG.int(4, canvas.width - 22),
                    y: cloudRNG.int(25, 37),
                    w: cloudRNG.int(9, 16),
                    color: cloudColor
                )
            }
        }

        // Rolling hills behind the town, urbanizing into a distant skyline
        // as the journey advances.
        var hillRNG = SplitMix64(state: 0x8111 &+ UInt64(stage))
        for _ in 0..<7 {
            let x = hillRNG.int(0, canvas.width - 1)
            let r = hillRNG.range(9, 20)
            canvas.disc(cx: x, cy: horizonRow, rx: r, ry: r * 0.3, pack(hillFar(stage)))
        }
        for _ in 0..<6 {
            let x = hillRNG.int(0, canvas.width - 1)
            let r = hillRNG.range(8, 16)
            canvas.disc(cx: x, cy: horizonRow - 1, rx: r, ry: r * 0.28, pack(hillNear(stage)))
        }
        if stage >= 5 {
            var skylineRNG = SplitMix64(state: 0x51CF &+ UInt64(stage))
            let towerColor = mixRGB(hillNear(stage), 0x2A2A44, 0.5)
            for _ in 0..<((stage - 4) * 3) {
                let x = skylineRNG.int(4, canvas.width - 5)
                let towerWidth = skylineRNG.int(2, 4)
                let towerHeight = skylineRNG.int(3, 4 + stage)
                canvas.rect(x, horizonRow, towerWidth, towerHeight, pack(towerColor))
                if duskiness[stage] > 0.5 {
                    for _ in 0..<(towerHeight / 2) {
                        canvas.set(
                            x + skylineRNG.int(0, towerWidth - 1),
                            horizonRow + skylineRNG.int(0, towerHeight - 1),
                            pack(0xFFD98A, 0.9)
                        )
                    }
                }
            }
        }

        drawGround(canvas, stage: stage, horizonRow: horizonRow)
        return canvas
    }

    private static func drawGround(_ canvas: PixelCanvas, stage: Int, horizonRow: Int) {
        let night = stage >= 9
        let dim = duskiness[stage] * 0.5
        func tinted(_ rgb: UInt32) -> UInt32 { pack(mixRGB(rgb, 0x232848, dim)) }
        var rng = SplitMix64(state: 0x6E0D &+ UInt64(stage))

        switch groundKind[stage] {
        case 0:
            canvas.rect(0, 0, canvas.width, horizonRow, tinted(0x74A754))
            canvas.rect(0, 0, canvas.width, 4, tinted(0x82B25E))
            for _ in 0..<50 {
                let x = rng.int(0, canvas.width - 1)
                let y = rng.int(0, horizonRow - 2)
                canvas.set(x, y, pack(mixRGB(0x82B25E, rng.unit() < 0.5 ? 0x3F6B38 : 0xD9E8A8, 0.4), 0.8))
            }
        case 1:
            canvas.rect(0, 0, canvas.width, horizonRow, tinted(0x74A754))
            canvas.rect(0, 0, canvas.width, 4, tinted(0x9A7B52))
            canvas.rect(0, 4, canvas.width, 1, tinted(0x84693F))
            for _ in 0..<36 {
                let x = rng.int(0, canvas.width - 1)
                canvas.set(x, rng.int(0, 3), pack(mixRGB(0x9A7B52, 0x74572F, rng.unit()), 0.8))
            }
        case 2:
            canvas.rect(0, 0, canvas.width, horizonRow, tinted(0x6C9B50))
            canvas.rect(0, 0, canvas.width, 5, tinted(0x9A9484))
            for y in 0..<5 {
                for x in 0..<canvas.width where (x + y * 2) % 4 == 0 {
                    canvas.set(x, y, tinted(0x847E6E))
                }
            }
            canvas.rect(0, 5, canvas.width, 1, tinted(0xB0AA98))
        default:
            canvas.rect(0, 0, canvas.width, horizonRow, tinted(0x62885C))
            canvas.rect(0, 0, canvas.width, 6, tinted(0x4E5058))
            canvas.rect(0, 5, canvas.width, 1, tinted(0x83858D))
            var dashX = 2
            while dashX < canvas.width {
                canvas.rect(dashX, 2, 3, 1, pack(0xD8C25E, night ? 0.8 : 1))
                dashX += 8
            }
        }
    }

    /// The 18 x 18 menu-bar silhouette: a skyline that rises with the town.
    static func drawSilhouette(stage: Int) -> PixelCanvas {
        let canvas = PixelCanvas(width: 18, height: 18)
        let black = pack(0x000000)
        canvas.rect(1, 0, 16, 1, black)

        func cottage(_ x: Int, _ w: Int, _ bodyH: Int) {
            canvas.rect(x, 1, w, bodyH, black)
            var half = w / 2 + 1
            var y = 1 + bodyH
            var left = x - 1
            while half > 0 {
                canvas.rect(left, y, half * 2, 1, black)
                left += 1
                half -= 1
                y += 1
            }
        }
        func block(_ x: Int, _ w: Int, _ h: Int) {
            canvas.rect(x, 1, w, h, black)
        }
        func tower(_ x: Int, _ w: Int, _ h: Int, antenna: Bool = false) {
            canvas.rect(x, 1, w, h, black)
            canvas.rect(x + 1, 1 + h, max(1, w - 2), 1, black)
            if antenna {
                canvas.rect(x + w / 2, 2 + h, 1, 3, black)
            }
        }

        switch stage {
        case 0: cottage(7, 5, 3)
        case 1: cottage(4, 5, 3); cottage(11, 4, 2)
        case 2: cottage(1, 4, 2); cottage(7, 5, 3); cottage(13, 4, 2)
        case 3: cottage(1, 4, 2); cottage(7, 5, 3); block(13, 3, 4)
        case 4: cottage(1, 4, 2); block(6, 4, 6); block(11, 3, 4); cottage(14, 3, 2)
        case 5: block(1, 3, 4); block(5, 4, 6); tower(10, 4, 7); cottage(14, 3, 2)
        case 6: block(1, 3, 4); tower(5, 4, 8); block(10, 4, 5); cottage(14, 3, 2)
        case 7: block(1, 3, 5); tower(5, 4, 9); tower(10, 3, 7); block(14, 3, 4)
        case 8: block(1, 3, 5); tower(5, 4, 10); tower(10, 3, 7); block(14, 3, 4)
        case 9: tower(1, 3, 8); tower(5, 4, 12, antenna: true); block(10, 3, 6); tower(14, 3, 9)
        case 10: tower(1, 3, 9); tower(5, 4, 13, antenna: true); tower(10, 4, 11); tower(15, 2, 7)
        default: tower(1, 3, 10); tower(5, 4, 14, antenna: true); tower(10, 4, 12); tower(15, 2, 8)
        }
        return canvas
    }
}

/// Individual building sprites: three period styles, four redevelopment
/// levels, each in a day and a lit-windows night variant.
enum BuildingSprites {
    // Heights must match `CompanionAssetCatalog.villageSpriteCellHeights`.
    static let cellHeights: [String: [Int]] = [
        "timber": [11, 17, 25, 31],
        "brick": [12, 18, 27, 33],
        "modern": [10, 16, 28, 35]
    ]
    static let cellWidths: [String: [Int]] = [
        "timber": [10, 11, 12, 14],
        "brick": [11, 12, 13, 15],
        "modern": [10, 11, 13, 16]
    ]

    struct Palette {
        let wall: UInt32
        let wallShade: UInt32
        let roof: UInt32
        let roofLight: UInt32
        let trim: UInt32
        let windowDay: UInt32
    }

    static let palettes: [String: Palette] = [
        "timber": Palette(
            wall: 0xEFE3C2, wallShade: 0xD6C7A0, roof: 0xB4523C,
            roofLight: 0xC96B4F, trim: 0x7A5A3C, windowDay: 0x54718A
        ),
        "brick": Palette(
            wall: 0xA85A44, wallShade: 0x8C4936, roof: 0x6E6E76,
            roofLight: 0x8A8A92, trim: 0xE0D5BC, windowDay: 0x4E6578
        ),
        "modern": Palette(
            wall: 0xB9BEC4, wallShade: 0x999FA8, roof: 0x70767E,
            roofLight: 0x878D95, trim: 0x5E7C90, windowDay: 0x9CC4DA
        )
    ]

    static let windowLit: UInt32 = 0xFFD98A
    static let windowNightDark: UInt32 = 0x2E3A54

    static func draw(style: String, level: Int, lit: Bool) -> PixelCanvas {
        let canvas = PixelCanvas(
            width: cellWidths[style]![level],
            height: cellHeights[style]![level]
        )
        drawShadow(canvas)
        let palette = palettes[style]!
        var rng = SplitMix64(state: stableHash("\(style)-\(level)"))
        // Night walls darken; lit windows carry the sprite.
        let wall = lit ? mixRGB(palette.wall, 0x232848, 0.45) : palette.wall
        let wallShade = lit ? mixRGB(palette.wallShade, 0x1B2038, 0.5) : palette.wallShade
        let roof = lit ? mixRGB(palette.roof, 0x1B2038, 0.45) : palette.roof
        let roofLight = lit ? mixRGB(palette.roofLight, 0x232848, 0.45) : palette.roofLight
        let trim = lit ? mixRGB(palette.trim, 0x232848, 0.4) : palette.trim

        let bodyWidth = canvas.width - 2
        let x0 = 1
        let pitched = level == 0 || (level == 1 && style != "brick")
        // Flat roofs reserve headroom for their furniture: a water tank on
        // brick mid-rises, an antenna mast on the modern skyscraper.
        let roofExtra = if style == "brick", level >= 2 {
            2
        } else if style == "modern", level == 3 {
            4
        } else {
            0
        }
        let roofHeight = pitched ? bodyWidth / 2 + 1 : 2 + roofExtra
        let bodyHeight = canvas.height - 1 - roofHeight

        canvas.rect(x0, 1, bodyWidth, bodyHeight, pack(wall))
        canvas.rect(x0 + bodyWidth - 2, 1, 2, bodyHeight, pack(wallShade))

        if pitched {
            var half = bodyWidth / 2 + 1
            var y = 1 + bodyHeight
            var rowColor = roofLight
            while half > 0 {
                let left = x0 + bodyWidth / 2 - half
                canvas.rect(left, y, half * 2 + bodyWidth % 2, 1, pack(rowColor))
                rowColor = roof
                half -= 1
                y += 1
            }
            // Chimney.
            canvas.rect(x0 + bodyWidth - 3, bodyHeight + roofHeight / 2, 1, roofHeight / 2 + 1, pack(trim))
        } else {
            canvas.rect(x0 - 1, 1 + bodyHeight, bodyWidth + 2, 1, pack(trim))
            canvas.rect(x0, 2 + bodyHeight, bodyWidth, 1, pack(roof))
            if style == "brick", level >= 2 {
                canvas.rect(x0 + bodyWidth - 5, 3 + bodyHeight, 3, 2, pack(wallShade))
            }
            if style == "modern", level == 3 {
                canvas.rect(
                    x0 + bodyWidth / 2, 3 + bodyHeight,
                    1, canvas.height - bodyHeight - 3, pack(trim)
                )
            }
        }

        // Door on the ground floor.
        let doorX = x0 + bodyWidth / 2 - 1
        canvas.rect(doorX, 1, 2, 3, pack(trim))
        if lit {
            canvas.rect(doorX, 1, 2, 2, pack(windowLit, 0.9))
        }

        func windowColor() -> UInt32 {
            if lit {
                rng.unit() < 0.7 ? windowLit : windowNightDark
            } else {
                palette.windowDay
            }
        }

        if level == 0 {
            // Cottages get one window either side of the door.
            canvas.rect(doorX - 3, 2, 2, 2, pack(windowColor()))
            canvas.rect(doorX + 3, 2, 2, 2, pack(windowColor()))
        } else {
            // Window grid above the door row, spread to the top floor.
            let floors = [1, 2, 5, 8][level]
            let columns = max(2, (bodyWidth - 1) / 3)
            let gridBottom = 5
            let gridHeight = bodyHeight - gridBottom
            let windowHeight = level >= 2 ? 1 : 2
            for floor in 0..<floors {
                let wy = gridBottom + floor * gridHeight / floors
                guard wy + windowHeight < bodyHeight else { continue }
                for column in 0..<columns {
                    let wx = x0 + 1 + column * (bodyWidth - 2) / columns
                    canvas.rect(wx, wy, 2, windowHeight, pack(windowColor()))
                }
            }
        }

        // Glass curtain shimmer for the modern tower.
        if style == "modern", level >= 2, !lit {
            for y in stride(from: 5, to: bodyHeight, by: 4) {
                canvas.rect(x0 + 1, y, bodyWidth - 3, 1, pack(0xC9E2EE, 0.35))
            }
        }
        return canvas
    }

    private static func drawShadow(_ canvas: PixelCanvas) {
        for x in 0..<canvas.width {
            canvas.set(x, 0, pack(0x101820, x % 2 == 0 ? 0.4 : 0.28))
        }
    }
}

// MARK: - Entry point

let arguments = CommandLine.arguments
let scriptURL = URL(fileURLWithPath: #filePath)
let repositoryRoot = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let outputRoot = arguments.count > 1
    ? URL(fileURLWithPath: arguments[1], isDirectory: true)
    : repositoryRoot.appending(path: "Resources/Companions")

verifyDeterminismContract()

do {
    try ForestArtwork.generate(into: outputRoot)
    try VillageArtwork.generate(into: outputRoot)
    print("Companion artwork written to \(outputRoot.path)")
} catch {
    print("generation failed: \(error)")
    exit(1)
}
