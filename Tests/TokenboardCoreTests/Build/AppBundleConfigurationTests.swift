import Foundation
import ImageIO
import XCTest
@testable import TokenboardCore

final class AppBundleConfigurationTests: XCTestCase {
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
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "0.5.0")
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "7")
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
