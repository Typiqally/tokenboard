import Foundation

/// Public, finite stills. The installation's seed and scenery never become
/// asset identifiers, and continuously growing worlds share one frame per stage.
struct DiscordCompanionArtwork: Equatable, Sendable {
    let theme: CompanionTheme
    let variant: CompanionVariant
    let stage: Int

    static let all: [Self] = CompanionTheme.allCases.flatMap { theme in
        CompanionCatalog.variants(for: theme).flatMap { variant in
            (0..<CompanionJourney.stageCount).map { stage in
                Self(theme: theme, variant: variant, stage: stage)
            }
        }
    }
    static let byKey = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    private init(theme: CompanionTheme, variant: CompanionVariant, stage: Int) {
        self.theme = theme
        self.variant = variant
        self.stage = stage
    }

    init?(companion: CompanionPresentation) {
        guard CompanionCatalog.variants(for: companion.theme).contains(companion.variant),
              (0..<CompanionJourney.stageCount).contains(companion.stage) else { return nil }
        self.init(theme: companion.theme, variant: companion.variant, stage: companion.stage)
    }

    var key: String {
        let variantKey = variant.id.replacingOccurrences(of: "-", with: "_")
        return "tb_v1_\(theme.rawValue)_\(variantKey)_\(String(format: "%02d", stage + 1))"
    }

    var previewFilename: String { "\(key).png" }

    var tooltip: String {
        "\(theme.title) · \(variant.title) · \(presentation.stageTitle)"
    }

    var presentation: CompanionPresentation {
        // The catalog contains only visible themes and valid stages. Reuse
        // canonical titles instead of maintaining a second journey table.
        let base = CompanionPresentation.make(
            state: CompanionState(theme: theme, showInMenuBar: false, seed: 0),
            dailyTokenTotal: CompanionJourney.thresholds[stage],
            date: Date(timeIntervalSince1970: 0),
            calendar: Calendar(identifier: .gregorian)
        )!
        return CompanionPresentation(
            theme: theme, variant: variant, stage: stage, scenery: 0, seed: 0,
            stageTitle: base.stageTitle,
            progressFraction: stage == CompanionJourney.finalStage ? 1 : 0,
            tokensUntilNextStage: base.tokensUntilNextStage,
            accessibilityLabel: "\(theme.title), \(variant.title), \(base.stageTitle)"
        )
    }
}

/// Checked-in release configuration, not an importer or a runtime upload list.
/// A key is enabled only after that exact asset has been verified in this app.
struct DiscordArtworkAvailability: Sendable {
    let applicationID: String
    let assetKeys: Set<String>

    static let none = Self(applicationID: "", assetKeys: [])

    func keys(for configuration: DiscordApplicationConfiguration?) -> Set<String> {
        guard configuration?.applicationID == applicationID else { return [] }
        return assetKeys.intersection(DiscordCompanionArtwork.byKey.keys)
    }

    static func decode(_ data: Data) throws -> Self {
        struct Manifest: Decodable {
            let schemaVersion: Int
            let applicationID: String
            let assetKeys: [String]
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.schemaVersion == 1,
              DiscordApplicationConfiguration(applicationID: manifest.applicationID) != nil,
              Set(manifest.assetKeys).count == manifest.assetKeys.count,
              manifest.assetKeys.allSatisfy({ DiscordCompanionArtwork.byKey[$0] != nil }) else {
            throw DiscordPresenceClientError.invalidConfiguration
        }
        return Self(applicationID: manifest.applicationID, assetKeys: Set(manifest.assetKeys))
    }
}
