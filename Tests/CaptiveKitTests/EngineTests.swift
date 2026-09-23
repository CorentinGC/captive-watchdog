import XCTest
@testable import CaptiveKit

final class EngineTests: XCTestCase {
    override func tearDown() { StubURLProtocol.reset() }

    func makeEngine(root: URL, notifier: RecordingNotifier, sleeper: SleepCounter = SleepCounter()) -> WatchdogEngine {
        var config = Config()
        config.email = BnB.email
        config.retries = 3
        config.retryDelay = 0
        let clock = TestClock()
        let environment = WatchdogEngine.Environment(
            makeClient: { _ in StubURLProtocol.client() },
            sleep: { await sleeper.sleep($0) },
            now: { clock.tick() },
            ssid: { nil },
            notifier: notifier)
        let engine = WatchdogEngine(paths: Paths(root: root), config: config, logger: Logger(url: nil), environment: environment)
        engine.reloadsConfig = false
        return engine
    }

    func testCaptiveCycleRenewsRecordsAndNotifies() async throws {
        let scenario = BnbScenario()
        scenario.install()
        let root = try TempDir.make()
        let notifier = RecordingNotifier()
        let result = await makeEngine(root: root, notifier: notifier).runOnce()
        XCTAssertEqual(result, .renewed)
        let store = StateStore(paths: Paths(root: root))
        let state = store.load()
        XCTAssertEqual(state.status, .online)
        XCTAssertNotNil(state.lastRenew)
        XCTAssertEqual(state.lastRenewNetwork, "wifi.moveon-hotelbb.com")
        XCTAssertEqual(state.consecutiveFailures, 0)
        let history = store.history()
        XCTAssertEqual(history.map(\.verdict), [.success])
        XCTAssertEqual(history.first?.profile, "bnb-hotels")
        XCTAssertEqual(notifier.titles, ["Wi-Fi reconnecté"])
    }

    func testOnlineCycleWritesNoHistory() async throws {
        let scenario = BnbScenario()
        scenario.authed = true
        scenario.install()
        let root = try TempDir.make()
        let notifier = RecordingNotifier()
        let result = await makeEngine(root: root, notifier: notifier).runOnce()
        XCTAssertEqual(result, .online)
        XCTAssertEqual(StateStore(paths: Paths(root: root)).load().status, .online)
        XCTAssertTrue(StateStore(paths: Paths(root: root)).history().isEmpty)
        XCTAssertTrue(notifier.titles.isEmpty)
    }

    func testFailureRetriesThenRecordsOneFailedEvent() async throws {
        let scenario = BnbScenario()
        scenario.grantAccess = false
        scenario.install()
        let root = try TempDir.make()
        let notifier = RecordingNotifier()
        let result = await makeEngine(root: root, notifier: notifier).runOnce()
        XCTAssertEqual(result, .failed("toujours captif après le login"))
        let store = StateStore(paths: Paths(root: root))
        XCTAssertEqual(store.history().map(\.attempts), [3])
        XCTAssertEqual(store.load().consecutiveFailures, 1)
        XCTAssertEqual(StubURLProtocol.requests.filter { $0.url.path == "/wifi-access.php" }.count, 3)
        XCTAssertEqual(notifier.titles, ["Wi-Fi : reconnexion impossible"])
    }

    func testOfflineCycle() async throws {
        StubURLProtocol.reset(nil)
        let root = try TempDir.make()
        let result = await makeEngine(root: root, notifier: RecordingNotifier()).runOnce()
        XCTAssertEqual(result, .offline)
        XCTAssertEqual(StateStore(paths: Paths(root: root)).load().status, .offline)
    }

    func testImmediateCycleRequestCutsTheNapShort() async throws {
        let sleeper = SleepCounter()
        let engine = makeEngine(root: try TempDir.make(), notifier: RecordingNotifier(), sleeper: sleeper)
        await engine.nap(2)
        XCTAssertEqual(sleeper.calls, 4)
        engine.requestImmediateCycle()
        await engine.nap(100)
        XCTAssertEqual(sleeper.calls, 4)
    }

    func testInstanceLockIsExclusiveAndReportsHolder() throws {
        let url = try TempDir.make().appendingPathComponent("watchdog.lock")
        XCTAssertNil(InstanceLock.holderPID(at: url))
        let first = InstanceLock(url: url)
        XCTAssertTrue(try first.acquire())
        XCTAssertFalse(try InstanceLock(url: url).acquire())
        XCTAssertEqual(InstanceLock.holderPID(at: url), getpid())
        first.release()
        XCTAssertNil(InstanceLock.holderPID(at: url))
        XCTAssertTrue(try InstanceLock(url: url).acquire())
    }
}
