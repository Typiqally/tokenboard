#if DEBUG
import AppKit
import CryptoKit
import SwiftUI

/// Development-only export. Invoked before AppDelegate is constructed, so it
/// cannot open the ledger, preferences, source folders, or Discord connection.
@MainActor
enum DiscordArtworkExporter {
    struct Manifest: Codable {
        let schemaVersion: Int
        let imageSize: Int
        let previewSize: Int
        let entries: [Entry]
    }

    struct Entry: Codable {
        let key: String
        let theme: String
        let variant: String
        let stage: Int
        let tooltip: String
        let imageSHA256: String
        let previewSHA256: String
    }

    enum ExportError: Error {
        case destinationExists
        case missingResources
        case renderFailed(String)
    }

    static func export(to destination: URL) throws {
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path) else {
            throw ExportError.destinationExists
        }
        let parent = destination.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appending(path: ".discord-export-\(UUID().uuidString)")
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        for directory in ["images", "previews", "review"] {
            try files.createDirectory(at: staging.appending(path: directory), withIntermediateDirectories: false)
        }

        var entries: [Entry] = []
        for artwork in DiscordCompanionArtwork.all {
            try autoreleasepool {
                let composition = CompanionSceneComposition.make(
                    presentation: artwork.presentation,
                    size: CGSize(width: 256, height: 256), layout: .discordIcon
                )
                let view = CompanionSceneCanvas(composition: composition, elapsed: 0, isMoving: false)
                    .frame(width: 256, height: 256)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 4
                guard let image = renderer.cgImage else { throw ExportError.renderFailed(artwork.key) }
                let full = try png(image)
                let preview = try png(resize(image, size: 128))
                try full.write(to: staging.appending(path: "images/\(artwork.key).png"))
                try preview.write(to: staging.appending(path: "previews/\(artwork.previewFilename)"))
                entries.append(Entry(
                    key: artwork.key, theme: artwork.theme.rawValue, variant: artwork.variant.id,
                    stage: artwork.stage, tooltip: artwork.tooltip,
                    imageSHA256: hash(full), previewSHA256: hash(preview)
                ))
            }
        }
        guard CompanionDiagnostics.shared.issues.isEmpty,
              let resources = CompanionAssetImageStore.baseDirectory?.deletingLastPathComponent(),
              let logo = NSImage(contentsOf: resources.appending(path: "AppIcon.png"))?
                .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ExportError.missingResources
        }
        try png(resize(logo, size: 128)).write(to: staging.appending(path: "previews/tokenboard.png"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(Manifest(
            schemaVersion: 1, imageSize: 1024, previewSize: 128, entries: entries
        )).write(to: staging.appending(path: "catalog.json"))
        try reviewSheet(
            artwork: DiscordCompanionArtwork.all.filter { $0.theme == .pokemon },
            root: staging, name: "pokemon"
        )
        try reviewSheet(
            artwork: DiscordCompanionArtwork.all.filter { $0.theme != .pokemon },
            root: staging, name: "worlds"
        )
        try files.moveItem(at: staging, to: destination)
        print("Exported \(entries.count) Discord scenes to \(destination.path)")
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func png(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ExportError.renderFailed("PNG encoding")
        }
        return data
    }

    private static func resize(_ image: CGImage, size: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ExportError.renderFailed("resizing") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let result = context.makeImage() else { throw ExportError.renderFailed("resizing") }
        return result
    }

    private static func reviewSheet(artwork: [DiscordCompanionArtwork], root: URL, name: String) throws {
        let tile = 96
        let rowHeight = 120
        let rows = artwork.count / CompanionJourney.stageCount
        let image = NSImage(size: NSSize(width: tile * 12, height: rows * rowHeight))
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        for (index, entry) in artwork.enumerated() {
            let x = index % 12 * tile
            let y = (rows - index / 12 - 1) * rowHeight
            let preview = NSImage(contentsOf: root.appending(path: "previews/\(entry.previewFilename)"))!
            preview.draw(in: NSRect(x: x, y: y + 20, width: tile, height: tile))
            let label = "\(entry.theme == .pokemon ? entry.variant.title : entry.theme.title) \(entry.stage + 1)"
            (label as NSString).draw(
                in: NSRect(x: x + 2, y: y, width: tile - 4, height: 20),
                withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.labelColor]
            )
        }
        image.unlockFocus()
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ExportError.renderFailed("review sheet")
        }
        try png(cgImage).write(to: root.appending(path: "review/\(name).png"))
    }

    /// Review the actual Settings component with its currently bundled images.
    /// Run after copying an export's previews into Resources/Discord.
    static func exportSettingsReview(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let samples = [
            DiscordPresencePresentation.activity(tokenTotal: 0, estimatedFocusMinutes: nil)
        ] + [CompanionTheme.forest, .village, .pokemon].map { theme in
            let artwork = DiscordCompanionArtwork.all.first { $0.theme == theme && $0.stage == 8 }!
            return DiscordPresencePresentation.activity(
                tokenTotal: 720_000_000, estimatedFocusMinutes: 85,
                companion: artwork.presentation, availableArtworkKeys: [artwork.key]
            )
        }
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let view = VStack(alignment: .leading, spacing: 20) {
                ForEach(samples.indices, id: \.self) { index in
                    DiscordActivityPreview(activity: samples[index])
                }
            }
            .padding(20)
            .frame(width: 400, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage else { throw ExportError.renderFailed("Settings preview") }
            try png(image).write(to: directory.appending(path: "settings-\(name).png"), options: .withoutOverwriting)
        }
    }
}
#endif
