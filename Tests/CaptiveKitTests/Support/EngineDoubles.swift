import Foundation
@testable import CaptiveKit

final class TestClock: @unchecked Sendable {
    private var current = Date(timeIntervalSince1970: 1_700_000_000)
    func tick() -> Date {
        current = current.addingTimeInterval(1)
        return current
    }
}

final class RecordingNotifier: Notifier, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(title: String, body: String)] = []
    var titles: [String] { lock.locked { recorded.map(\.title) } }
    func notify(title: String, body: String) { lock.locked { recorded.append((title, body)) } }
}

final class SleepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.locked { count } }
    func sleep(_ seconds: Double) async { lock.locked { count += 1 } }
}
