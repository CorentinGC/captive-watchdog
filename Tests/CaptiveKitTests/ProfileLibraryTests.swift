import XCTest
@testable import CaptiveKit

final class ProfileLibraryTests: XCTestCase {
    let custom = #"""
    {
      "id": "hotel-example",
      "name": "Hôtel Example",
      "match": { "portalHost": "(^|\\.)portal\\.example\\.com$" }
    }
    """#

    func testBuiltinsAreListedAndReadOnly() throws {
        let (entries, errors) = ProfileLibrary(directory: try TempDir.make()).load()
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(entries.map(\.id), ["generic", "bnb-hotels"])
        XCTAssertEqual(entries.map(\.origin), [.builtin, .builtin])
        XCTAssertFalse(entries[1].isEditable)
        XCTAssertEqual(try ProfileLibrary.parse(entries[1].json), BuiltinProfiles.all[1])
    }

    func testSaveCreatesAUserProfileFileKeepingTheText() throws {
        let dir = try TempDir.make()
        let library = ProfileLibrary(directory: dir)
        let profile = try library.save(custom)
        XCTAssertEqual(profile.id, "hotel-example")
        let file = dir.appendingPathComponent("hotel-example.json")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), custom + "\n")
        let entry = try XCTUnwrap(library.load().entries.last)
        XCTAssertEqual(entry.origin, .user)
        XCTAssertEqual(entry.file?.lastPathComponent, "hotel-example.json")
        XCTAssertEqual(entry.json, custom + "\n")
        XCTAssertEqual(ProfileStore(userDirectory: dir).resolve(portalHost: "portal.example.com", ssid: nil).id, "hotel-example")
    }

    func testSavingAnExistingIdRewritesItsFile() throws {
        let dir = try TempDir.make()
        try custom.write(to: dir.appendingPathComponent("mon-fichier.json"), atomically: true, encoding: .utf8)
        let library = ProfileLibrary(directory: dir)
        _ = try library.save(custom.replacingOccurrences(of: "Hôtel Example", with: "Renommé"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["mon-fichier.json"])
        XCTAssertEqual(library.load().entries.last?.profile.name, "Renommé")
    }

    func testInvalidTextIsRejectedWithoutWriting() throws {
        let dir = try TempDir.make()
        let library = ProfileLibrary(directory: dir)
        let cases: [(String, String)] = [
            ("{ pas du json", "JSON invalide"),
            (#"{"name":"sans id"}"#, "clé manquante : id"),
            (#"{"id":"x","match":{"portalHost":"(unclosed"}}"#, "regex invalide"),
            (#"{"id":"../evil"}"#, "id invalide"),
        ]
        for (text, expected) in cases {
            XCTAssertThrowsError(try library.save(text)) { error in
                XCTAssertTrue(String(describing: error).contains(expected), "\(text) → \(error)")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testDeletingAnOverrideRestoresTheBuiltin() throws {
        let dir = try TempDir.make()
        let library = ProfileLibrary(directory: dir)
        _ = try library.save(#"{"id":"bnb-hotels","name":"Mon B&B"}"#)
        var bnb = try XCTUnwrap(library.load().entries.first { $0.id == "bnb-hotels" })
        XCTAssertEqual(bnb.origin, .override)
        XCTAssertEqual(bnb.originLabel, "remplace l'intégré")
        XCTAssertEqual(library.load().entries.count, 2)
        try library.delete(bnb)
        bnb = try XCTUnwrap(library.load().entries.first { $0.id == "bnb-hotels" })
        XCTAssertEqual(bnb.origin, .builtin)
        XCTAssertThrowsError(try library.delete(bnb))
    }

    func testImportAndExportRoundTrip() throws {
        let source = try TempDir.make().appendingPathComponent("partage.json")
        try custom.write(to: source, atomically: true, encoding: .utf8)
        let library = ProfileLibrary(directory: try TempDir.make())
        XCTAssertEqual(try library.importFile(source).id, "hotel-example")
        let entry = try XCTUnwrap(library.load().entries.first { $0.id == "hotel-example" })
        let exported = try TempDir.make().appendingPathComponent("out.json")
        try library.export(entry, to: exported)
        XCTAssertEqual(try ProfileLibrary.parse(String(contentsOf: exported, encoding: .utf8)).name, "Hôtel Example")
    }

    func testDuplicateIdsKeepTheLastFileAndReportTheOther() throws {
        let dir = try TempDir.make()
        try custom.write(to: dir.appendingPathComponent("a.json"), atomically: true, encoding: .utf8)
        try custom.replacingOccurrences(of: "Hôtel Example", with: "B").write(to: dir.appendingPathComponent("b.json"), atomically: true, encoding: .utf8)
        let (entries, errors) = ProfileLibrary(directory: dir).load()
        XCTAssertEqual(entries.filter { $0.id == "hotel-example" }.map(\.profile.name), ["B"])
        XCTAssertEqual(errors.map(\.file), ["a.json"])
    }

    func testTemplateParses() throws {
        XCTAssertEqual(try ProfileLibrary.parse(ProfileLibrary.template).id, "mon-portail")
    }

    func testDryRunUsesTheEditedProfileOrSaysWhyNot() throws {
        let html = try Fixture.string("bnb/portal-fr.html")
        let matching = try ProfileLibrary.parse(#"{"id":"essai","match":{"portalHost":"moveon-hotelbb\\.com$"},"form":{"submit":"connect"}}"#)
        let report = ProfileLibrary.test(matching, html: html, pageURL: BnB.portalURL,
                                         identity: Identity(email: BnB.email), skipCheckbox: FormFiller.defaultSkipCheckbox)
        XCTAssertTrue(report.contains("profil : essai"))
        XCTAssertTrue(report.contains("  connect = Se connecter"))
        XCTAssertFalse(report.contains("ne correspond pas"))

        let other = try ProfileLibrary.parse(custom)
        let mismatch = ProfileLibrary.test(other, html: html, pageURL: BnB.portalURL,
                                           identity: Identity(email: BnB.email), skipCheckbox: FormFiller.defaultSkipCheckbox)
        XCTAssertTrue(mismatch.contains("profil : generic"))
        XCTAssertTrue(mismatch.contains("« hotel-example » ne correspond pas à cet hôte"))
    }
}
