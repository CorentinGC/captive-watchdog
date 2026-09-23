import XCTest
@testable import CaptiveKit

final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var calls: [String] { lock.locked { recorded } }
    func record(_ pid: pid_t, _ signal: Int32) -> Int32 {
        lock.locked { recorded.append("\(pid):\(signal)") }
        return 0
    }
}

final class EngineHostTests: XCTestCase {
    override func tearDown() { StubURLProtocol.reset() }

    func waitUntil(_ timeout: Double = 3, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Hôte dont le moteur parle au stub, avec un intervalle d'une heure :
    /// seul un réveil explicite peut déclencher un second cycle rapidement.
    func makeHost(root: URL, email: String? = BnB.email, signals: SignalRecorder = SignalRecorder()) throws -> EngineHost {
        let paths = Paths(root: root)
        try paths.ensure()
        if let email {
            var config = Config()
            try config.set("email", email)
            try config.set("interval", "3600")
            try config.save(to: paths.config)
        }
        let clock = TestClock()
        return EngineHost(paths: paths, makeEngine: { config in
            WatchdogEngine(paths: paths, config: config, logger: Logger(url: nil), environment: .init(
                makeClient: { _ in StubURLProtocol.client() },
                sleep: { _ in try? await Task.sleep(nanoseconds: 5_000_000) },
                now: { clock.tick() },
                ssid: { nil },
                notifier: RecordingNotifier()))
        }, sendSignal: signals.record)
    }

    func testObservesThenTakesOverWhenTheHolderLeaves() async throws {
        StubURLProtocol.reset { _ in .html(BnB.successPage) }
        let root = try TempDir.make()
        let signals = SignalRecorder()
        let host = try makeHost(root: root, signals: signals)
        defer { host.stop() }
        let cli = InstanceLock(url: Paths(root: root).lock)
        XCTAssertTrue(try cli.acquire())

        XCTAssertEqual(host.start(), .observing(getpid()))
        XCTAssertNil(host.engine)
        host.reconnect()
        XCTAssertEqual(signals.calls, ["\(getpid()):\(SIGUSR1)"])

        cli.release()
        XCTAssertEqual(host.refresh(), .hosting)
        XCTAssertNotNil(host.engine)
        let store = StateStore(paths: Paths(root: root))
        let ran = await waitUntil { store.load().lastCheck != nil }
        XCTAssertTrue(ran)
        XCTAssertEqual(store.load().status, .online)

        host.stop()
        XCTAssertEqual(host.mode, .stopped)
        XCTAssertEqual(host.refresh(), .stopped, "une suspension n'est pas levée par refresh()")
        XCTAssertNil(InstanceLock.holderPID(at: Paths(root: root).lock))
    }

    func testReconnectWakesTheHostedEngine() async throws {
        StubURLProtocol.reset { _ in .html(BnB.successPage) }
        let root = try TempDir.make()
        let host = try makeHost(root: root)
        defer { host.stop() }
        XCTAssertEqual(host.start(), .hosting)
        let store = StateStore(paths: Paths(root: root))
        let first = await waitUntil { store.load().lastCheck != nil }
        XCTAssertTrue(first)
        let before = store.load().lastCheck
        host.reconnect()
        let second = await waitUntil { store.load().lastCheck != before }
        XCTAssertTrue(second, "le réveil doit déclencher un cycle malgré l'intervalle d'une heure")
    }

    func testSIGUSR1WakesTheHostedEngine() async throws {
        StubURLProtocol.reset { _ in .html(BnB.successPage) }
        let root = try TempDir.make()
        let host = try makeHost(root: root)
        defer { host.stop() }
        XCTAssertEqual(host.start(), .hosting)
        let store = StateStore(paths: Paths(root: root))
        let first = await waitUntil { store.load().lastCheck != nil }
        XCTAssertTrue(first)
        let before = store.load().lastCheck
        kill(getpid(), SIGUSR1)
        let second = await waitUntil { store.load().lastCheck != before }
        XCTAssertTrue(second, "SIGUSR1 (captive-watchdog reconnect) doit réveiller le moteur, pas tuer l'app")
    }

    func testNeedsEmailUntilAValidAddressIsSet() throws {
        StubURLProtocol.reset { _ in .html(BnB.successPage) }
        let root = try TempDir.make()
        let host = try makeHost(root: root, email: nil)
        defer { host.stop() }
        XCTAssertEqual(host.start(), .needsEmail)
        XCTAssertNil(host.engine)
        XCTAssertNil(InstanceLock.holderPID(at: Paths(root: root).lock), "le verrou ne reste pas pris sans moteur")
        XCTAssertThrowsError(try host.setEmail("pas-une-adresse"))
        XCTAssertEqual(host.mode, .needsEmail)
        XCTAssertEqual(try host.setEmail("  \(BnB.email) "), .hosting)
        XCTAssertEqual(try Config.load(from: Paths(root: root).config).email, BnB.email)
    }
}
