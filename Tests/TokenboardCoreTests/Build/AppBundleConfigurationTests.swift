import Foundation
import ImageIO
import XCTest
@testable import TokenboardCore

final class AppBundleConfigurationTests: XCTestCase {
    func testCompanionArtworkIsBundledSourceMaterial() throws {
        let root = TestRepository.root
        let companions = root.appending(path: "Resources/Companions")
        let representativeAssets = [
            "Pokemon/scenes/01-pallet-town-a.jpg",
            "Pokemon/scenes/12-indigo-plateau-c.jpg",
            "Pokemon/art/001.png",
            "Forest/scenes/01-a.png",
            "Forest/scenes/12-c.png",
            "Forest/sprites/oak-3.png",
            "Forest/silhouettes/12.png",
            "Village/scenes/12-b.png",
            "Village/sprites/modern-3-lit.png",
            "Village/silhouettes/12.png",
            "OldSchoolRuneScape/Characters/12-masori.png",
            "OldSchoolRuneScape/Backgrounds/12-tombs-of-amascut-b.jpg",
            "AgeOfEmpiresII/scenes/12-imperial-capital-c.jpg",
            "Minecraft/scenes/01-plains-a.jpg",
            "Minecraft/scenes/12-end-city-c.jpg",
            "Minecraft/characters/netherite.png"
        ]
        for resource in representativeAssets {
            let url = companions.appending(path: resource)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = try XCTUnwrap(attributes[.size] as? NSNumber).intValue
            XCTAssertGreaterThan(size, 1_000, resource)
        }
        let pokemonDirectory = root.appending(path: "Resources/Companions/Pokemon")
        let pokemonArtworks = try FileManager.default.contentsOfDirectory(
            at: pokemonDirectory.appending(path: "art"),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "png" }
        XCTAssertEqual(pokemonArtworks.count, 36)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: pokemonDirectory.appending(path: "POKEAPI-LICENCE.txt").path
        ))
        let buildScript = try String(
            contentsOf: root.appending(path: "Scripts/build-app.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(buildScript.contains("Resources/Companions"))
    }
    func testBuildInfoPinsBundleAndDeploymentTarget() {
        XCTAssertEqual(BuildInfo.bundleIdentifier, "com.tokenboard.Tokenboard")
        XCTAssertEqual(BuildInfo.minimumMacOS, "14.0")
    }

    func testBuildInfoFormatsTheReleaseAndBuildForSettings() {
        XCTAssertEqual(
            BuildInfo.versionDescription(shortVersion: "0.3.0", buildNumber: "3"),
            "0.3.0 (3)"
        )
        XCTAssertEqual(
            BuildInfo.versionDescription(shortVersion: "0.3.0", buildNumber: nil),
            "0.3.0"
        )
        XCTAssertEqual(
            BuildInfo.versionDescription(shortVersion: nil, buildNumber: "3"),
            "Build 3"
        )
        XCTAssertEqual(
            BuildInfo.versionDescription(shortVersion: nil, buildNumber: nil),
            "Unknown"
        )
    }

    func testEntitlementsAreSandboxedReadOnlyAndOffline() throws {
        let url = TestRepository.root.appending(path: "Resources/Tokenboard.entitlements")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(plist["com.apple.security.files.user-selected.read-only"] as? Bool, true)
        XCTAssertEqual(plist["com.apple.security.files.bookmarks.app-scope"] as? Bool, true)
        XCTAssertNil(plist["com.apple.security.network.client"])
        XCTAssertNil(plist["com.apple.security.network.server"])
    }

    func testInfoPlistDefinesAnAgentOnlyApplication() throws {
        let url = TestRepository.root.appending(path: "Resources/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "14.0")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, BuildInfo.bundleIdentifier)
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "Tokenboard.icns")
        let shortVersion = try XCTUnwrap(plist["CFBundleShortVersionString"] as? String)
        XCTAssertNotNil(
            shortVersion.range(
                of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#,
                options: .regularExpression
            )
        )
        let buildNumber = try XCTUnwrap(plist["CFBundleVersion"] as? String)
        XCTAssertGreaterThan(Int(buildNumber) ?? 0, 0)
    }

    func testAppIconMasterIsAFullResolutionSquarePNG() throws {
        let url = TestRepository.root.appending(path: "Resources/AppIcon.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )

        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1_024)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 1_024)
    }
}
