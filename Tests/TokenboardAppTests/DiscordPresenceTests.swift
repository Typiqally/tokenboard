import Darwin
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
            "Playing Tokenboard. Today's AI coding usage. 12.3M tokens, activity in 4 hours. Action: View on GitHub."
        )
        XCTAssertTrue(DiscordPresencePresentation.disclosure.contains("public GitHub repository"))
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
        let buttons = try XCTUnwrap(payload["buttons"] as? [[String: Any]])

        XCTAssertEqual(Set(root.keys), ["cmd", "args", "nonce"])
        XCTAssertEqual(root["cmd"] as? String, "SET_ACTIVITY")
        XCTAssertEqual(args["pid"] as? Int, 321)
        XCTAssertEqual(Set(payload.keys), ["type", "details", "state", "assets", "buttons"])
        XCTAssertEqual(payload["type"] as? Int, 0)
        XCTAssertEqual(Set(assets.keys), ["large_image", "large_text"])
        XCTAssertEqual(buttons.count, 1)
        XCTAssertEqual(Set(buttons[0].keys), ["label", "url"])
        XCTAssertEqual(buttons[0]["label"] as? String, "View on GitHub")
        XCTAssertEqual(buttons[0]["url"] as? String, "https://github.com/Typiqally/tokenboard")
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

    func testNativeClientPerformsHandshakeActivityAndPingPongOverLocalIPC() async throws {
        let server = try DiscordIPCTestServer()
        defer { server.close() }
        let client = DiscordIPCClient(environment: ["TMPDIR": server.directory])
        let applicationID = "123456789012345678"
        let activity = DiscordPresencePresentation.activity(
            tokenTotal: 12_345_678,
            activeHourCount: 4
        )

        async let capturedExchange = server.captureExchange()
        try await client.connect(applicationID: applicationID)
        try await client.setActivity(activity)
        let exchange = try await capturedExchange
        await client.disconnect()

        let handshake = try XCTUnwrap(
            JSONSerialization.jsonObject(with: exchange.handshake) as? [String: Any]
        )
        XCTAssertEqual(handshake["v"] as? Int, 1)
        XCTAssertEqual(handshake["client_id"] as? String, applicationID)

        let command = try XCTUnwrap(
            JSONSerialization.jsonObject(with: exchange.activity) as? [String: Any]
        )
        XCTAssertEqual(command["cmd"] as? String, "SET_ACTIVITY")
        let arguments = try XCTUnwrap(command["args"] as? [String: Any])
        let published = try XCTUnwrap(arguments["activity"] as? [String: Any])
        XCTAssertEqual(published["details"] as? String, activity.details)
        XCTAssertEqual(published["state"] as? String, activity.state)
        XCTAssertEqual(exchange.pong, exchange.ping)
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

    func testUnconfiguredCoordinatorIsVisiblyUnavailable() {
        let coordinator = DiscordPresenceCoordinator(
            configuration: nil,
            client: RecordingDiscordPresenceClient()
        )

        XCTAssertFalse(coordinator.isConfigured)
        XCTAssertEqual(coordinator.status, .unavailable)
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

private struct DiscordIPCExchange: Sendable {
    let handshake: Data
    let activity: Data
    let ping: Data
    let pong: Data
}

private final class DiscordIPCTestServer: @unchecked Sendable {
    let directory: String

    private let listener: Int32
    private let socketPath: String

    init() throws {
        directory = "/tmp/tokenboard-discord-\(UUID().uuidString.prefix(8))"
        socketPath = "\(directory)/discord-ipc-0"
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: false
        )

        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw DiscordIPCTestError.socketFailure }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = socketPath.utf8CString.map { UInt8(bitPattern: $0) }
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(listener)
            throw DiscordIPCTestError.socketFailure
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let didBind = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    listener,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                ) == 0
            }
        }
        guard didBind, Darwin.listen(listener, 1) == 0 else {
            Darwin.close(listener)
            throw DiscordIPCTestError.socketFailure
        }
    }

    func captureExchange() async throws -> DiscordIPCExchange {
        try await Task.detached(priority: .utility) { [listener] in
            var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&ready, 1, 5_000) > 0 else {
                throw DiscordIPCTestError.timeout
            }
            let connection = Darwin.accept(listener, nil, nil)
            guard connection >= 0 else { throw DiscordIPCTestError.socketFailure }
            defer { Darwin.close(connection) }

            let handshake = try Self.readFrame(from: connection)
            guard handshake.opcode == .handshake else {
                throw DiscordIPCTestError.unexpectedFrame
            }
            let readyPayload = Data(
                #"{"cmd":"DISPATCH","evt":"READY","data":{}}"#.utf8
            )
            try Self.write(
                DiscordIPCFrameCodec.encode(opcode: .frame, payload: readyPayload),
                to: connection
            )

            let activity = try Self.readFrame(from: connection)
            guard activity.opcode == .frame else {
                throw DiscordIPCTestError.unexpectedFrame
            }
            let ping = Data(#"{"probe":true}"#.utf8)
            try Self.write(
                DiscordIPCFrameCodec.encode(opcode: .ping, payload: ping),
                to: connection
            )
            let pong = try Self.readFrame(from: connection)
            guard pong.opcode == .pong else {
                throw DiscordIPCTestError.unexpectedFrame
            }
            return DiscordIPCExchange(
                handshake: handshake.payload,
                activity: activity.payload,
                ping: ping,
                pong: pong.payload
            )
        }.value
    }

    func close() {
        _ = Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        try? FileManager.default.removeItem(atPath: directory)
    }

    private static func readFrame(from descriptor: Int32) throws -> DiscordIPCFrame {
        var buffer = try read(count: 8, from: descriptor)
        let payloadSize = Int(UInt32(buffer[4])
            | (UInt32(buffer[5]) << 8)
            | (UInt32(buffer[6]) << 16)
            | (UInt32(buffer[7]) << 24))
        guard payloadSize <= DiscordIPCFrameCodec.maximumPayloadSize else {
            throw DiscordIPCTestError.unexpectedFrame
        }
        buffer.append(try read(count: payloadSize, from: descriptor))
        let frames = try DiscordIPCFrameCodec.decodeAvailableFrames(from: &buffer)
        guard frames.count == 1, buffer.isEmpty, let frame = frames.first else {
            throw DiscordIPCTestError.unexpectedFrame
        }
        return frame
    }

    private static func read(count: Int, from descriptor: Int32) throws -> Data {
        guard count > 0 else { return Data() }
        var result = Data(count: count)
        var offset = 0
        try result.withUnsafeMutableBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            while offset < count {
                var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                guard Darwin.poll(&ready, 1, 5_000) > 0 else {
                    throw DiscordIPCTestError.timeout
                }
                let received = Darwin.recv(
                    descriptor,
                    address.advanced(by: offset),
                    count - offset,
                    0
                )
                guard received > 0 else { throw DiscordIPCTestError.socketFailure }
                offset += received
            }
        }
        return result
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard var address = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let sent = Darwin.send(descriptor, address, remaining, 0)
                guard sent > 0 else { throw DiscordIPCTestError.socketFailure }
                remaining -= sent
                address = address.advanced(by: sent)
            }
        }
    }
}

private enum DiscordIPCTestError: Error {
    case socketFailure
    case timeout
    case unexpectedFrame
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
