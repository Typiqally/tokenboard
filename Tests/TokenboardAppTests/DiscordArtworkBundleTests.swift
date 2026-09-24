import AppKit
import CryptoKit
import XCTest
@testable import TokenboardApp

@MainActor
final class DiscordArtworkBundleTests: XCTestCase {
    func testBundledPreviewsMatchExportManifestAndCoverTheWholeCatalog() throws {
        let root = try XCTUnwrap(DiscordArtworkResources.directory)
        let manifest = try JSONDecoder().decode(
            DiscordArtworkExporter.Manifest.self,
            from: Data(contentsOf: root.appending(path: "catalog.json"))
        )
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.imageSize, 1024)
        XCTAssertEqual(manifest.previewSize, 128)
        XCTAssertEqual(manifest.entries.map(\.key), DiscordCompanionArtwork.all.map(\.key))
        var stageHashes: [String: Set<String>] = [:]
        for (entry, artwork) in zip(manifest.entries, DiscordCompanionArtwork.all) {
            XCTAssertEqual(entry.theme, artwork.theme.rawValue)
            XCTAssertEqual(entry.variant, artwork.variant.id)
            XCTAssertEqual(entry.stage, artwork.stage)
            XCTAssertEqual(entry.tooltip, artwork.tooltip)
            let url = try XCTUnwrap(DiscordArtworkResources.previewURL(for: entry.key))
            let data = try Data(contentsOf: url)
            XCTAssertEqual(DiscordArtworkExporter.hash(data), entry.previewSHA256, entry.key)
            let size = try XCTUnwrap(pngPixelSize(at: url))
            XCTAssertEqual(size.width, 128)
            XCTAssertEqual(size.height, 128)
            XCTAssertNotNil(NSImage(contentsOf: url), entry.key)
            stageHashes[entry.theme + entry.variant, default: []].insert(entry.previewSHA256)
        }
        for (variant, hashes) in stageHashes {
            XCTAssertEqual(hashes.count, 12, "Every stage needs a distinct still: \(variant)")
        }
        let logo = try XCTUnwrap(DiscordArtworkResources.previewURL(for: "tokenboard"))
        XCTAssertEqual(pngPixelSize(at: logo)?.width, 128)
        XCTAssertNotNil(DiscordArtworkResources.preview(for: "tokenboard"))
        XCTAssertNil(DiscordArtworkResources.previewURL(for: "../AppIcon"))
    }

    func testPublishedKeysHavePreviewsAndRecordedRightsStatus() throws {
        let root = try XCTUnwrap(DiscordArtworkResources.directory)
        let availability = try DiscordArtworkAvailability.decode(
            Data(contentsOf: root.appending(path: "published-assets.json"))
        )
        struct Rights: Decodable {
            struct Group: Decodable {
                let id: String
                let redistributionStatus: String
                let evidence: [String]
            }
            let assetGroups: [Group]
        }
        let rights = try JSONDecoder().decode(Rights.self, from: Data(contentsOf:
            developmentCompanionResourceURL("rights-manifest.json")
        ))
        let repository = root.deletingLastPathComponent().deletingLastPathComponent()
        for key in availability.assetKeys {
            let artwork = try XCTUnwrap(DiscordCompanionArtwork.byKey[key])
            let groupID = artwork.theme.rawValue.replacingOccurrences(of: "_", with: "-")
            let group = try XCTUnwrap(rights.assetGroups.first { $0.id == groupID })
            XCTAssertTrue(["cleared", "pending"].contains(group.redistributionStatus), key)
            if group.redistributionStatus == "cleared" {
                XCTAssertFalse(group.evidence.isEmpty, key)
            }
            for evidence in group.evidence {
                XCTAssertTrue(FileManager.default.fileExists(atPath: repository.appending(path: evidence).path))
            }
            XCTAssertNotNil(DiscordArtworkResources.preview(for: key))
        }
    }

    func testSquareCompositionsKeepForegroundSubjectsWithinTheIcon() throws {
        let diagnostics = CompanionDiagnostics()
        for artwork in DiscordCompanionArtwork.all {
            let composition = CompanionSceneComposition.make(
                presentation: artwork.presentation,
                size: CGSize(width: 256, height: 256), layout: .discordIcon,
                diagnostics: diagnostics
            )
            XCTAssertNotNil(composition.asset, artwork.key)
            for placement in composition.placements {
                XCTAssertGreaterThanOrEqual(placement.rect.maxY, 0, artwork.key)
                XCTAssertLessThanOrEqual(placement.rect.maxY, 256, artwork.key)
                // Edge trees and buildings may intentionally bleed; heroes must fit.
                if [.pokemon, .oldSchoolRuneScape, .minecraft].contains(artwork.theme) {
                    XCTAssertGreaterThanOrEqual(placement.rect.minX, 0, artwork.key)
                    XCTAssertLessThanOrEqual(placement.rect.maxX, 256, artwork.key)
                    XCTAssertGreaterThanOrEqual(placement.rect.minY, 0, artwork.key)
                }
            }
        }
        XCTAssertTrue(diagnostics.issues.isEmpty)
    }
}
