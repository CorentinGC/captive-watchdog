import Foundation

enum Fixture {
    static func url(_ path: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(path)
    }

    static func string(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: url(path)), as: UTF8.self)
    }
}

/// Valeurs du portail B&B réel, lavées (voir Scripts/scrub.sh).
enum BnB {
    static let email = "guest@example.com"
    static let probeRedirect = "https://wifi.moveon-hotelbb.com/?cmd=login&mod=hive&url=ENCRYPTED_URL_PLACEHOLDER&ssid=BBHOTELSGuest&mac=000000000000&autherr=0&Called-Station-Id=000000000000&NAS-IP-Address=1.1.1.1&RADIUS-NAS-IP=192.0.2.1&Calling-Station-Id=000000000000&STA-IP=192.0.2.1&NAS-ID=0000-000000"
    static var portalURL: URL { URL(string: probeRedirect)! }
    static let loginAction = "https://wifi.moveon-hotelbb.com/wifi-access.php"
    static let stage2Action = "https://redirect-wifi.moveon-hotelbb.com/reg.php"
    static let chain = [
        "http://1.1.1.1:80/redir_tmp.php?ori=https%3a%2f%2fwifi.moveon-hotelbb.com%2fredirect.php%3fsessid%3dhotelBB%26hotelid%3d0000&random=RANDOM_PLACEHOLDER",
        "https://wifi.moveon-hotelbb.com/redirect.php?sessid=hotelBB&hotelid=0000",
        "https://notre.guide/bb_0000?source=wifi-hotel",
    ]
    static let successPage = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"
}

enum TempDir {
    static func make() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cw-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
