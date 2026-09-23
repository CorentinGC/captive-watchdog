#!/usr/bin/env python3
"""
wifi-watchdog — reconnexion automatique aux portails captifs (macOS).

Surveille la sonde captive d'Apple. Quand un portail est detecte : dumpe tout
dans un dossier d'incident, parse le formulaire de login, le remplit (email +
consentements + champs caches), le soumet, puis enchaine les formulaires
auto-soumis que le portail renvoie (pattern classique : la page de succes
contient un second form POST vers le concentrateur wifi). Verifie enfin que la
connectivite est revenue.

Aucune dependance externe : stdlib uniquement, /usr/bin/python3 suffit.

@author CorentinGC
"""

import argparse
import http.cookiejar
import json
import os
import re
import shutil
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser

HOME = os.path.expanduser("~")
CONFIG_PATH = os.path.join(HOME, ".config", "wifi-watchdog", "config.env")
STATE_DIR = os.path.join(HOME, ".local", "state", "wifi-watchdog")
DUMP_DIR = os.path.join(STATE_DIR, "portals")
LOG_PATH = os.path.join(STATE_DIR, "watchdog.log")
MAX_LOG_BYTES = 2 * 1024 * 1024

PROBE_URL = "http://captive.apple.com/hotspot-detect.html"
PROBE_OK = "<TITLE>Success</TITLE>"

ONLINE, CAPTIVE, OFFLINE = "ONLINE", "CAPTIVE", "OFFLINE"

DEFAULTS = {
    "EMAIL": "",
    "PASSWORD": "",
    "INTERVAL": "20",
    "RETRIES": "3",
    "RETRY_DELAY": "4",
    "FAIL_BACKOFF": "300",
    "VERIFY_TLS": "0",
    "NOTIFY": "1",
    "KEEP_INCIDENTS": "10",
    "MAX_CHAIN_HOPS": "4",
    # Cases a NE PAS cocher : opt-ins marketing, pas des CGU.
    "SKIP_CHECKBOX": "optin|newsletter|marketing|offre|promo|publicit|advert|subscribe|loyalty",
    "USER_AGENT": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    ),
}

# Champs qui doivent recevoir l'email : les portails nomment ca de 15 facons.
EMAIL_HINT = re.compile(
    r"e-?mail|courriel|adresse|user(name)?|login|identifiant|guest|client|nom",
    re.I,
)
# Bouton de soumission a privilegier quand un formulaire en a plusieurs.
SUBMIT_PREFER = re.compile(
    r"connect|log[-_ ]?in|continu|acce(s|d)|valider|entrer|start|submit", re.I
)
# Formulaires a ignorer (barres de recherche, newsletters de la page d'accueil).
SKIP_FORM_HINT = re.compile(r"search|recherche|newsletter", re.I)


def log(msg):
    """Ecrit une ligne horodatee dans le log et sur stderr."""
    line = "%s %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    print(line, file=sys.stderr, flush=True)
    try:
        if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > MAX_LOG_BYTES:
            os.replace(LOG_PATH, LOG_PATH + ".1")
        with open(LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError as exc:
        print("log write failed: %s" % exc, file=sys.stderr)


def load_config():
    """Charge config.env (KEY=VALUE) par-dessus les valeurs par defaut."""
    cfg = dict(DEFAULTS)
    try:
        with open(CONFIG_PATH, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                cfg[key.strip()] = val.strip().strip('"').strip("'")
    except FileNotFoundError:
        log("config absente (%s), valeurs par defaut" % CONFIG_PATH)
    # Ancien nom de cle, conserve pour ne pas casser une config existante.
    if "KEEP_DUMPS" in cfg and "KEEP_INCIDENTS" not in cfg:
        cfg["KEEP_INCIDENTS"] = cfg["KEEP_DUMPS"]
    return cfg


def notify(cfg, title, message):
    """Notification macOS via osascript. Silencieuse si NOTIFY=0."""
    if cfg.get("NOTIFY") != "1":
        return
    script = "display notification %s with title %s" % (
        json.dumps(message),
        json.dumps(title),
    )
    try:
        subprocess.run(
            ["/usr/bin/osascript", "-e", script],
            check=False, capture_output=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        log("notification impossible: %s" % exc)


class TracingRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Enregistre chaque saut de redirection, invisible autrement."""

    def __init__(self):
        self.hops = []

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        self.hops.append({"code": code, "from": req.full_url, "to": newurl})
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class Resp:
    """Reponse HTTP complete : corps, status, headers et chaine de redirection."""

    def __init__(self, url, body, status, headers, hops):
        self.url = url
        self.body = body
        self.status = status
        self.headers = headers
        self.hops = hops

    def summary(self, request=None):
        data = {
            "url": self.url,
            "status": self.status,
            "redirects": self.hops,
            "headers": self.headers,
        }
        if request:
            data["request"] = request
        return data


def make_opener(cfg):
    """Opener urllib avec cookies (les portails en posent systematiquement)."""
    jar = http.cookiejar.CookieJar()
    tracer = TracingRedirectHandler()
    handlers = [urllib.request.HTTPCookieProcessor(jar), tracer]
    if cfg.get("VERIFY_TLS") != "1":
        # Les portails captifs presentent quasi toujours un certificat invalide
        # (MITM par definition). On accepte, la session n'a rien de sensible.
        handlers.append(
            urllib.request.HTTPSHandler(context=ssl._create_unverified_context())
        )
    opener = urllib.request.build_opener(*handlers)
    opener.addheaders = [
        ("User-Agent", cfg["USER_AGENT"]),
        ("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"),
        ("Accept-Language", "fr-FR,fr;q=0.9,en;q=0.8"),
    ]
    opener.redirect_tracer = tracer
    opener.cookie_jar = jar
    return opener


def fetch(opener, url, data=None, referer=None, timeout=15):
    """GET ou POST. Retourne un Resp (corps + status + headers + redirects)."""
    tracer = getattr(opener, "redirect_tracer", None)
    if tracer is not None:
        tracer.hops = []
    headers = {}
    if referer:
        headers["Referer"] = referer
    if data is None:
        req = urllib.request.Request(url, headers=headers, method="GET")
    else:
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        req = urllib.request.Request(
            url, data=data.encode("utf-8"), headers=headers, method="POST"
        )
    with opener.open(req, timeout=timeout) as resp:
        body = resp.read().decode("utf-8", "replace")
        hops = list(tracer.hops) if tracer is not None else []
        return Resp(resp.geturl(), body, resp.status, dict(resp.headers), hops)


class FormParser(HTMLParser):
    """Extrait les formulaires, leurs champs, et un eventuel meta-refresh."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.forms = []
        self.meta_refresh = None
        self.title = ""
        self.base_href = None
        self._form = None
        self._select = None
        self._in_title = False

    def _field(self, tag, attrs, ftype):
        return {
            "tag": tag,
            "type": ftype,
            "name": attrs.get("name", ""),
            "value": attrs.get("value", ""),
            "id": attrs.get("id", ""),
            "placeholder": attrs.get("placeholder", ""),
            "checked": "checked" in attrs,
            "required": "required" in attrs,
            "options": [],
        }

    def handle_starttag(self, tag, attrs):
        a = {k.lower(): (v if v is not None else "") for k, v in attrs}
        if tag == "title":
            self._in_title = True
        elif tag == "base" and a.get("href"):
            # Un navigateur resout les URL relatives contre <base href>.
            self.base_href = a.get("href")
        elif tag == "meta" and a.get("http-equiv", "").lower() == "refresh":
            self.meta_refresh = a.get("content", "")
        elif tag == "form":
            self._form = {
                "action": a.get("action", ""),
                "method": (a.get("method") or "get").lower(),
                "id": a.get("id", ""),
                "name": a.get("name", ""),
                "class": a.get("class", ""),
                "fields": [],
            }
        elif self._form is None:
            return
        elif tag == "input":
            self._form["fields"].append(
                self._field(tag, a, (a.get("type") or "text").lower())
            )
        elif tag == "button":
            self._form["fields"].append(
                self._field(tag, a, (a.get("type") or "submit").lower())
            )
        elif tag == "textarea":
            self._form["fields"].append(self._field(tag, a, "textarea"))
        elif tag == "select":
            field = self._field(tag, a, "select")
            self._form["fields"].append(field)
            self._select = field
        elif tag == "option" and self._select is not None:
            self._select["options"].append(a.get("value", ""))
            if "selected" in a:
                self._select["value"] = a.get("value", "")

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False
        elif tag == "form" and self._form is not None:
            self.forms.append(self._form)
            self._form = None
        elif tag == "select":
            self._select = None

    def handle_data(self, data):
        if self._in_title:
            self.title += data.strip()


def resolve(parser, page_url, target):
    """Resout une URL relative comme le ferait un navigateur (<base href> inclus)."""
    base = urllib.parse.urljoin(page_url, parser.base_href) if parser.base_href else page_url
    return urllib.parse.urljoin(base, target or base)


def score_form(form):
    """Note un formulaire : plus c'est un login de portail, plus le score monte."""
    blob = " ".join([form["id"], form["name"], form["class"], form["action"]])
    if SKIP_FORM_HINT.search(blob):
        return -1
    score = 0
    for field in form["fields"]:
        ftype = field["type"]
        hint = " ".join([field["name"], field["id"], field["placeholder"]])
        if ftype == "email" or (ftype in ("text", "tel") and EMAIL_HINT.search(hint)):
            score += 5
        elif ftype == "checkbox":
            score += 2
        elif ftype == "hidden":
            score += 1
        elif ftype in ("submit", "image"):
            score += 2
        elif ftype == "password":
            score += 1
    return score


def form_digest(forms):
    """Resume des formulaires vus, pour le meta.json d'incident."""
    return [
        {
            "index": i,
            "score": score_form(f),
            "action": f["action"],
            "method": f["method"],
            "id": f["id"],
            "auto": is_auto_form(f),
            "fields": ["%s:%s" % (x["type"], x["name"]) for x in f["fields"]],
        }
        for i, f in enumerate(forms)
    ]


def pick_form(forms):
    """Retourne le formulaire de login le plus probable, ou None."""
    scored = [(score_form(f), i, f) for i, f in enumerate(forms)]
    scored = [s for s in scored if s[0] > 0]
    if not scored:
        return None
    scored.sort(key=lambda s: (-s[0], s[1]))
    return scored[0][2]


def is_auto_form(form):
    """Formulaire auto-soumis : que des champs caches, aucune saisie attendue.

    C'est le rebond classique des portails : la page de succes POSTe des
    identifiants generes vers le concentrateur wifi. Sans JS, il faut le rejouer.
    """
    if not form["fields"]:
        return False
    for field in form["fields"]:
        if field["type"] in ("hidden", "submit", "image", "button"):
            continue
        return False
    return any(f["type"] == "hidden" and f["name"] for f in form["fields"])


def build_payload(form, cfg):
    """Construit les couples (name, value) a poster. Retourne (payload, notes)."""
    email = cfg["EMAIL"]
    password = cfg["PASSWORD"]
    payload = []
    notes = []
    email_set = False
    submits = []
    skip_cb = re.compile(cfg.get("SKIP_CHECKBOX") or r"(?!x)x", re.I)

    # Radios : un seul choix par groupe (celui coche, sinon le premier).
    radios = {}
    for field in form["fields"]:
        if field["type"] == "radio" and field["name"]:
            radios.setdefault(field["name"], field["value"])
            if field["checked"]:
                radios[field["name"]] = field["value"]
    radios_done = set()

    plain_text = []
    for field in form["fields"]:
        ftype, name = field["type"], field["name"]
        hint = " ".join([name, field["id"], field["placeholder"]])

        if ftype in ("submit", "image", "button"):
            # Un navigateur n'envoie que le bouton clique : on en garde un seul.
            if name:
                submits.append(field)
            continue
        if not name:
            continue

        if ftype == "hidden":
            payload.append((name, field["value"]))
        elif ftype == "radio":
            if name not in radios_done:
                payload.append((name, radios[name]))
                radios_done.add(name)
        elif ftype == "checkbox":
            if skip_cb.search(hint):
                notes.append("checkbox laissee decochee (opt-in marketing): %s" % name)
                continue
            payload.append((name, field["value"] or "on"))
            notes.append("checkbox cochee: %s" % name)
        elif ftype == "select":
            value = field["value"] or (field["options"][0] if field["options"] else "")
            payload.append((name, value))
        elif ftype == "password":
            payload.append((name, password))
            if not password:
                notes.append("champ password vide (PASSWORD non configure)")
        elif ftype == "email" or EMAIL_HINT.search(hint):
            payload.append((name, email))
            email_set = True
        else:
            plain_text.append((len(payload), name))
            payload.append((name, ""))

    # Aucun champ email identifie : si un champ texte libre existe, c'est lui.
    if not email_set and plain_text:
        index, name = plain_text[0]
        payload[index] = (name, email)
        email_set = True
        notes.append("email place par defaut dans le champ texte '%s'" % name)

    if submits:
        preferred = next(
            (f for f in submits
             if SUBMIT_PREFER.search(" ".join([f["name"], f["value"], f["id"]]))),
            submits[0],
        )
        payload.append((preferred["name"], preferred["value"] or "Submit"))
        if len(submits) > 1:
            notes.append("%d boutons submit, retenu '%s'"
                         % (len(submits), preferred["name"]))

    if not email_set:
        notes.append("ATTENTION: aucun champ email trouve")
    return payload, notes


class Incident:
    """Un dossier par portail rencontre : tout ce qu'il faut pour un post-mortem.

    Arborescence :
      incident-<ts>-<host>/
        meta.json          verdict, formulaires vus + scores, notes, etapes
        NN-<label>.html    corps de chaque reponse
        NN-<label>.json    status, headers, redirections, requete envoyee
    """

    def __init__(self, host):
        stamp = time.strftime("%Y%m%d-%H%M%S")
        self.dir = os.path.join(DUMP_DIR, "incident-%s-%s" % (stamp, host))
        self.meta = {
            "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "host": host,
            "verdict": "en cours",
            "steps": [],
            "notes": [],
            "forms_seen": [],
        }
        self._n = 0
        self.ok = True
        try:
            os.makedirs(self.dir, exist_ok=True)
        except OSError as exc:
            log("dossier d'incident impossible: %s" % exc)
            self.ok = False

    def record(self, label, resp, request=None):
        """Sauvegarde une reponse (corps + metadonnees) et la trace dans meta."""
        step = {
            "n": self._n,
            "label": label,
            "url": resp.url,
            "status": resp.status,
            "redirects": resp.hops,
        }
        if request:
            step["request"] = request
        self.meta["steps"].append(step)
        if not self.ok:
            self._n += 1
            return
        base = os.path.join(self.dir, "%02d-%s" % (self._n, label))
        try:
            with open(base + ".html", "w", encoding="utf-8") as fh:
                fh.write(resp.body)
            with open(base + ".json", "w", encoding="utf-8") as fh:
                json.dump(resp.summary(request), fh, indent=2, ensure_ascii=False)
        except OSError as exc:
            log("ecriture d'incident impossible: %s" % exc)
        self._n += 1

    def note(self, msg):
        self.meta["notes"].append(msg)

    def close(self, verdict):
        self.meta["verdict"] = verdict
        self.meta["ended"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        if not self.ok:
            return
        try:
            with open(os.path.join(self.dir, "meta.json"), "w", encoding="utf-8") as fh:
                json.dump(self.meta, fh, indent=2, ensure_ascii=False)
        except OSError as exc:
            log("meta.json non ecrit: %s" % exc)


def prune_incidents(cfg):
    """Ne garde que les N derniers incidents. Appele AVANT d'en ouvrir un neuf,
    jamais pendant : le premier dump d'un incident en cours ne peut pas sauter."""
    try:
        keep = int(cfg["KEEP_INCIDENTS"])
    except (KeyError, ValueError):
        keep = 10
    try:
        entries = [
            os.path.join(DUMP_DIR, d)
            for d in os.listdir(DUMP_DIR)
            if d.startswith("incident-") and os.path.isdir(os.path.join(DUMP_DIR, d))
        ]
        entries.sort(key=os.path.getmtime, reverse=True)
        for path in entries[keep:]:
            shutil.rmtree(path, ignore_errors=True)
    except OSError:
        pass


def probe(cfg, opener):
    """Etat du reseau. Retourne (etat, Resp ou message d'erreur)."""
    try:
        resp = fetch(opener, PROBE_URL, timeout=10)
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return OFFLINE, str(exc)
    if PROBE_OK in resp.body:
        return ONLINE, resp
    return CAPTIVE, resp


def follow_meta_refresh(opener, base_url, content):
    """Suit un <meta http-equiv=refresh url=...>. Retourne un Resp ou None."""
    match = re.search(r"url\s*=\s*['\"]?([^'\";]+)", content or "", re.I)
    if not match:
        return None
    target = urllib.parse.urljoin(base_url, match.group(1).strip())
    try:
        return fetch(opener, target, referer=base_url)
    except (urllib.error.URLError, OSError, ValueError) as exc:
        log("meta-refresh vers %s a echoue: %s" % (target, exc))
        return None


def follow_chain(cfg, opener, resp, incident):
    """Enchaine les rebonds post-login : formulaires auto-soumis et meta-refresh.

    Les portails renvoient souvent une page 'Redirection en cours' contenant un
    form cache POSTe par JS vers le concentrateur. C'est ce POST qui ouvre
    reellement l'acces : sans lui, le login est un faux succes.
    """
    try:
        max_hops = int(cfg["MAX_CHAIN_HOPS"])
    except (KeyError, ValueError):
        max_hops = 4

    for hop in range(1, max_hops + 1):
        parser = FormParser()
        parser.feed(resp.body)
        incident.meta["forms_seen"].append(
            {"step": "chain-%d" % hop, "url": resp.url, "forms": form_digest(parser.forms)}
        )

        auto = next((f for f in parser.forms if is_auto_form(f)), None)
        if auto is not None:
            payload, _ = build_payload(auto, cfg)
            action = resolve(parser, resp.url, auto["action"])
            encoded = urllib.parse.urlencode(payload)
            log("rebond %d : form auto-soumis -> %s (%s)"
                % (hop, action, [p[0] for p in payload]))
            incident.note("rebond %d vers %s" % (hop, action))
            try:
                if auto["method"] == "post":
                    resp = fetch(opener, action, data=encoded, referer=resp.url)
                else:
                    sep = "&" if "?" in action else "?"
                    resp = fetch(opener, action + sep + encoded, referer=resp.url)
            except (urllib.error.URLError, OSError, ValueError) as exc:
                log("rebond %d echoue: %s" % (hop, exc))
                incident.note("rebond %d echoue: %s" % (hop, exc))
                return resp
            incident.record("chain%d" % hop, resp,
                            {"url": action, "method": auto["method"], "payload": payload})
            continue

        if parser.meta_refresh:
            log("rebond %d : meta-refresh" % hop)
            followed = follow_meta_refresh(opener, resp.url, parser.meta_refresh)
            if followed is None:
                return resp
            resp = followed
            incident.record("chain%d-refresh" % hop, resp)
            continue

        return resp

    incident.note("chaine interrompue apres %d rebonds" % max_hops)
    return resp


def attempt_login(cfg, opener, resp, incident):
    """Une tentative complete de login. Retourne True si le net est revenu."""
    parser = FormParser()
    parser.feed(resp.body)
    incident.meta["forms_seen"].append(
        {"step": "portal", "url": resp.url, "title": parser.title,
         "forms": form_digest(parser.forms)}
    )

    if not parser.forms and parser.meta_refresh:
        log("meta-refresh detecte avant login, on suit")
        followed = follow_meta_refresh(opener, resp.url, parser.meta_refresh)
        if followed is not None:
            resp = followed
            incident.record("portal-refresh", resp)
            parser = FormParser()
            parser.feed(resp.body)
            incident.meta["forms_seen"].append(
                {"step": "portal-refresh", "url": resp.url, "title": parser.title,
                 "forms": form_digest(parser.forms)}
            )

    form = pick_form(parser.forms)
    if form is None:
        msg = ("aucun formulaire exploitable sur %s (titre: %r, %d form(s))"
               % (resp.url, parser.title, len(parser.forms)))
        log(msg)
        incident.note(msg)
        return False

    payload, notes = build_payload(form, cfg)
    for note in notes:
        log("  %s" % note)
        incident.note(note)

    action = resolve(parser, resp.url, form["action"])
    log("POST -> %s | champs: %s" % (action, [p[0] for p in payload]))
    encoded = urllib.parse.urlencode(payload)
    request = {"url": action, "method": form["method"], "payload": payload}

    try:
        if form["method"] == "post":
            resp = fetch(opener, action, data=encoded, referer=resp.url)
        else:
            sep = "&" if "?" in action else "?"
            resp = fetch(opener, action + sep + encoded, referer=resp.url)
    except (urllib.error.URLError, OSError, ValueError) as exc:
        log("soumission echouee: %s" % exc)
        incident.note("soumission echouee: %s" % exc)
        return False

    log("reponse %s depuis %s" % (resp.status, resp.url))
    incident.record("login-response", resp, request)

    follow_chain(cfg, opener, resp, incident)

    time.sleep(float(cfg["RETRY_DELAY"]))
    state, _ = probe(cfg, opener)
    return state == ONLINE


def handle_captive(cfg, probe_resp):
    """Gere un portail detecte : incident, tentatives, notification."""
    host = urllib.parse.urlparse(probe_resp.url).hostname or "?"
    log("PORTAIL DETECTE sur %s (%s)" % (host, probe_resp.url))
    prune_incidents(cfg)
    incident = Incident(host)
    incident.record("probe", probe_resp)
    log("incident: %s" % incident.dir)

    retries = int(cfg["RETRIES"])
    verdict = "echec"
    for attempt in range(1, retries + 1):
        log("tentative %d/%d" % (attempt, retries))
        incident.note("--- tentative %d/%d" % (attempt, retries))
        # Opener neuf a chaque essai : cookies et tokens repartent de zero.
        opener = make_opener(cfg)
        resp = probe_resp
        if attempt > 1:
            state, resp = probe(cfg, opener)
            if state == ONLINE:
                log("deja reconnecte entre-temps")
                verdict = "succes (hors tentative)"
                break
            if state == OFFLINE:
                log("reseau perdu, on abandonne cette passe")
                incident.note("reseau perdu: %s" % resp)
                verdict = "reseau perdu"
                break
            incident.record("probe-retry%d" % attempt, resp)
        else:
            # La premiere tentative rejoue la sonde pour avoir ses propres cookies.
            state, resp = probe(cfg, opener)
            if state != CAPTIVE:
                verdict = "succes (hors tentative)" if state == ONLINE else "reseau perdu"
                break
            incident.record("portal", resp)

        if attempt_login(cfg, opener, resp, incident):
            log("RECONNECTE (%s)" % host)
            notify(cfg, "Wi-Fi reconnecte", "Portail %s : session relancee." % host)
            verdict = "succes"
            break
        time.sleep(float(cfg["RETRY_DELAY"]))

    incident.close(verdict)
    if verdict.startswith("succes"):
        return True

    log("ECHEC (%s) sur %s — details: %s" % (verdict, host, incident.dir))
    notify(cfg, "Wi-Fi : reconnexion impossible",
           "Portail %s. Ouvre-le a la main. Details: %s" % (host, incident.dir))
    return False


def run_once(cfg):
    """Un seul cycle. Retourne l'etat observe."""
    opener = make_opener(cfg)
    state, resp = probe(cfg, opener)
    if state == ONLINE:
        log("en ligne")
    elif state == OFFLINE:
        log("hors ligne (%s)" % str(resp)[:200])
    else:
        handle_captive(cfg, resp)
    return state


def loop(cfg):
    """Boucle principale, avec backoff apres echec repete sur un meme portail."""
    interval = float(cfg["INTERVAL"])
    backoff = float(cfg["FAIL_BACKOFF"])
    last_state = None
    failed_until = 0.0
    log("watchdog demarre (interval=%ss, email=%s)"
        % (interval, cfg["EMAIL"] or "<non configure>"))

    while True:
        try:
            opener = make_opener(cfg)
            state, resp = probe(cfg, opener)

            if state == ONLINE:
                if last_state != ONLINE:
                    log("en ligne")
                failed_until = 0.0
            elif state == OFFLINE:
                if last_state != OFFLINE:
                    log("hors ligne, en attente d'un reseau (%s)" % str(resp)[:200])
            elif time.time() < failed_until:
                if last_state != CAPTIVE:
                    log("portail en echec, backoff jusqu'a %s"
                        % time.strftime("%H:%M:%S", time.localtime(failed_until)))
            elif not handle_captive(cfg, resp):
                failed_until = time.time() + backoff

            last_state = state
        except Exception as exc:  # le watchdog ne doit jamais mourir
            log("erreur inattendue: %r" % exc)
        time.sleep(interval)


def test_form(cfg, path):
    """Rejoue le parseur sur un dump sauvegarde, sans rien envoyer."""
    with open(path, encoding="utf-8") as fh:
        body = fh.read()
    parser = FormParser()
    parser.feed(body)
    print("titre: %r" % parser.title)
    print("meta-refresh: %r" % parser.meta_refresh)
    print("formulaires: %d" % len(parser.forms))
    for entry in form_digest(parser.forms):
        print("  [%(index)d] score=%(score)d auto=%(auto)s action=%(action)r "
              "method=%(method)s champs=%(fields)s" % entry)
    auto = next((f for f in parser.forms if is_auto_form(f)), None)
    if auto is not None:
        payload, _ = build_payload(auto, cfg)
        print("=> rebond auto detecte: action=%r payload=%s"
              % (auto["action"], urllib.parse.urlencode(payload)))
    form = pick_form(parser.forms)
    if form is None:
        print("=> aucun formulaire de login retenu")
        return 0 if auto is not None else 1
    payload, notes = build_payload(form, cfg)
    print("=> retenu: action=%r method=%s" % (form["action"], form["method"]))
    for note in notes:
        print("   note: %s" % note)
    print("=> payload: %s" % urllib.parse.urlencode(payload))
    return 0


def main():
    ap = argparse.ArgumentParser(description="Reconnexion auto aux portails captifs")
    ap.add_argument("--once", action="store_true", help="un seul cycle puis sortie")
    ap.add_argument("--test-form", metavar="FICHIER", help="parse un dump sans rien envoyer")
    args = ap.parse_args()

    os.makedirs(STATE_DIR, exist_ok=True)
    os.makedirs(DUMP_DIR, exist_ok=True)
    cfg = load_config()

    if args.test_form:
        return test_form(cfg, args.test_form)
    if not cfg["EMAIL"]:
        log("EMAIL non configure dans %s" % CONFIG_PATH)
        return 2
    if args.once:
        return 0 if run_once(cfg) == ONLINE else 1
    loop(cfg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
