#!/usr/bin/env swift
// Development-time baker for the photographic companion scenes.
//
// Usage: swift Scripts/bake-companion-assets.swift <raw-root> [output-root]
//
// <raw-root> is the directory populated by Scripts/fetch-companion-assets.sh.
// The output root defaults to Resources/Companions. The baker art-directs
// each source into the final bundled 1240 x 336 scene (4x the 310 x 84 point
// canvas), so the app never ships oversized originals or crops at runtime.

import AppKit
import CoreImage

let sceneSize = CGSize(width: 1240, height: 336)
let sceneAspect = sceneSize.width / sceneSize.height
let ciContext = CIContext(options: [.useSoftwareRenderer: false])

struct BakeError: Error, CustomStringConvertible {
    let description: String
}

// MARK: - IO helpers

func loadImage(_ url: URL) throws -> CIImage {
    guard let image = CIImage(contentsOf: url) else {
        throw BakeError(description: "unreadable image: \(url.path)")
    }
    return image
}

func render(_ image: CIImage, extent: CGRect) throws -> CGImage {
    guard let cgImage = ciContext.createCGImage(image, from: extent) else {
        throw BakeError(description: "render failed")
    }
    return cgImage
}

func write(_ cgImage: CGImage, to url: URL, jpegQuality: Double?) throws {
    let rep = NSBitmapImageRep(cgImage: cgImage)
    let data: Data?
    if let jpegQuality {
        data = rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: jpegQuality]
        )
    } else {
        data = rep.representation(using: .png, properties: [:])
    }
    guard let data else {
        throw BakeError(description: "encode failed for \(url.lastPathComponent)")
    }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url)
}

// MARK: - Crops

/// A normalized crop in image coordinates: x/y measured from the top-left
/// corner, as fractions of the source. Height follows the scene aspect.
struct Crop {
    let x: Double
    let y: Double
    let width: Double

    func rect(in extent: CGRect) -> CGRect {
        let cropWidth = extent.width * width
        let cropHeight = cropWidth / sceneAspect
        return CGRect(
            x: extent.minX + extent.width * x,
            y: extent.maxY - extent.height * y - cropHeight,
            width: cropWidth,
            height: cropHeight
        )
    }
}

// MARK: - Scenery variants
//
// Each scene ships three vantages of the same location so the daily rotation
// never repeats a plate two days running. Variants are derived from the
// vetted base crop against the source's real dimensions: a lateral shift
// where the source has room, otherwise a zoom anchored to the crop's bottom
// edge — so the walkable ground line is preserved by construction.

let sceneryVariantSuffixes = ["a", "b", "c"]

func heightFraction(ofCropWidth width: Double, in extent: CGRect) -> Double {
    (width * extent.width / sceneAspect) / extent.height
}

func laterallyShifted(_ crop: Crop, by dx: Double) -> Crop {
    Crop(
        x: min(max(crop.x + dx, 0), 1 - crop.width),
        y: crop.y,
        width: crop.width
    )
}

func bottomAnchoredZoom(
    _ crop: Crop,
    scale: Double,
    bias: Double,
    in extent: CGRect
) -> Crop {
    let width = crop.width * scale
    let bottom = crop.y + heightFraction(ofCropWidth: crop.width, in: extent)
    return Crop(
        x: min(max(crop.x + (crop.width - width) * bias, 0), 1 - width),
        y: bottom - heightFraction(ofCropWidth: width, in: extent),
        width: width
    )
}

func derivedVariants(of crop: Crop, in extent: CGRect) -> [Crop] {
    let roomLeft = crop.x
    let roomRight = 1 - crop.x - crop.width
    let room = max(roomLeft, roomRight)
    let vantageB: Crop
    if room >= 0.06 {
        let direction: Double = roomRight >= roomLeft ? 1 : -1
        vantageB = laterallyShifted(crop, by: direction * min(room, crop.width * 0.22))
    } else {
        vantageB = bottomAnchoredZoom(crop, scale: 0.9, bias: 0.15, in: extent)
    }
    return [vantageB, bottomAnchoredZoom(crop, scale: 0.82, bias: 0.7, in: extent)]
}

/// "Backgrounds/01-lumbridge.jpg" -> "Backgrounds/01-lumbridge-b.jpg"
func variantOutputPath(_ path: String, suffix: String) -> String {
    guard let dot = path.lastIndex(of: ".") else { return "\(path)-\(suffix)" }
    return "\(path[..<dot])-\(suffix)\(path[dot...])"
}

func lanczosScale(_ image: CIImage, scale: Double) -> CIImage {
    let filter = CIFilter(name: "CILanczosScaleTransform")!
    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(scale, forKey: kCIInputScaleKey)
    filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
    return filter.outputImage!
}

/// Crops the source and scales it to the 1240 x 336 scene.
func bakeScene(_ source: CIImage, crop: Crop) throws -> CIImage {
    let cropRect = crop.rect(in: source.extent).integral
    guard source.extent.insetBy(dx: -1, dy: -1).contains(cropRect) else {
        throw BakeError(description: "crop escapes source: \(cropRect) in \(source.extent)")
    }
    let cropped = source.cropped(to: cropRect)
        .transformed(by: .init(translationX: -cropRect.minX, y: -cropRect.minY))
    let scaled = lanczosScale(cropped, scale: sceneSize.width / cropRect.width)
    return scaled.cropped(to: CGRect(origin: .zero, size: sceneSize))
}

// MARK: - Selective hue rotation (Dark Age blue -> purple player color)

func shiftBlueTrimToPurple(_ cgImage: CGImage) throws -> CGImage {
    // Rotate strongly blue pixels toward the purple player color used by the
    // West European Feudal/Castle/Imperial set renders, so all eight stages
    // read as one civilization.
    let width = cgImage.width
    let height = cgImage.height
    let bytesPerRow = width * 4
    var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
    guard let context = CGContext(
        data: &buffer,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw BakeError(description: "hue-shift context failed")
    }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    for offset in stride(from: 0, to: buffer.count, by: 4) {
        let r = Double(buffer[offset]) / 255
        let g = Double(buffer[offset + 1]) / 255
        let b = Double(buffer[offset + 2]) / 255
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        guard delta > 0.10, maxC > 0.12 else { continue }
        var hue: Double
        if maxC == r {
            hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        let saturation = delta / maxC
        guard hue >= 196, hue <= 252, saturation >= 0.26 else { continue }
        let shifted = (hue + 52).truncatingRemainder(dividingBy: 360)
        // The native late-age player purple is darker and less saturated
        // than a pure hue rotation of this blue, so temper the chroma.
        let temperedDelta = delta * 0.72
        let hp = shifted / 60
        let x = temperedDelta * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let rgb1: (Double, Double, Double)
        switch hp {
        case ..<1: rgb1 = (temperedDelta, x, 0)
        case ..<2: rgb1 = (x, temperedDelta, 0)
        case ..<3: rgb1 = (0, temperedDelta, x)
        case ..<4: rgb1 = (0, x, temperedDelta)
        case ..<5: rgb1 = (x, 0, temperedDelta)
        default: rgb1 = (temperedDelta, 0, x)
        }
        let m = maxC * 0.92 - temperedDelta
        buffer[offset] = UInt8(((rgb1.0 + m) * 255).rounded().clamped(to: 0...255))
        buffer[offset + 1] = UInt8(((rgb1.1 + m) * 255).rounded().clamped(to: 0...255))
        buffer[offset + 2] = UInt8(((rgb1.2 + m) * 255).rounded().clamped(to: 0...255))
    }

    guard let shifted = context.makeImage() else {
        throw BakeError(description: "hue-shift render failed")
    }
    return shifted
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Pokémon painted foreground

struct ForegroundPalette {
    let deep: NSColor
    let mid: NSColor
    let rim: NSColor

    static let meadow = ForegroundPalette(
        deep: color(0x3F7040), mid: color(0x5B9150), rim: color(0x8BBF70)
    )
    static let forest = ForegroundPalette(
        deep: color(0x2E5A34), mid: color(0x477B44), rim: color(0x74A85F)
    )
    static let volcanic = ForegroundPalette(
        deep: color(0x6E5A42), mid: color(0x8C7554), rim: color(0xB59B72)
    )

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Paints a soft foreground meadow band along the bottom of the scene so a
/// subject can stand in front of the location vista without floating on it.
/// The band matches the painterly style of the Let's Go location renders.
func addPaintedForeground(
    to cgImage: CGImage,
    palette: ForegroundPalette,
    bandHeight: Double = 0.215,
    phase: Double = 0
) throws -> CGImage {
    let width = CGFloat(cgImage.width)
    let height = CGFloat(cgImage.height)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: cgImage.width,
        pixelsHigh: cgImage.height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw BakeError(description: "foreground context failed")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height))

    let bandTop = height * bandHeight
    func edgeY(_ x: CGFloat) -> CGFloat {
        bandTop
            + height * 0.016 * sin(x / width * .pi * 2 * 1.35 + phase)
            + height * 0.008 * sin(x / width * .pi * 2 * 3.1 + phase * 1.7)
    }
    let band = NSBezierPath()
    band.move(to: NSPoint(x: 0, y: 0))
    band.line(to: NSPoint(x: 0, y: edgeY(0)))
    let steps = 60
    for step in 1...steps {
        let x = width * CGFloat(step) / CGFloat(steps)
        band.line(to: NSPoint(x: x, y: edgeY(x)))
    }
    band.line(to: NSPoint(x: width, y: 0))
    band.close()

    NSGraphicsContext.current?.saveGraphicsState()
    band.addClip()
    NSGradient(
        colors: [palette.deep, palette.mid],
        atLocations: [0, 1],
        colorSpace: .deviceRGB
    )!.draw(
        in: NSRect(x: 0, y: 0, width: width, height: bandTop + height * 0.03),
        angle: 90
    )
    NSGraphicsContext.current?.restoreGraphicsState()

    // A sunlit rim along the band's top edge separates it from the vista.
    let rim = NSBezierPath()
    rim.move(to: NSPoint(x: 0, y: edgeY(0)))
    for step in 1...steps {
        let x = width * CGFloat(step) / CGFloat(steps)
        rim.line(to: NSPoint(x: x, y: edgeY(x)))
    }
    rim.lineWidth = height * 0.012
    palette.rim.withAlphaComponent(0.9).setStroke()
    rim.stroke()

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let out = rep.cgImage else {
        throw BakeError(description: "foreground render failed")
    }
    return out
}

// MARK: - Alpha trimming for subject layers

func trimmedSubject(_ url: URL, padding: Int = 3) throws -> CGImage {
    guard let image = NSImage(contentsOf: url) else {
        throw BakeError(description: "unreadable subject: \(url.path)")
    }
    var rect = NSRect(origin: .zero, size: image.size)
    guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
        throw BakeError(description: "no bitmap for \(url.path)")
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = -1, maxY = -1
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    guard maxX >= minX, maxY >= minY else {
        throw BakeError(description: "fully transparent subject: \(url.path)")
    }
    minX = max(0, minX - padding); minY = max(0, minY - padding)
    maxX = min(rep.pixelsWide - 1, maxX + padding)
    maxY = min(rep.pixelsHigh - 1, maxY + padding)
    guard let trimmed = cgImage.cropping(
        to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    ) else {
        throw BakeError(description: "trim failed: \(url.path)")
    }
    return trimmed
}

// MARK: - Theme bakes

struct SceneBake {
    let input: String
    let output: String
    let crop: Crop
    var shiftsBlueToPurple = false
    var foreground: ForegroundPalette?
    var foregroundPhase = 0.0
}

let osrsScenes: [SceneBake] = [
    SceneBake(
        input: "osrs/backgrounds/01-lumbridge.png",
        output: "OldSchoolRuneScape/Backgrounds/01-lumbridge.jpg",
        crop: Crop(x: 0.06, y: 0.16, width: 0.92)
    ),
    SceneBake(
        input: "osrs/backgrounds/02-al-kharid.png",
        output: "OldSchoolRuneScape/Backgrounds/02-al-kharid.jpg",
        crop: Crop(x: 0.08, y: 0.36, width: 0.86)
    ),
    SceneBake(
        input: "osrs/backgrounds/03-varrock.png",
        output: "OldSchoolRuneScape/Backgrounds/03-varrock.jpg",
        crop: Crop(x: 0.05, y: 0.3, width: 0.9)
    ),
    SceneBake(
        input: "osrs/backgrounds/04-karamja.png",
        output: "OldSchoolRuneScape/Backgrounds/04-karamja.jpg",
        crop: Crop(x: 0.02, y: 0.3, width: 0.9)
    ),
    SceneBake(
        input: "osrs/backgrounds/05-grand-exchange.png",
        output: "OldSchoolRuneScape/Backgrounds/05-grand-exchange.jpg",
        crop: Crop(x: 0.04, y: 0.3, width: 0.92)
    ),
    SceneBake(
        input: "osrs/backgrounds/06-falador.png",
        output: "OldSchoolRuneScape/Backgrounds/06-falador.jpg",
        crop: Crop(x: 0.05, y: 0.42, width: 0.9)
    ),
    SceneBake(
        input: "osrs/backgrounds/07-seers-village.png",
        output: "OldSchoolRuneScape/Backgrounds/07-seers-village.jpg",
        crop: Crop(x: 0.05, y: 0.34, width: 0.9)
    ),
    SceneBake(
        input: "osrs/backgrounds/08-east-ardougne.png",
        output: "OldSchoolRuneScape/Backgrounds/08-east-ardougne.jpg",
        crop: Crop(x: 0.0, y: 0.38, width: 0.86)
    ),
    SceneBake(
        input: "osrs/backgrounds/09-canifis.png",
        output: "OldSchoolRuneScape/Backgrounds/09-canifis.jpg",
        crop: Crop(x: 0.06, y: 0.34, width: 0.86)
    ),
    SceneBake(
        input: "osrs/backgrounds/10-god-wars.png",
        output: "OldSchoolRuneScape/Backgrounds/10-god-wars.jpg",
        crop: Crop(x: 0.03, y: 0.3, width: 0.94)
    ),
    SceneBake(
        input: "osrs/backgrounds/11-prifddinas.png",
        output: "OldSchoolRuneScape/Backgrounds/11-prifddinas.jpg",
        crop: Crop(x: 0.02, y: 0.42, width: 0.94)
    ),
    SceneBake(
        input: "osrs/backgrounds/12-tombs-of-amascut.png",
        output: "OldSchoolRuneScape/Backgrounds/12-tombs-of-amascut.jpg",
        crop: Crop(x: 0.08, y: 0.3, width: 0.84)
    )
]

let ageOfEmpiresScenes: [SceneBake] = [
    SceneBake(
        input: "aoe2/dark-age-set.png",
        output: "AgeOfEmpiresII/scenes/01-dark-age-camp.jpg",
        crop: Crop(x: 0.0, y: 0.03, width: 0.48),
        shiftsBlueToPurple: true
    ),
    SceneBake(
        input: "aoe2/dark-age-set.png",
        output: "AgeOfEmpiresII/scenes/02-dark-age-hamlet.jpg",
        crop: Crop(x: 0.0, y: 0.33, width: 0.58),
        shiftsBlueToPurple: true
    ),
    SceneBake(
        input: "aoe2/dark-age-set.png",
        output: "AgeOfEmpiresII/scenes/03-dark-age-town.jpg",
        crop: Crop(x: 0.34, y: 0.42, width: 0.64),
        shiftsBlueToPurple: true
    ),
    SceneBake(
        input: "aoe2/feudal-age-set.png",
        output: "AgeOfEmpiresII/scenes/04-feudal-age.jpg",
        crop: Crop(x: 0.52, y: 0.04, width: 0.48)
    ),
    SceneBake(
        input: "aoe2/feudal-age-set.png",
        output: "AgeOfEmpiresII/scenes/05-feudal-village.jpg",
        crop: Crop(x: 0.0, y: 0.12, width: 0.55)
    ),
    SceneBake(
        input: "aoe2/feudal-age-set.png",
        output: "AgeOfEmpiresII/scenes/06-feudal-town.jpg",
        crop: Crop(x: 0.16, y: 0.48, width: 0.72)
    ),
    SceneBake(
        input: "aoe2/castle-age-set.png",
        output: "AgeOfEmpiresII/scenes/07-castle-age.jpg",
        crop: Crop(x: 0.02, y: 0.27, width: 0.54)
    ),
    SceneBake(
        input: "aoe2/castle-age-set.png",
        output: "AgeOfEmpiresII/scenes/08-castle-village.jpg",
        crop: Crop(x: 0.0, y: 0.06, width: 0.56)
    ),
    SceneBake(
        input: "aoe2/castle-age-set.png",
        output: "AgeOfEmpiresII/scenes/09-castle-town.jpg",
        crop: Crop(x: 0.28, y: 0.35, width: 0.68)
    ),
    SceneBake(
        input: "aoe2/imperial-age-set.png",
        output: "AgeOfEmpiresII/scenes/10-imperial-age.jpg",
        crop: Crop(x: 0.5, y: 0.17, width: 0.5)
    ),
    SceneBake(
        input: "aoe2/imperial-age-set.png",
        output: "AgeOfEmpiresII/scenes/11-imperial-city.jpg",
        crop: Crop(x: 0.32, y: 0.6, width: 0.68)
    ),
    SceneBake(
        input: "aoe2/imperial-age-set.png",
        output: "AgeOfEmpiresII/scenes/12-imperial-capital.jpg",
        crop: Crop(x: 0.5, y: 0.75, width: 0.5)
    )
]

let pokemonScenes: [SceneBake] = [
    SceneBake(
        input: "pokemon/backgrounds/01-pallet-town.png",
        output: "Pokemon/scenes/01-pallet-town.jpg",
        crop: Crop(x: 0.02, y: 0.1, width: 0.96),
        foreground: .meadow,
        foregroundPhase: 0.0
    ),
    SceneBake(
        input: "pokemon/backgrounds/02-viridian-forest.png",
        output: "Pokemon/scenes/02-viridian-forest.jpg",
        crop: Crop(x: 0.02, y: 0.26, width: 0.96),
        foreground: .forest,
        foregroundPhase: 1.1
    ),
    SceneBake(
        input: "pokemon/backgrounds/03-pewter-city.png",
        output: "Pokemon/scenes/03-pewter-city.jpg",
        crop: Crop(x: 0.02, y: 0.26, width: 0.96),
        foreground: .meadow,
        foregroundPhase: 1.7
    ),
    SceneBake(
        input: "pokemon/backgrounds/04-cerulean-city.png",
        output: "Pokemon/scenes/04-cerulean-city.jpg",
        crop: Crop(x: 0.02, y: 0.3, width: 0.96),
        foreground: .meadow,
        foregroundPhase: 2.3
    ),
    SceneBake(
        input: "pokemon/backgrounds/05-vermilion-city.png",
        output: "Pokemon/scenes/05-vermilion-city.jpg",
        crop: Crop(x: 0.02, y: 0.24, width: 0.96),
        foreground: .meadow,
        foregroundPhase: 3.4
    ),
    SceneBake(
        input: "pokemon/backgrounds/06-lavender-town.png",
        output: "Pokemon/scenes/06-lavender-town.jpg",
        crop: Crop(x: 0.02, y: 0.3, width: 0.96),
        foreground: .meadow,
        foregroundPhase: 3.9
    ),
    SceneBake(
        input: "pokemon/backgrounds/07-celadon-city.png",
        output: "Pokemon/scenes/07-celadon-city.jpg",
        crop: Crop(x: 0.04, y: 0.24, width: 0.94),
        foreground: .meadow,
        foregroundPhase: 4.2
    ),
    SceneBake(
        input: "pokemon/backgrounds/08-saffron-city.png",
        output: "Pokemon/scenes/08-saffron-city.jpg",
        crop: Crop(x: 0.02, y: 0.32, width: 0.96),
        foreground: .meadow,
        foregroundPhase: 4.6
    ),
    SceneBake(
        input: "pokemon/backgrounds/09-fuchsia-city.png",
        output: "Pokemon/scenes/09-fuchsia-city.jpg",
        crop: Crop(x: 0.02, y: 0.16, width: 0.96),
        foreground: .meadow,
        foregroundPhase: 5.0
    ),
    SceneBake(
        input: "pokemon/backgrounds/10-cinnabar-island.png",
        output: "Pokemon/scenes/10-cinnabar-island.jpg",
        crop: Crop(x: 0.02, y: 0.28, width: 0.96),
        foreground: .volcanic,
        foregroundPhase: 5.9
    ),
    SceneBake(
        input: "pokemon/backgrounds/11-victory-road.png",
        output: "Pokemon/scenes/11-victory-road.jpg",
        crop: Crop(x: 0.02, y: 0.3, width: 0.96),
        foreground: .volcanic,
        foregroundPhase: 6.3
    ),
    SceneBake(
        input: "pokemon/backgrounds/12-indigo-plateau.png",
        output: "Pokemon/scenes/12-indigo-plateau.jpg",
        crop: Crop(x: 0.02, y: 0.2, width: 0.96),
        foreground: .forest,
        foregroundPhase: 0.7
    )
]

let minecraftScenes: [SceneBake] = [
    SceneBake(
        input: "minecraft/backgrounds/01-plains.png",
        output: "Minecraft/scenes/01-plains.jpg",
        crop: Crop(x: 0.0, y: 0.35, width: 1.0)
    ),
    SceneBake(
        input: "minecraft/backgrounds/02-forest.png",
        output: "Minecraft/scenes/02-forest.jpg",
        crop: Crop(x: 0.0, y: 0.4, width: 1.0)
    ),
    SceneBake(
        input: "minecraft/backgrounds/03-village.jpg",
        output: "Minecraft/scenes/03-village.jpg",
        crop: Crop(x: 0.0, y: 0.08, width: 1.0)
    ),
    SceneBake(
        input: "minecraft/backgrounds/04-lush-caves.png",
        output: "Minecraft/scenes/04-lush-caves.jpg",
        crop: Crop(x: 0.0, y: 0.35, width: 1.0)
    ),
    SceneBake(
        input: "minecraft/backgrounds/05-jagged-peaks.png",
        output: "Minecraft/scenes/05-jagged-peaks.jpg",
        crop: Crop(x: 0.0, y: 0.3, width: 1.0)
    ),
    SceneBake(
        input: "minecraft/backgrounds/06-ancient-city.png",
        output: "Minecraft/scenes/06-ancient-city.jpg",
        crop: Crop(x: 0.0, y: 0.35, width: 1.0)
    ),
    SceneBake(
        input: "minecraft/backgrounds/07-nether-wastes.png",
        output: "Minecraft/scenes/07-nether-wastes.jpg",
        crop: Crop(x: 0.0, y: 0.35, width: 1.0)
    ),
    SceneBake(
        input: "minecraft/backgrounds/08-crimson-forest.png",
        output: "Minecraft/scenes/08-crimson-forest.jpg",
        crop: Crop(x: 0.0, y: 0.4, width: 1.0)
    ),
    SceneBake(
        input: "minecraft/backgrounds/09-nether-fortress.png",
        output: "Minecraft/scenes/09-nether-fortress.jpg",
        crop: Crop(x: 0.0, y: 0.4, width: 1.0)
    ),
    SceneBake(
        input: "minecraft/backgrounds/10-stronghold.png",
        output: "Minecraft/scenes/10-stronghold.jpg",
        crop: Crop(x: 0.0, y: 0.32, width: 1.0)
    ),
    SceneBake(
        input: "minecraft/backgrounds/11-the-end.png",
        output: "Minecraft/scenes/11-the-end.jpg",
        crop: Crop(x: 0.0, y: 0.45, width: 1.0)
    ),
    SceneBake(
        input: "minecraft/backgrounds/12-end-city.png",
        output: "Minecraft/scenes/12-end-city.jpg",
        crop: Crop(x: 0.0, y: 0.45, width: 1.0)
    )
]

let osrsCharacters = [
    "01-leather", "02-frog-leather", "03-studded-leather", "04-snakeskin",
    "05-green-dhide", "06-blue-dhide", "07-red-dhide", "08-black-dhide",
    "09-karils", "10-armadyl", "11-crystal", "12-masori"
]

let minecraftCharacters = [
    "steve", "leather", "golden", "chainmail", "iron", "diamond", "netherite"
]

let pokemonArtworkIDs = [
    1, 2, 3, 4, 5, 6, 7, 8, 9,
    152, 153, 154, 155, 156, 157, 158, 159, 160,
    252, 253, 254, 255, 256, 257, 258, 259, 260,
    387, 388, 389, 390, 391, 392, 393, 394, 395
]

// MARK: - Entry point

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: swift Scripts/bake-companion-assets.swift <raw-root> [output-root]")
    exit(64)
}
let rawRoot = URL(fileURLWithPath: arguments[1], isDirectory: true)
let scriptURL = URL(fileURLWithPath: #filePath)
let repositoryRoot = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let outputRoot = arguments.count > 2
    ? URL(fileURLWithPath: arguments[2], isDirectory: true)
    : repositoryRoot.appending(path: "Resources/Companions")

do {
    for bake in osrsScenes + ageOfEmpiresScenes + pokemonScenes + minecraftScenes {
        let source = try loadImage(rawRoot.appending(path: bake.input))
        let crops = [bake.crop] + derivedVariants(of: bake.crop, in: source.extent)
        for (variant, crop) in crops.enumerated() {
            let image = try bakeScene(source, crop: crop)
            var cgImage = try render(image, extent: CGRect(origin: .zero, size: sceneSize))
            if bake.shiftsBlueToPurple {
                cgImage = try shiftBlueTrimToPurple(cgImage)
            }
            if let palette = bake.foreground {
                cgImage = try addPaintedForeground(
                    to: cgImage,
                    palette: palette,
                    // The meadow band waves differently on each variant.
                    phase: bake.foregroundPhase + Double(variant) * 1.9
                )
            }
            let output = variantOutputPath(
                bake.output,
                suffix: sceneryVariantSuffixes[variant]
            )
            try write(
                cgImage,
                to: outputRoot.appending(path: output),
                jpegQuality: 0.87
            )
            print("baked \(output)")
        }
    }

    for name in osrsCharacters {
        let subject = try trimmedSubject(
            rawRoot.appending(path: "osrs/characters/\(name).png")
        )
        try write(
            subject,
            to: outputRoot.appending(path: "OldSchoolRuneScape/Characters/\(name).png"),
            jpegQuality: nil
        )
    }
    print("baked \(osrsCharacters.count) OSRS characters")

    for name in minecraftCharacters {
        let subject = try trimmedSubject(
            rawRoot.appending(path: "minecraft/characters/\(name).png")
        )
        try write(
            subject,
            to: outputRoot.appending(path: "Minecraft/characters/\(name).png"),
            jpegQuality: nil
        )
    }
    print("baked \(minecraftCharacters.count) Minecraft characters")

    for id in pokemonArtworkIDs {
        let subject = try trimmedSubject(
            rawRoot.appending(path: String(format: "pokemon/artwork/%d.png", id))
        )
        try write(
            subject,
            to: outputRoot.appending(path: String(format: "Pokemon/art/%03d.png", id)),
            jpegQuality: nil
        )
    }
    print("baked \(pokemonArtworkIDs.count) Pokémon artworks")
} catch {
    print("bake failed: \(error)")
    exit(1)
}
