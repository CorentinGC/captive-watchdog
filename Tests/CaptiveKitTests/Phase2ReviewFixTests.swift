import XCTest
@testable import CaptiveKit

/// Régressions de la revue finale de la phase 2.
final class Phase2ReviewFixTests: XCTestCase {
    override func tearDown() { StubURLProtocol.reset() }

    /// Suspendre pendant un login ne doit ni écrire un faux échec ni notifier.
    func testACancelledCycleLeavesNoTrace() async throws {
        StubURLProtocol.reset { request in
            request.url.host == "captive.apple.com" ? .redirect("https://portal.example.com/") : .html("<html>rien</html>")
        }
        let root = try TempDir.make()
        let paths = Paths(root: root)
        try paths.ensure()
        var config = Config()
        config.email = BnB.email
        config.retries = 3
        let notifier = RecordingNotifier()
        let clock = TestClock()
        let engine = WatchdogEngine(paths: paths, config: config, logger: Logger(url: nil), environment: .init(
            makeClient: { _ in StubURLProtocol.client() },
            // L'utilisateur suspend pendant l'attente entre deux tentatives.
            sleep: { _ in withUnsafeCurrentTask { $0?.cancel() } },
            now: { clock.tick() },
            ssid: { nil },
            notifier: notifier))
        engine.reloadsConfig = false
        _ = await Task { await engine.runOnce() }.value
        let store = StateStore(paths: paths)
        XCTAssertEqual(store.history(), [], "aucun événement d'échec pour un cycle annulé")
        XCTAssertEqual(notifier.titles, [])
        XCTAssertEqual(store.load().consecutiveFailures, 0)
        XCTAssertNil(store.load().lastCheck, "l'état n'est pas réécrit par un cycle annulé")
    }

    /// `captive-watchdog reconnect` peut viser l'app dès qu'elle tient le verrou,
    /// même brièvement (état « e-mail à configurer ») : le signal doit être
    /// neutralisé dès la création de l'hôte.
    func testSIGUSR1IsIgnoredAsSoonAsTheHostExists() throws {
        signal(SIGUSR1, SIG_DFL)
        let paths = Paths(root: try TempDir.make())
        let host = EngineHost(paths: paths, makeEngine: { _ in fatalError("pas de moteur") })
        let current = signal(SIGUSR1, SIG_IGN)
        XCTAssertEqual(unsafeBitCast(current, to: Int.self), unsafeBitCast(SIG_IGN, to: Int.self))
        _ = host
    }
}
