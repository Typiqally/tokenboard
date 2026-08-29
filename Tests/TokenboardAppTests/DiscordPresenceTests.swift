import Foundation
import XCTest
@testable import TokenboardApp
import TokenboardCore

@MainActor
final class DiscordPresenceTests: XCTestCase {
    func testDailySummaryUsesOnlyCompactTokensAndActiveHourBuckets() throws {
        let activity = DiscordPresencePresentation.activity(
            tokenTotal: 12_345_678,
            activeHourCount: 4
        )

        XCTAssertEqual(activity.details, "Today's AI coding usage")
        XCTAssertEqual(activity.state, "12.3M tokens · activity in 4 hours")
        XCTAssertEqual(activity.largeImageKey, "tokenboard")
        XCTAssertEqual(activity.largeImageText, "Tokenboard")
        XCTAssertEqual(
            DiscordPresencePresentation.accessibilityPreview(activity),
            "Playing Tokenboard. Today's AI coding usage. 12.3M tokens, activity in 4 hours."
        )
    }

    func testDailySummaryHandlesSingularMissingPatternsAndZeroUsage() {
        XCTAssertEqual(
            DiscordPresencePresentation.activity(
                tokenTotal: 42,
                activeHourCount: 1
            ).state,
            "42 tokens · activity in 1 hour"
        )
        XCTAssertEqual(
            DiscordPresencePresentation.activity(
                tokenTotal: 42,
                activeHourCount: nil
            ).state,
            "42 tokens today"
        )
        XCTAssertEqual(
            DiscordPresencePresentation.activity(
                tokenTotal: 0,
                activeHourCount: 0
            ).state,
            "No usage yet today"
        )
    }

    func testActivityPayloadIsStrictlyAllowlistedAndClearUsesNull() throws {
        let activity = DiscordPresencePresentation.activity(
            tokenTotal: 12_345_678,
            activeHourCount: 4
        )
        let encoded = try DiscordRPCMessage.activity(
            activity,
            processID: 321,
            nonce: "synthetic-nonce"
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let args = try XCTUnwrap(root["args"] as? [String: Any])
        let payload = try XCTUnwrap(args["activity"] as? [String: Any])
        let assets = try XCTUnwrap(payload["assets"] as? [String: Any])

        XCTAssertEqual(Set(root.keys), ["cmd", "args", "nonce"])
        XCTAssertEqual(root["cmd"] as? String, "SET_ACTIVITY")
        XCTAssertEqual(args["pid"] as? Int, 321)
        XCTAssertEqual(Set(payload.keys), ["type", "details", "state", "assets"])
        XCTAssertEqual(payload["type"] as? Int, 0)
        XCTAssertEqual(Set(assets.keys), ["large_image", "large_text"])
        XCTAssertFalse(encoded.containsSensitiveDiscordPresenceKey)

        let cleared = try DiscordRPCMessage.activity(
            nil,
            processID: 321,
            nonce: "clear-nonce"
        )
        let clearRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: cleared) as? [String: Any]
        )
        let clearArgs = try XCTUnwrap(clearRoot["args"] as? [String: Any])
        XCTAssertTrue(clearArgs["activity"] is NSNull)
    }

    func testApplicationConfigurationAcceptsOnlyPublicNumericSnowflakes() {
        XCTAssertEqual(
            DiscordApplicationConfiguration(applicationID: "123456789012345678")?.applicationID,
            "123456789012345678"
        )
        XCTAssertNil(DiscordApplicationConfiguration(applicationID: ""))
        XCTAssertNil(DiscordApplicationConfiguration(applicationID: "123"))
        XCTAssertNil(DiscordApplicationConfiguration(applicationID: "not-a-client-id"))
        XCTAssertNil(DiscordApplicationConfiguration(applicationID: "١٢٣٤٥٦٧٨٩٠١٢٣٤٥٦٧٨"))
        XCTAssertNil(DiscordApplicationConfiguration(
            applicationID: "__TOKENBOARD_DISCORD_APPLICATION_ID__"
        ))
    }

    func testIPCFrameCodecUsesLittleEndianHeadersAndSupportsFragmentedFrames() throws {
        let payload = Data(#"{"v":1}"#.utf8)
        let encoded = try DiscordIPCFrameCodec.encode(opcode: .handshake, payload: payload)

        XCTAssertEqual(Array(encoded.prefix(4)), [0, 0, 0, 0])
        XCTAssertEqual(Array(encoded.dropFirst(4).prefix(4)), [7, 0, 0, 0])

        var buffer = Data(encoded.prefix(6))
        XCTAssertEqual(try DiscordIPCFrameCodec.decodeAvailableFrames(from: &buffer), [])
        buffer.append(encoded.dropFirst(6))
        XCTAssertEqual(
            try DiscordIPCFrameCodec.decodeAvailableFrames(from: &buffer),
            [DiscordIPCFrame(opcode: .handshake, payload: payload)]
        )
        XCTAssertTrue(buffer.isEmpty)
    }

    func testIPCFrameCodecDecodesMultipleFramesAndRejectsOversizedPayloads() throws {
        let first = try DiscordIPCFrameCodec.encode(opcode: .ping, payload: Data([1, 2]))
        let second = try DiscordIPCFrameCodec.encode(opcode: .pong, payload: Data([3]))
        var combined = first + second

        XCTAssertEqual(
            try DiscordIPCFrameCodec.decodeAvailableFrames(from: &combined),
            [
                DiscordIPCFrame(opcode: .ping, payload: Data([1, 2])),
                DiscordIPCFrame(opcode: .pong, payload: Data([3])),
            ]
        )
        XCTAssertThrowsError(try DiscordIPCFrameCodec.encode(
            opcode: .frame,
            payload: Data(repeating: 0, count: DiscordIPCFrameCodec.maximumPayloadSize + 1)
        ))
    }

    func testEndpointDiscoveryFollowsDiscordOrderDeduplicatesAndBoundsIndices() {
        let candidates = DiscordIPCEndpointDiscovery.candidates(environment: [
            "XDG_RUNTIME_DIR": "/runtime",
            "TMPDIR": "/temporary",
            "TMP": "/temporary",
            "TEMP": "relative-path",
        ])

        XCTAssertEqual(candidates.count, 30)
        XCTAssertEqual(candidates.first, "/runtime/discord-ipc-0")
        XCTAssertEqual(candidates[9], "/runtime/discord-ipc-9")
        XCTAssertEqual(candidates[10], "/temporary/discord-ipc-0")
        XCTAssertEqual(candidates.last, "/tmp/discord-ipc-9")
        XCTAssertFalse(candidates.contains { $0.contains("relative-path") })
    }

    func testCoordinatorConnectsUpdatesWithoutDuplicatesAndClearsOnDisable() async {
        let client = RecordingDiscordPresenceClient()
        let coordinator = DiscordPresenceCoordinator(
            configuration: DiscordApplicationConfiguration(
                applicationID: "123456789012345678"
            )!,
            client: client
        )
        let initial = DiscordPresencePresentation.activity(
            tokenTotal: 42,
            activeHourCount: 1
        )
        let updated = DiscordPresencePresentation.activity(
            tokenTotal: 84,
            activeHourCount: 2
        )

        await coordinator.setEnabled(true, activity: initial)
        await coordinator.update(initial)
        await coordinator.update(updated)

        XCTAssertEqual(coordinator.status, .connected)
        let applicationIDs = await client.applicationIDs()
        let activities = await client.activities()
        XCTAssertEqual(applicationIDs, ["123456789012345678"])
        XCTAssertEqual(activities, [initial, updated])

        await coordinator.setEnabled(false, activity: updated)

        XCTAssertEqual(coordinator.status, .disabled)
        let clearCount = await client.clearCount()
        let disconnectCount = await client.disconnectCount()
        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(disconnectCount, 1)
    }

    func testCoordinatorDistinguishesDiscordNotRunningAndRetries() async {
        let client = RecordingDiscordPresenceClient(connectFailures: [.discordNotRunning])
        let coordinator = DiscordPresenceCoordinator(
            configuration: DiscordApplicationConfiguration(
                applicationID: "123456789012345678"
            )!,
            client: client
        )
        let activity = DiscordPresencePresentation.activity(
            tokenTotal: 42,
            activeHourCount: nil
        )

        await coordinator.setEnabled(true, activity: activity)
        XCTAssertEqual(coordinator.status, .discordNotRunning)

        await coordinator.retry()
        XCTAssertEqual(coordinator.status, .connected)
        let activities = await client.activities()
        XCTAssertEqual(activities, [activity])
    }

    func testCoordinatorClearsOnShutdownWithoutBlockingFailure() async {
        let client = RecordingDiscordPresenceClient(clearError: .connectionFailed)
        let coordinator = DiscordPresenceCoordinator(
            configuration: DiscordApplicationConfiguration(
                applicationID: "123456789012345678"
            )!,
            client: client
        )
        await coordinator.setEnabled(
            true,
            activity: DiscordPresencePresentation.activity(
                tokenTotal: 42,
                activeHourCount: nil
            )
        )

        await coordinator.shutdown()

        let clearCount = await client.clearCount()
        let disconnectCount = await client.disconnectCount()
        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(disconnectCount, 1)
    }
}

private extension Data {
    var containsSensitiveDiscordPresenceKey: Bool {
        let text = String(decoding: self, as: UTF8.self)
        return [
            "provider", "model", "project", "path", "conversation", "cost",
            "timestamp", "button", "party", "secret", "url",
        ].contains { text.localizedCaseInsensitiveContains($0) }
    }
}

private actor RecordingDiscordPresenceClient: DiscordPresenceClient {
    private var recordedApplicationIDs: [String] = []
    private var recordedActivities: [DiscordPresenceActivity] = []
    private var recordedClearCount = 0
    private var recordedDisconnectCount = 0
    private var connectFailures: [DiscordPresenceClientError]
    private let clearError: DiscordPresenceClientError?

    init(
        connectFailures: [DiscordPresenceClientError] = [],
        clearError: DiscordPresenceClientError? = nil
    ) {
        self.connectFailures = connectFailures
        self.clearError = clearError
    }

    func connect(applicationID: String) throws {
        if !connectFailures.isEmpty {
            throw connectFailures.removeFirst()
        }
        recordedApplicationIDs.append(applicationID)
    }

    func setActivity(_ activity: DiscordPresenceActivity?) throws {
        guard let activity else {
            recordedClearCount += 1
            if let clearError { throw clearError }
            return
        }
        recordedActivities.append(activity)
    }

    func disconnect() {
        recordedDisconnectCount += 1
    }

    func applicationIDs() -> [String] { recordedApplicationIDs }
    func activities() -> [DiscordPresenceActivity] { recordedActivities }
    func clearCount() -> Int { recordedClearCount }
    func disconnectCount() -> Int { recordedDisconnectCount }
}
