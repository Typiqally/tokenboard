import Combine
import Foundation
import TokenboardCore

struct DiscordPresenceButton: Equatable, Sendable {
    let label: String
    let url: String
}

struct DiscordPresenceActivity: Equatable, Sendable {
    let details: String
    let state: String
    let largeImageKey: String
    let largeImageText: String
    let buttons: [DiscordPresenceButton]
}

enum DiscordPresencePresentation {
    static let consentVersion = 3
    static let disclosure = "Discord may show this activity on your profile, in friend lists, and in server member lists. Tokenboard publishes today's token total, estimated focus time, and a still of your selected companion's daily stage when its Discord artwork is available. The image follows companion changes and resets each local day. Tokenboard publishes only this preview and a static link to its public GitHub repository through the local Discord desktop client."

    static func activity(
        tokenTotal: Int64,
        estimatedFocusMinutes: Int?,
        companion: CompanionPresentation? = nil,
        availableArtworkKeys: Set<String> = []
    ) -> DiscordPresenceActivity {
        let state: String
        if tokenTotal == 0 {
            state = "No usage yet today"
        } else if let estimatedFocusMinutes, estimatedFocusMinutes > 0 {
            state = "\(ValueFormatter.compactTokens(tokenTotal)) tokens · est. focus \(ValueFormatter.duration(minutes: estimatedFocusMinutes))"
        } else {
            state = "\(ValueFormatter.compactTokens(tokenTotal)) tokens today"
        }
        let artwork = companion.flatMap(DiscordCompanionArtwork.init(companion:))
            .flatMap { availableArtworkKeys.contains($0.key) ? $0 : nil }
        return DiscordPresenceActivity(
            details: "Today's AI coding usage",
            state: state,
            largeImageKey: artwork?.key ?? "tokenboard",
            largeImageText: artwork?.tooltip ?? "Tokenboard",
            buttons: [
                DiscordPresenceButton(
                    label: "View on GitHub",
                    url: "https://github.com/Typiqally/tokenboard"
                )
            ]
        )
    }

    static func accessibilityPreview(_ activity: DiscordPresenceActivity) -> String {
        let spokenState = activity.state.replacingOccurrences(of: " · ", with: ", ")
        let action = activity.buttons.first.map { " Action: \($0.label)." } ?? ""
        let artwork = activity.largeImageKey == "tokenboard"
            ? "" : " Image: \(activity.largeImageText)."
        return "Playing Tokenboard. \(activity.details). \(spokenState).\(artwork)\(action)"
    }
}

struct DiscordApplicationConfiguration: Equatable, Sendable {
    let applicationID: String

    init?(applicationID: String) {
        guard (17...20).contains(applicationID.count),
              applicationID.utf8.allSatisfy({ (48...57).contains($0) }),
              applicationID != String(repeating: "0", count: applicationID.count) else {
            return nil
        }
        self.applicationID = applicationID
    }

    static func load(from bundle: Bundle = .main) -> DiscordApplicationConfiguration? {
        guard let value = bundle.object(
            forInfoDictionaryKey: "TokenboardDiscordApplicationID"
        ) as? String else { return nil }
        return DiscordApplicationConfiguration(applicationID: value)
    }
}

enum DiscordPresenceStatus: Equatable, Sendable {
    case disabled
    case connecting
    case connected
    case discordNotRunning
    case failed
    case unavailable

    var title: String {
        switch self {
        case .disabled: "Off"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .discordNotRunning: "Discord isn't running"
        case .failed: "Couldn't connect"
        case .unavailable: "Unavailable in this build"
        }
    }
}

enum DiscordPresenceClientError: Error, Equatable, Sendable {
    case discordNotRunning
    case connectionFailed
    case invalidConfiguration
    case malformedResponse
    case payloadTooLarge
}

protocol DiscordPresenceClient: Sendable {
    func connect(applicationID: String) async throws
    func setActivity(_ activity: DiscordPresenceActivity?) async throws
    func disconnect() async
}

@MainActor
final class DiscordPresenceCoordinator: ObservableObject {
    @Published private(set) var status: DiscordPresenceStatus = .disabled
    @Published private(set) var isEnabled = false
    @Published private(set) var currentActivity: DiscordPresenceActivity?

    var isConfigured: Bool { configuration != nil }
    let availableArtworkKeys: Set<String>

    private let configuration: DiscordApplicationConfiguration?
    private let client: any DiscordPresenceClient
    private var publishedActivity: DiscordPresenceActivity?

    init(
        configuration: DiscordApplicationConfiguration?,
        client: any DiscordPresenceClient,
        artworkAvailability: DiscordArtworkAvailability? = nil
    ) {
        self.configuration = configuration
        self.client = client
        availableArtworkKeys = (artworkAvailability ?? DiscordArtworkResources.availability)
            .keys(for: configuration)
        status = configuration == nil ? .unavailable : .disabled
    }

    // One worker owns all client calls. Main-actor reentrancy may change the
    // desired activity while connect/send suspends; the worker drains the
    // newest value before finishing and never lets an old task reconnect later.
    private var worker: Task<Void, Never>?
    private var connected = false
    private var shouldConnect = false
    private var disconnectRequested = false
    private var clearRequested = false
    private var disconnectedStatus: DiscordPresenceStatus = .disabled
    private var intentRevision: UInt64 = 0

    func setEnabled(_ enabled: Bool, activity: DiscordPresenceActivity) async {
        currentActivity = activity
        intentRevision &+= 1
        isEnabled = enabled && configuration != nil
        shouldConnect = isEnabled
        if !isEnabled {
            disconnectRequested = true
            clearRequested = true
            disconnectedStatus = enabled ? .unavailable : .disabled
        }
        await synchronize()
    }

    func update(_ activity: DiscordPresenceActivity) async {
        currentActivity = activity
        guard isEnabled, worker == nil, connected else { return }
        await synchronize()
    }

    func retry() async {
        guard isEnabled else { return }
        intentRevision &+= 1
        disconnectRequested = true
        shouldConnect = true
        await synchronize()
    }

    func discordBecameUnavailable() async {
        guard isEnabled else { return }
        intentRevision &+= 1
        disconnectRequested = true
        shouldConnect = false
        disconnectedStatus = .discordNotRunning
        await synchronize()
    }

    func shutdown() async {
        intentRevision &+= 1
        isEnabled = false
        shouldConnect = false
        disconnectRequested = true
        clearRequested = true
        disconnectedStatus = .disabled
        await synchronize()
    }

    private func synchronize() async {
        if let worker {
            await worker.value
            return
        }
        let task = Task { @MainActor [weak self] in
            await self?.drain()
            self?.worker = nil
        }
        worker = task
        await task.value
    }

    private func drain() async {
        while true {
            if disconnectRequested {
                disconnectRequested = false
                let shouldClear = clearRequested
                clearRequested = false
                if connected && shouldClear {
                    try? await client.setActivity(nil)
                }
                await client.disconnect()
                connected = false
                publishedActivity = nil
                status = disconnectedStatus
                continue
            }
            guard isEnabled, shouldConnect, let configuration else { return }
            let revision = intentRevision
            do {
                if !connected {
                    status = .connecting
                    try await client.connect(applicationID: configuration.applicationID)
                    connected = true
                    // Disable, shutdown, or Retry may have arrived while opening.
                    if disconnectRequested || !isEnabled { continue }
                    status = .connected
                }
                guard let activity = currentActivity, publishedActivity != activity else { return }
                try await client.setActivity(activity)
                publishedActivity = activity
                // Loop: an update received during the send replaces this value.
            } catch {
                await client.disconnect()
                connected = false
                publishedActivity = nil
                if intentRevision == revision {
                    shouldConnect = false
                    status = Self.status(for: error)
                }
            }
        }
    }

    private static func status(for error: Error) -> DiscordPresenceStatus {
        guard let error = error as? DiscordPresenceClientError else { return .failed }
        return error == .discordNotRunning ? .discordNotRunning : .failed
    }
}

enum DiscordIPCOpcode: UInt32, Equatable, Sendable {
    case handshake = 0
    case frame = 1
    case close = 2
    case ping = 3
    case pong = 4
}

struct DiscordIPCFrame: Equatable, Sendable {
    let opcode: DiscordIPCOpcode
    let payload: Data
}

enum DiscordIPCFrameCodec {
    static let maximumPayloadSize = 65_536

    static func encode(
        opcode: DiscordIPCOpcode,
        payload: Data
    ) throws -> Data {
        guard payload.count <= maximumPayloadSize else {
            throw DiscordPresenceClientError.payloadTooLarge
        }
        var result = Data(capacity: 8 + payload.count)
        appendLittleEndian(opcode.rawValue, to: &result)
        appendLittleEndian(UInt32(payload.count), to: &result)
        result.append(payload)
        return result
    }

    static func decodeAvailableFrames(
        from buffer: inout Data
    ) throws -> [DiscordIPCFrame] {
        var frames: [DiscordIPCFrame] = []
        while buffer.count >= 8 {
            let start = buffer.startIndex
            let opcodeValue = littleEndianUInt32(buffer, offset: 0)
            let payloadSize = Int(littleEndianUInt32(buffer, offset: 4))
            guard payloadSize <= maximumPayloadSize else {
                throw DiscordPresenceClientError.payloadTooLarge
            }
            guard let opcode = DiscordIPCOpcode(rawValue: opcodeValue) else {
                throw DiscordPresenceClientError.malformedResponse
            }
            guard buffer.count >= 8 + payloadSize else { break }
            let payloadStart = buffer.index(start, offsetBy: 8)
            let payloadEnd = buffer.index(payloadStart, offsetBy: payloadSize)
            let payload = Data(buffer[payloadStart..<payloadEnd])
            frames.append(DiscordIPCFrame(opcode: opcode, payload: payload))
            buffer.removeFirst(8 + payloadSize)
        }
        return frames
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        let littleEndian = value.littleEndian
        withUnsafeBytes(of: littleEndian) { data.append(contentsOf: $0) }
    }

    private static func littleEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        let index = data.index(data.startIndex, offsetBy: offset)
        return UInt32(data[index])
            | (UInt32(data[data.index(index, offsetBy: 1)]) << 8)
            | (UInt32(data[data.index(index, offsetBy: 2)]) << 16)
            | (UInt32(data[data.index(index, offsetBy: 3)]) << 24)
    }
}

enum DiscordIPCEndpointDiscovery {
    static func candidates(environment: [String: String]) -> [String] {
        let names = ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"]
        var roots = names.compactMap { environment[$0] }
        roots.append("/tmp")
        var seen: Set<String> = []
        return roots.flatMap { root -> [String] in
            guard root.hasPrefix("/"), !root.contains("\0") else { return [] }
            let standardized = (root as NSString).standardizingPath
            guard seen.insert(standardized).inserted else { return [] }
            return (0..<10).map { "\(standardized)/discord-ipc-\($0)" }
        }
    }
}

enum DiscordRPCMessage {
    static func handshake(applicationID: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["v": 1, "client_id": applicationID],
            options: [.sortedKeys]
        )
    }

    static func activity(
        _ activity: DiscordPresenceActivity?,
        processID: Int32,
        nonce: String
    ) throws -> Data {
        let activityValue: Any
        if let activity {
            activityValue = [
                "type": 0,
                "details": activity.details,
                "state": activity.state,
                "assets": [
                    "large_image": activity.largeImageKey,
                    "large_text": activity.largeImageText,
                ],
                "buttons": activity.buttons.map { button in
                    ["label": button.label, "url": button.url]
                },
            ] as [String: Any]
        } else {
            activityValue = NSNull()
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "cmd": "SET_ACTIVITY",
                "args": ["pid": Int(processID), "activity": activityValue],
                "nonce": nonce,
            ] as [String: Any],
            options: [.sortedKeys]
        )
    }
}
