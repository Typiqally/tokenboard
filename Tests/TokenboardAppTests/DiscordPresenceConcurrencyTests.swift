import XCTest
@testable import TokenboardApp

@MainActor
final class DiscordPresenceConcurrencyTests: XCTestCase {
    func testThemeChangeDuringConnectPublishesOnlyLatestArtwork() async throws {
        let client = SuspendedPresenceClient(suspendConnect: true)
        let coordinator = makeCoordinator(client)
        let initial = activity(.forest)
        let latest = activity(.pokemon)
        let connecting = Task { await coordinator.setEnabled(true, activity: initial) }
        await client.waitUntilSuspended()
        await coordinator.update(latest)
        await client.resume()
        await connecting.value
        let published = await client.activities
        XCTAssertEqual(published, [latest])
        XCTAssertEqual(coordinator.status, .connected)
    }

    func testUpdatesDuringSendAreCoalescedAndNewestArtworkWins() async {
        let client = SuspendedPresenceClient(suspendConnect: false)
        let coordinator = makeCoordinator(client)
        let initial = activity(.forest)
        let latest = activity(.minecraft)
        let connecting = Task { await coordinator.setEnabled(true, activity: initial) }
        await client.waitUntilSuspended()
        await coordinator.update(activity(.village))
        await coordinator.update(latest)
        await client.resume()
        await connecting.value
        await coordinator.update(latest)
        let published = await client.activities
        XCTAssertEqual(published, [initial, latest])
    }

    func testDisableDuringConnectCannotPublishOrResurrectPresence() async {
        let client = SuspendedPresenceClient(suspendConnect: true)
        let coordinator = makeCoordinator(client)
        let initial = activity(.forest)
        let connecting = Task { await coordinator.setEnabled(true, activity: initial) }
        await client.waitUntilSuspended()
        let disabling = Task { await coordinator.setEnabled(false, activity: initial) }
        // The main actor executes the disabling task through its first await.
        while coordinator.isEnabled { await Task.yield() }
        await client.resume()
        await connecting.value
        await disabling.value
        let published = await client.activities
        let disconnects = await client.disconnects
        XCTAssertEqual(published, [])
        XCTAssertGreaterThan(disconnects, 0)
        XCTAssertEqual(coordinator.status, .disabled)
        XCTAssertFalse(coordinator.isEnabled)
    }

    private func makeCoordinator(_ client: SuspendedPresenceClient) -> DiscordPresenceCoordinator {
        DiscordPresenceCoordinator(
            configuration: DiscordApplicationConfiguration(applicationID: "123456789012345678"),
            client: client
        )
    }

    private func activity(_ theme: CompanionTheme) -> DiscordPresenceActivity {
        let artwork = DiscordCompanionArtwork.all.first { $0.theme == theme }!
        return DiscordPresencePresentation.activity(
            tokenTotal: 0, estimatedFocusMinutes: nil,
            companion: artwork.presentation, availableArtworkKeys: [artwork.key]
        )
    }
}

private actor SuspendedPresenceClient: DiscordPresenceClient {
    let suspendConnect: Bool
    var activities: [DiscordPresenceActivity] = []
    var disconnects = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var didSuspend = false

    init(suspendConnect: Bool) { self.suspendConnect = suspendConnect }

    func connect(applicationID: String) async {
        if suspendConnect { await suspendOnce() }
    }

    func setActivity(_ activity: DiscordPresenceActivity?) async {
        if !suspendConnect { await suspendOnce() }
        if let activity { activities.append(activity) }
    }

    func disconnect() { disconnects += 1 }

    func waitUntilSuspended() async {
        if didSuspend { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func resume() {
        gate?.resume()
        gate = nil
    }

    private func suspendOnce() async {
        guard !didSuspend else { return }
        didSuspend = true
        await withCheckedContinuation {
            gate = $0
            waiter?.resume()
            waiter = nil
        }
    }
}
