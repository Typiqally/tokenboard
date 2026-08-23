import Foundation
import ImageIO
import XCTest
@testable import TokenboardCore

final class AppBundleConfigurationTests: XCTestCase {
    func testCompanionArtworkIsBundledSourceMaterial() throws {
        let root = TestRepository.root
        let companions = root.appending(path: "Resources/Companions")
        let representativeAssets = [
            "Pokemon/Backgrounds/01-pallet-town.png",
            "Tree/growing-tree.png",
            "Tower/08-skyscraper.jpg",
            "OldSchoolRuneScape/Characters/08-masori.png",
            "OldSchoolRuneScape/Backgrounds/08-tombs-of-amascut.png",
            "AgeOfEmpiresII/07-imperial-age.webp"
        ]
        for resource in representativeAssets {
            let url = companions.appending(path: resource)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = try XCTUnwrap(attributes[.size] as? NSNumber).intValue
            XCTAssertGreaterThan(size, 1_000, resource)
        }
        let pokemonDirectory = root.appending(path: "Resources/Companions/Pokemon")
        let pokemonSprites = try FileManager.default.contentsOfDirectory(
            at: pokemonDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "png" }
        XCTAssertEqual(pokemonSprites.count, 36)
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
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "0.6.2")
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "10")
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
