import XCTest
@testable import CaptiveKit

final class StatusSnapshotTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testOnlineWithARecentRenew() {
        var state = WatchdogState()
        state.status = .online
        state.lastCheck = now.addingTimeInterval(-12)
        state.lastRenew = now.addingTimeInterval(-3 * 3600)
        state.lastRenewNetwork = "wifi.moveon-hotelbb.com"
        state.lastRenewDuration = 6
        state.lastIncident = "20231114-221320-wifi.moveon-hotelbb.com"
        let s = StatusSnapshot.make(state: state, mode: .hosting, now: now)
        XCTAssertEqual(s.symbol, "checkmark.shield")
        XCTAssertEqual(s.headline, "En ligne")
        XCTAssertEqual(s.lastRenew, "Dernier renouvellement : il y a 3 h")
        XCTAssertEqual(s.lastRenewDetail, "\(Format.timestamp(state.lastRenew!)) — wifi.moveon-hotelbb.com (6 s)")
        XCTAssertEqual(s.lastCheck, "Vérifié il y a 12 s")
        XCTAssertNil(s.failure)
        XCTAssertEqual(s.engine, "Surveillance : active")
        XCTAssertEqual(s.lastIncident, state.lastIncident)
    }

    func testFailuresTurnTheIconIntoAWarning() {
        var state = WatchdogState()
        state.status = .captive
        state.consecutiveFailures = 2
        state.lastFailureReason = "toujours captif après le login"
        let s = StatusSnapshot.make(state: state, mode: .hosting, now: now)
        XCTAssertEqual(s.symbol, "exclamationmark.shield")
        XCTAssertEqual(s.headline, "Portail captif")
        XCTAssertEqual(s.failure, "2 échec(s) d'affilée — toujours captif après le login")
    }

    func testNeverRenewedAndUnknown() {
        let s = StatusSnapshot.make(state: WatchdogState(), mode: .needsEmail, now: now)
        XCTAssertEqual(s.headline, "État inconnu")
        XCTAssertEqual(s.lastRenew, "Dernier renouvellement : jamais")
        XCTAssertNil(s.lastRenewDetail)
        XCTAssertNil(s.lastCheck)
        XCTAssertEqual(s.engine, "Surveillance : e-mail à configurer")
        XCTAssertEqual(s.symbol, "exclamationmark.shield")
    }

    func testEngineModes() {
        var state = WatchdogState()
        state.status = .offline
        XCTAssertEqual(StatusSnapshot.make(state: state, mode: .hosting, now: now).symbol, "xmark.shield")
        XCTAssertEqual(StatusSnapshot.make(state: state, mode: .observing(4242), now: now).engine,
                       "Surveillance : démon en ligne de commande (pid 4242)")
        let stopped = StatusSnapshot.make(state: state, mode: .stopped, now: now)
        XCTAssertEqual(stopped.symbol, "shield.slash")
        XCTAssertEqual(stopped.engine, "Surveillance : suspendue")
        XCTAssertTrue(EngineMode.observing(1).isObserving)
        XCTAssertFalse(EngineMode.hosting.isObserving)
    }

    func testConfigErrorIsShown() {
        let s = StatusSnapshot.make(state: WatchdogState(), mode: .configError("config.json illisible"), now: now)
        XCTAssertEqual(s.engine, "Surveillance : config.json illisible")
        XCTAssertEqual(s.symbol, "exclamationmark.shield")
    }

    /// L'icône ne doit pas se confondre avec l'indicateur Wi-Fi du système.
    func testUnknownStateUsesAPlainShield() {
        XCTAssertEqual(StatusSnapshot.make(state: WatchdogState(), mode: .hosting, now: now).symbol, "shield")
    }
}
