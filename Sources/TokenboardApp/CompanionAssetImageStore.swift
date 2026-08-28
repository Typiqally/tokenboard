import AppKit
import Foundation

@MainActor
enum CompanionAssetImageStore {
    /// Sized ~10x the largest working set (the lit village summit plus the
    /// settings shelf), so a session that stays on one theme never evicts,
    /// while a browse through every theme stays bounded.
    static let cache = CompanionBoundedCache<NSImage>(
        countLimit: 128,
        totalCostLimit: 64 * 1024 * 1024
    )

    static func image(resource: String) -> NSImage? {
        if let image = cache.value(forKey: resource) { return image }
        guard let url = resourceURL(resource),
              let image = NSImage(contentsOf: url) else { return nil }
        cache.setValue(image, forKey: resource, cost: cost(of: image))
        return image
    }

    /// Decoded footprint: four bytes per pixel of the largest representation.
    private static func cost(of image: NSImage) -> Int {
        let pixels = image.representations.reduce(0) {
            max($0, $1.pixelsWide * $1.pixelsHigh)
        }
        guard pixels > 0 else {
            return Int(image.size.width * image.size.height) * 4
        }
        return pixels * 4
    }

    /// Width over height of the bundled resource, defaulting to square when
    /// the artwork is unavailable so layout stays stable.
    static func aspectRatio(resource: String) -> Double {
        guard let image = image(resource: resource), image.size.height > 0 else {
            return 1
        }
        return image.size.width / image.size.height
    }

    /// Resolved once: the bundled Companions directory when the app carries
    /// one; in DEBUG builds (which is what `swift test` runs) the repository's
    /// Resources/Companions beside this source file fills in.
    static let baseDirectory: URL? = {
        if let bundled = Bundle.main.resourceURL?.appending(path: "Companions"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        #if DEBUG
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/Companions")
        #else
        return nil
        #endif
    }()

    private static func resourceURL(_ resource: String) -> URL? {
        baseDirectory?.appending(path: resource)
    }
}
