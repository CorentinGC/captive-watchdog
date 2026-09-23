import XCTest
@testable import CaptiveKit

final class ProfileTests: XCTestCase {
    func write(_ json: String, _ name: String, in dir: URL) throws {
        try json.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testBuiltinProfilesDecode() {
        XCTAssertEqual(BuiltinProfiles.all.map(\.id), ["generic", "bnb-hotels"])
        let bnb = BuiltinProfiles.all[1]
        XCTAssertEqual(bnb.form?.checkboxes?.skip, ["optinEmail"])
        XCTAssertEqual(bnb.form?.submit, "connect")
    }

    func testResolvesBnBByHostWhenSSIDIsUnreadable() {
        let store = ProfileStore(userDirectory: nil)
        XCTAssertEqual(store.resolve(portalHost: "wifi.moveon-hotelbb.com", ssid: nil).id, "bnb-hotels")
        XCTAssertEqual(store.resolve(portalHost: "wifi.moveon-hotelbb.com", ssid: "BBHOTELSGuest").id, "bnb-hotels")
        XCTAssertEqual(store.resolve(portalHost: "wifi.moveon-hotelbb.com", ssid: "Livebox-1234").id, "generic")
        XCTAssertEqual(store.resolve(portalHost: "portal.example.com", ssid: nil).id, "generic")
    }

    func testMoreSpecificProfileWins() throws {
        let dir = try TempDir.make()
        try write(#"{"id":"host-only","match":{"portalHost":"example\\.com$"}}"#, "a.json", in: dir)
        try write(#"{"id":"host-and-ssid","match":{"portalHost":"example\\.com$","ssid":"^Hotel"}}"#, "b.json", in: dir)
        let store = ProfileStore(userDirectory: dir)
        XCTAssertEqual(store.resolve(portalHost: "portal.example.com", ssid: "HotelGuest").id, "host-and-ssid")
        XCTAssertEqual(store.resolve(portalHost: "portal.example.com", ssid: nil).id, "host-only")
    }

    func testUserProfileWithSameIdReplacesBuiltin() throws {
        let dir = try TempDir.make()
        try write(#"{"id":"bnb-hotels","name":"Mon B&B","match":{"portalHost":"moveon-hotelbb\\.com$"}}"#, "bnb.json", in: dir)
        let store = ProfileStore(userDirectory: dir)
        let bnb = store.resolve(portalHost: "wifi.moveon-hotelbb.com", ssid: nil)
        XCTAssertEqual(bnb.name, "Mon B&B")
        XCTAssertNil(bnb.form, "le remplacement est intégral")
        XCTAssertEqual(store.profiles.filter { $0.id == "bnb-hotels" }.count, 1)
    }

    func testInvalidUserProfilesAreSkippedAndReported() throws {
        let dir = try TempDir.make()
        try write("{ pas du json", "broken.json", in: dir)
        try write(#"{"id":"bad-regex","match":{"portalHost":"(unclosed"}}"#, "regex.json", in: dir)
        try write(#"{"id":"","match":{"portalHost":"x"}}"#, "noid.json", in: dir)
        try write(#"{"id":"fine","match":{"portalHost":"fine\\.example\\.com$"}}"#, "fine.json", in: dir)
        try write("ignored", "notes.txt", in: dir)
        let store = ProfileStore(userDirectory: dir)
        XCTAssertEqual(Set(store.errors.map(\.file)), ["broken.json", "regex.json", "noid.json"])
        XCTAssertEqual(store.resolve(portalHost: "fine.example.com", ssid: nil).id, "fine")
        XCTAssertTrue(store.profiles.contains { $0.id == "bnb-hotels" })
    }

    func testMissingUserDirectoryIsNotAnError() {
        let store = ProfileStore(userDirectory: URL(fileURLWithPath: "/nonexistent/captive-watchdog"))
        XCTAssertTrue(store.errors.isEmpty)
        XCTAssertEqual(store.profiles.count, BuiltinProfiles.all.count)
    }
}
