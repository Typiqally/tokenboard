import AppKit

@MainActor
enum DiscordArtworkResources {
    static let directory: URL? = {
        if let bundled = Bundle.main.resourceURL?.appending(path: "Discord"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        #if DEBUG
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/Discord")
        #else
        return nil
        #endif
    }()

    static let availability: DiscordArtworkAvailability = {
        guard let url = directory?.appending(path: "published-assets.json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? DiscordArtworkAvailability.decode(data) else { return .none }
        // A release with incomplete preview resources must display the same
        // fallback locally and remotely, never promise artwork it cannot show.
        return DiscordArtworkAvailability(
            applicationID: manifest.applicationID,
            assetKeys: manifest.assetKeys.filter { key in
                guard let url = previewURL(for: key) else { return false }
                return FileManager.default.fileExists(atPath: url.path)
            }
        )
    }()

    private static let cache = CompanionBoundedCache<NSImage>(
        countLimit: 8, totalCostLimit: 512 * 1024
    )

    static func previewURL(for key: String) -> URL? {
        guard key == "tokenboard" || DiscordCompanionArtwork.byKey[key] != nil else { return nil }
        return directory?.appending(path: "previews/\(key).png")
    }

    static func preview(for key: String) -> NSImage? {
        if let image = cache.value(forKey: key) { return image }
        guard let url = previewURL(for: key), let image = NSImage(contentsOf: url) else { return nil }
        cache.setValue(image, forKey: key, cost: 128 * 128 * 4)
        return image
    }
}
