import Foundation

/// Rejoue le parcours B&B observé le 2026-09-23 : sonde redirigée, portail,
/// POST 1 (formulaire e-mail), POST 2 (formulaire caché), chaîne de 302.
final class BnbScenario {
    var authed = false
    /// false : le POST 2 n'ouvre pas l'accès (échec côté passerelle).
    var grantAccess = true

    func install() {
        StubURLProtocol.reset { [unowned self] in self.reply($0) }
    }

    func reply(_ r: StubURLProtocol.Request) -> StubURLProtocol.Reply? {
        switch (r.method, r.url.host ?? "", r.url.path) {
        case ("GET", "captive.apple.com", _):
            return authed ? .html(BnB.successPage) : .redirect(BnB.probeRedirect)
        case ("GET", "wifi.moveon-hotelbb.com", "/"):
            return .html(try! Fixture.string("bnb/portal-fr.html"),
                         headers: ["Set-Cookie": "SESSIONID=abc123; Path=/; Max-Age=600; Secure; HttpOnly"])
        case ("POST", "wifi.moveon-hotelbb.com", "/wifi-access.php"):
            return .html(try! Fixture.string("bnb/stage2.html"),
                         headers: ["Set-Cookie": "wf=1; Domain=moveon-hotelbb.com; Path=/"])
        case ("POST", "redirect-wifi.moveon-hotelbb.com", "/reg.php"):
            if grantAccess { authed = true }
            return .redirect(BnB.chain[0])
        case ("GET", "1.1.1.1", "/redir_tmp.php"):
            return .redirect(BnB.chain[1])
        case ("GET", "wifi.moveon-hotelbb.com", "/redirect.php"):
            return .redirect(BnB.chain[2])
        case ("GET", "notre.guide", _):
            return .html("<html><title>Guide</title><body>Bienvenue</body></html>")
        default:
            return .html("introuvable", status: 404)
        }
    }
}
