import AppKit
import Foundation

/// The optional 18 x 18 menu-bar silhouette. It reads the same bundled subject
/// artwork the scenes use, so a stage's icon can never drift from its scene.
@MainActor
enum CompanionMenuIconRenderer {
    static let iconSize = NSSize(width: 18, height: 18)

    static func image(
        theme: CompanionTheme,
        variant: CompanionVariant,
        stage: Int
    ) -> NSImage {
        let stage = CompanionJourney.clamped(stage: stage)
        if theme == .ageOfEmpiresII || theme == .banished {
            return settlementGlyph(stage: stage)
        }
        if theme == .frostpunk {
            return generatorGlyph(stage: stage)
        }
        if let resource = CompanionAssetCatalog.menuIconResource(
            theme: theme,
            variant: variant,
            stage: stage
        ), let source = CompanionAssetImageStore.image(resource: resource) {
            return templateSilhouette(from: source)
        }

        let symbolName = switch theme {
        case .none: "circle"
        case .pokemon: "pawprint.fill"
        case .forest: "tree.fill"
        case .village: "building.2.fill"
        case .oldSchoolRuneScape: "figure.walk"
        case .ageOfEmpiresII: "building.columns.fill"
        case .minecraft: "cube.fill"
        case .banished: "house.and.flag.fill"
        case .frostpunk: "snowflake"
        }
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            ?? NSImage(size: iconSize)
        symbol.size = iconSize
        symbol.isTemplate = true
        return symbol
    }

    /// Fits the source artwork into 18 x 18; the menu bar then renders its
    /// alpha channel as a template silhouette.
    private static func templateSilhouette(from source: NSImage) -> NSImage {
        let image = NSImage(size: iconSize, flipped: false) { destination in
            let size = source.size
            guard size.width > 0, size.height > 0 else { return false }
            let scale = min(destination.width / size.width, destination.height / size.height)
            let drawSize = NSSize(width: size.width * scale, height: size.height * scale)
            let drawRect = NSRect(
                x: destination.midX - drawSize.width / 2,
                y: destination.midY - drawSize.height / 2,
                width: drawSize.width,
                height: drawSize.height
            )
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Age of Empires II scenes are opaque screenshots, so the menu icon is
    /// a drawn settlement silhouette that advances with the age journey.
    private static func settlementGlyph(stage: Int) -> NSImage {
        let image = NSImage(size: iconSize, flipped: false) { _ in
            let path = settlementGlyphPath(stage: stage)
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func settlementGlyphPath(stage: Int) -> NSBezierPath {
        let path = NSBezierPath()
        let baseline: CGFloat = 2.5

        func ground(width: CGFloat = 15) {
            path.appendRect(NSRect(x: 9 - width / 2, y: baseline - 1.4, width: width, height: 1.4))
        }

        func hut(centerX: CGFloat, width: CGFloat, height: CGFloat) {
            let bodyHeight = height * 0.62
            path.appendRect(NSRect(
                x: centerX - width / 2,
                y: baseline,
                width: width,
                height: bodyHeight
            ))
            let roof = NSBezierPath()
            roof.move(to: NSPoint(x: centerX - width / 2 - 0.9, y: baseline + bodyHeight))
            roof.line(to: NSPoint(x: centerX, y: baseline + height))
            roof.line(to: NSPoint(x: centerX + width / 2 + 0.9, y: baseline + bodyHeight))
            roof.close()
            path.append(roof)
        }

        func crenellatedTower(centerX: CGFloat, width: CGFloat, height: CGFloat) {
            path.appendRect(NSRect(
                x: centerX - width / 2,
                y: baseline,
                width: width,
                height: height
            ))
            let merlonWidth = width / 3
            for index in 0..<2 {
                path.appendRect(NSRect(
                    x: centerX - width / 2 + CGFloat(index) * (width - merlonWidth),
                    y: baseline + height,
                    width: merlonWidth,
                    height: 1.8
                ))
            }
        }

        func spire(centerX: CGFloat, width: CGFloat, bodyHeight: CGFloat, spireHeight: CGFloat) {
            path.appendRect(NSRect(
                x: centerX - width / 2,
                y: baseline,
                width: width,
                height: bodyHeight
            ))
            let tip = NSBezierPath()
            tip.move(to: NSPoint(x: centerX - width / 2, y: baseline + bodyHeight))
            tip.line(to: NSPoint(x: centerX, y: baseline + bodyHeight + spireHeight))
            tip.line(to: NSPoint(x: centerX + width / 2, y: baseline + bodyHeight))
            tip.close()
            path.append(tip)
        }

        switch stage {
        case 0:
            ground(width: 11)
            hut(centerX: 9, width: 7.5, height: 8)
        case 1:
            ground()
            hut(centerX: 5.6, width: 6.4, height: 7)
            hut(centerX: 12.6, width: 5.2, height: 5.6)
        case 2:
            ground()
            hut(centerX: 6, width: 7, height: 8.6)
            path.appendRect(NSRect(x: 11.4, y: baseline, width: 1.5, height: 4.6))
            path.appendRect(NSRect(x: 13.7, y: baseline, width: 1.5, height: 5.6))
            path.appendRect(NSRect(x: 16, y: baseline, width: 1.5, height: 4.6))
        case 3:
            ground()
            hut(centerX: 4.6, width: 5.6, height: 6.4)
            path.appendRect(NSRect(x: 8.4, y: baseline, width: 8.2, height: 4.2))
            crenellatedTower(centerX: 14.6, width: 4.4, height: 7.4)
        case 4:
            ground()
            hut(centerX: 4, width: 5, height: 6)
            path.appendRect(NSRect(x: 7.2, y: baseline, width: 4.6, height: 4.2))
            crenellatedTower(centerX: 14, width: 4.4, height: 8.2)
        case 5:
            ground()
            crenellatedTower(centerX: 4.4, width: 4.4, height: 8.2)
            path.appendRect(NSRect(x: 6.8, y: baseline, width: 4.8, height: 4.6))
            hut(centerX: 14.2, width: 5, height: 6)
        case 6:
            ground(width: 13)
            crenellatedTower(centerX: 9, width: 6.6, height: 10.4)
        case 7:
            ground()
            crenellatedTower(centerX: 5, width: 5, height: 9.2)
            hut(centerX: 12.6, width: 5.2, height: 5.8)
        case 8:
            ground()
            crenellatedTower(centerX: 4.4, width: 4.4, height: 9.2)
            path.appendRect(NSRect(x: 6.4, y: baseline, width: 5.2, height: 5))
            crenellatedTower(centerX: 13.6, width: 4.4, height: 9.2)
        case 9:
            ground()
            spire(centerX: 9, width: 6.2, bodyHeight: 7.6, spireHeight: 5.4)
            path.appendRect(NSRect(x: 2.4, y: baseline, width: 3.4, height: 4.4))
            path.appendRect(NSRect(x: 12.4, y: baseline, width: 3.4, height: 4.4))
        case 10:
            ground(width: 17)
            spire(centerX: 9, width: 5.4, bodyHeight: 8.2, spireHeight: 5.6)
            crenellatedTower(centerX: 3.2, width: 3.8, height: 8.4)
            crenellatedTower(centerX: 14.8, width: 3.8, height: 8.4)
        default:
            ground(width: 17)
            spire(centerX: 9, width: 5.8, bodyHeight: 9, spireHeight: 5.8)
            crenellatedTower(centerX: 3, width: 4, height: 9.6)
            crenellatedTower(centerX: 15, width: 4, height: 9.6)
        }
        return path
    }

    /// Frostpunk's Generator grows from a bare furnace into the many-ringed
    /// heart of New London, keeping the menu silhouette stage-readable.
    private static func generatorGlyph(stage: Int) -> NSImage {
        let image = NSImage(size: iconSize, flipped: false) { _ in
            let path = NSBezierPath()
            let tier = min(max(stage, 0), CompanionJourney.thresholds.count - 1)
            let coreHeight = CGFloat(7.0 + Double(tier) * 0.22)
            path.appendRect(NSRect(x: 6.25, y: 2.1, width: 5.5, height: coreHeight))
            path.appendRect(NSRect(x: 5.2, y: 2.0, width: 7.6, height: 1.5))
            path.appendRect(NSRect(x: 7.2, y: 2.0 + coreHeight, width: 3.6, height: 2.0))

            let rings = min(4, 1 + tier / 3)
            for index in 0..<rings {
                let y = CGFloat(4.0 + Double(index) * 2.25)
                path.appendRect(NSRect(x: 4.9, y: y, width: 8.2, height: 0.9))
            }
            if tier >= 4 {
                path.appendRect(NSRect(x: 3.4, y: 3.0, width: 1.6, height: 5.4))
            }
            if tier >= 7 {
                path.appendRect(NSRect(x: 13.0, y: 3.0, width: 1.6, height: 6.8))
            }
            if tier >= 10 {
                path.appendRect(NSRect(x: 2.0, y: 2.0, width: 1.4, height: 3.6))
                path.appendRect(NSRect(x: 14.6, y: 2.0, width: 1.4, height: 4.6))
            }
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
