# captive-watchdog — design

Date : 2026-09-23
Statut : proposé, en attente de relecture

## 1. Objectif

Reconnecter automatiquement un Mac aux portails captifs Wi-Fi (hôtels, B&B,
lieux publics) dont la session expire périodiquement, sans intervention et sans
navigateur. Le premier réseau ciblé est B&B Hotels (opérateur Wifirst) ;
l'architecture doit rendre l'ajout d'un nouveau réseau trivial.

Utilisateur : un seul, sur son Mac portable. Le projet est publié en open source
parce que le problème est banal et l'outillage existant, inexistant ou abandonné.

## 2. Acquis à préserver

Une v1 Python (`legacy/wifi-watchdog.py`) a réussi une reconnexion
réelle le 2026-09-23, en 6 secondes. Elle a permis d'établir des
faits que la v2 doit conserver :

- Le client est identifié par la passerelle via MAC + IP. Aucun jeton privilégié
  n'est attaché à la fenêtre CNA (Captive Network Assistant) de macOS : la page
  servie est identique octet pour octet avec l'User-Agent du CNA et celui de
  Safari. Un POST émis par n'importe quel process de la machine est donc
  équivalent.
- Le login B&B se fait en **deux POST**. Le second, vers un formulaire caché
  auto-soumis par JavaScript, est celui qui ouvre réellement l'accès. Un moteur
  qui s'arrête au premier produit un faux succès.
- Le portail suit `Accept-Language` : la valeur du bouton de soumission change
  selon la langue. Rien ne doit être codé en dur.
- Les jetons (`csrf_token` + cookie de session) sont émis au GET et consommés au
  POST dans une fenêtre courte. GET et POST doivent partager la même connexion.
- Les cases à cocher ne sont pas toutes des CGU : certaines sont des opt-ins
  marketing qu'il faut laisser décochées.
- Plusieurs boutons de soumission peuvent coexister ; un navigateur n'en envoie
  qu'un. En envoyer deux change le parcours côté serveur.

Ces faits sont la raison d'être de la suite de tests : ils ont tous été trouvés
en observant le vrai portail, pas en le devinant.

## 3. Portée

Dans le périmètre : détection de captivité, résolution de profil, remplissage et
soumission du formulaire, enchaînement des rebonds, vérification, journalisation
par incident, app menubar, CLI, distribution Homebrew, publication du dépôt.

Hors périmètre : portails exigeant une authentification réelle (compte, SMS,
paiement), portails purement JavaScript sans formulaire HTML, iOS, contournement
de quota (changement de MAC, multi-comptes).

## 4. Architecture

Un paquet SwiftPM, trois cibles :

- `CaptiveKit` — bibliothèque : moteur, parseur HTML, profils, stockage. Aucune
  dépendance externe.
- `captive-watchdog` — exécutable CLI : mode démon headless et commandes de
  debug. Fine enveloppe autour de `CaptiveKit`, qui porte les tests.
- `CaptiveWatchdogApp` — app menubar (`LSUIElement`, pas d'icône Dock), lancée
  au login par un LaunchAgent. Elle héberge le moteur.

**Un seul processus actif.** L'app contient le moteur ; il n'y a ni démon séparé
ni IPC. Un verrou d'instance (fichier verrouillé dans le répertoire de support)
garantit que le CLI et l'app ne tournent jamais ensemble : le CLI refuse de
démarrer en mode démon si l'app tourne, sauf `--force`.

Justification : l'IPC était la seule complexité qu'apportait l'option
démon + UI, pour aucun bénéfice — l'app doit de toute façon tourner en
permanence pour afficher un statut.

### Modules de CaptiveKit

| Module | Responsabilité | Dépend de |
|---|---|---|
| `Prober` | détecte en ligne / captif / hors ligne | `HTTPClient` |
| `HTMLScanner` | tokenise formulaires, champs, `<base href>`, `meta refresh`, titre | — |
| `ProfileStore` | charge, valide, ordonne les profils | — |
| `FormFiller` | choisit le formulaire, construit le payload | `HTMLScanner`, `Profile` |
| `LoginSession` | orchestre GET → POST → rebonds → vérification | tous |
| `IncidentRecorder` | dossier de post-mortem par portail | — |
| `StateStore` | statut courant, dernier renouvellement, historique | — |

Chaque module est testable seul : `FormFiller` prend du HTML et un profil et
rend un payload, sans réseau.

## 5. Modèle de profil

Un profil décrit **comment un réseau dévie du comportement générique**. Toutes
les clés sont optionnelles ; ce qui manque est déduit par l'heuristique.

```json
{
  "id": "bnb-hotels",
  "name": "B&B Hotels (Wifirst)",
  "match": {
    "portalHost": "moveon-hotelbb\\.com$",
    "ssid": "^BBHOTELS"
  },
  "form": {
    "action": "wifi-access\\.php",
    "fields": { "email": "email" },
    "checkboxes": { "check": ["chartConsent"], "skip": ["optinEmail"] },
    "submit": "connect"
  },
  "chain": { "maxHops": 4, "expectHosts": ["redirect-wifi.moveon-hotelbb.com"] }
}
```

**Le SSID n'est pas toujours lisible.** Depuis macOS 26, le système masque le
SSID à tout process dépourvu d'autorisation de Localisation, et la liste des
réseaux connus est réservée à root. Une app peut demander cette autorisation,
contrairement à un script lancé par launchd — c'est un bénéfice concret de
l'architecture retenue. Mais l'autorisation peut être refusée : `match.ssid`
est donc un critère **facultatif**, ignoré quand le SSID est indisponible.
`match.portalHost` reste le critère principal, et il suffit.

Résolution : les profils sont testés par spécificité décroissante (un `match`
plus contraint gagne) ; le profil `generic` intégré s'applique en dernier
recours. Les profils livrés avec l'application sont surchargeables : un profil
utilisateur portant le même `id` le remplace intégralement. **Un réseau inconnu doit fonctionner sans profil** — c'est le cas
nominal, pas le cas dégradé : le générique a suffi pour B&B avant qu'un profil
n'existe.

L'heuristique générique conserve les règles éprouvées en v1 : score de
formulaire (champ email +5, case +2, caché +1, soumission +2 ; formulaires de
recherche exclus), détection du champ email par type puis par indice de nom,
cases à cocher cochées sauf motif marketing, un seul bouton de soumission choisi
par préférence, rejeu verbatim des champs cachés.

`captive-watchdog profile learn <dump.html>` produit un squelette de profil à
partir d'une page capturée : c'est le chemin nominal pour ajouter un réseau.

## 6. Séquence du moteur

1. Sonder `http://captive.apple.com/hotspot-detect.html` toutes les N secondes.
   Réponse `Success` → en ligne. Échec réseau → hors ligne. Autre → captif.
2. Ouvrir un incident, enregistrer la sonde et la chaîne de redirection.
3. Résoudre le profil à partir de l'hôte du portail, et du SSID s'il est lisible.
4. GET du portail (même session HTTP que la suite), parser, choisir le
   formulaire, construire le payload.
5. POST. Les URL relatives sont résolues contre `<base href>` si présent, comme
   le fait un navigateur.
6. Enchaîner les rebonds : tout formulaire composé uniquement de champs cachés
   est rejoué automatiquement ; `meta refresh` suivi. Plafond configurable.
7. Re-sonder. Succès → horodater le renouvellement, notifier, clore l'incident.
   Échec → réessayer (N fois), puis backoff et notification d'échec.

## 7. Stockage

| Quoi | Chemin |
|---|---|
| Config | `~/Library/Application Support/CaptiveWatchdog/config.json` |
| État | `…/state.json` |
| Historique | `…/history.jsonl` |
| Profils utilisateur | `…/profiles/*.json` |
| Incidents | `…/incidents/<ts>-<host>/` |
| Journal | `~/Library/Logs/CaptiveWatchdog/watchdog.log` |

`config.json` porte l'identité utilisée pour les formulaires (adresse e-mail,
mot de passe optionnel), l'intervalle de sonde, le nombre de tentatives et le
backoff, le plafond de rebonds, le nombre d'incidents conservés et l'activation
des notifications.

Un incident contient `meta.json` (verdict, formulaires vus et leurs scores,
payloads envoyés, notes) et, par étape, le corps HTML et un JSON de
statut/en-têtes/redirections. La purge garde les N derniers incidents et
s'exécute **avant** d'en ouvrir un nouveau, jamais pendant : le premier dump d'un
incident en cours ne peut pas être évincé.

`history.jsonl` est append-only : un objet par événement de session (réseau,
début, fin, durée, verdict). C'est la source de la vue Historique.

## 8. App menubar

- Icône d'état : en ligne / captif / hors ligne.
- Dernier renouvellement, en temps relatif et absolu.
- **Reconnecter maintenant** : force une passe de login immédiate.
- Ouvrir le journal ; révéler le dernier incident dans le Finder.
- Fenêtre Historique : sessions récentes (réseau, début, durée, verdict).
- Éditeur de profils : liste, édition, import/export, et test à blanc d'un
  profil contre un dump sauvegardé (affiche le payload qui serait envoyé, sans
  rien émettre).

## 9. CLI

`run` (démon), `run --once`, `status`, `reconnect`, `logs`, `incidents`,
`profile list|learn|test`, `install-agent`, `uninstall-agent`.

## 10. Anonymisation et confidentialité

Les fixtures sont de vraies pages de portail, ce qui fait leur valeur. Elles
doivent être lavées avant publication : jeton CSRF, identifiants générés,
adresse MAC, adresses IP, identifiant de session, identifiant et ville de
l'hôtel, adresse e-mail. `Scripts/scrub.sh` applique ces substitutions.

Un garde-fou CI fait **échouer le build** si un commit contient un de ces
motifs. C'est la protection réelle ; le script n'est qu'une commodité.

La configuration utilisateur (adresse e-mail) vit hors du dépôt, dans le
répertoire de support, et n'est jamais journalisée en clair dans un incident
destiné au partage.

Commits et dépôt sous `CorentinGC@users.noreply.github.com`.

## 11. Distribution

Dépôt **privé** jusqu'au premier release, puis public. Une fuite poussée sur un
dépôt public survit dans les forks et les caches, donc la bascule n'intervient
qu'après relecture humaine de l'anonymisation.

`brew install corentingc/tap/captive-watchdog` : la formule compile en release,
installe le CLI dans `bin`, l'app dans le préfixe, et documente
`captive-watchdog install-agent` pour poser le LaunchAgent.

CI GitHub Actions sur `macos-latest` : build, tests, garde-fou d'anonymisation.

## 12. Tests

Les faits de la section 2 deviennent des tests. Sur les fixtures B&B
anonymisées :

- le jeton CSRF est rejoué à l'identique ;
- l'adresse e-mail atterrit dans le champ attendu ;
- la case de consentement est cochée, l'opt-in marketing ne l'est pas ;
- un seul bouton de soumission est envoyé, et c'est le bon ;
- le bouton hors formulaire n'est jamais envoyé ;
- le formulaire caché de second niveau est détecté et rejoué verbatim ;
- `<base href>` est honoré quand le portail est servi sans redirection ;
- les cookies sont conservés entre le GET et les deux POST.

Les requêtes sont stubées via `URLProtocol` : aucun accès réseau en CI, aucune
dépendance. Des fixtures synthétiques couvrent les variantes non rencontrées
(champ sans indice de nom, boutons multiples, chaîne de `meta refresh`).

## 13. Bascule depuis la v1

La v1 Python reste active jusqu'à ce que la v2 ait réussi une coupure réelle.
Deux moteurs simultanés se disputeraient le même portail, donc
`install-agent` désactive l'agent Python. Le script v1 est archivé dans
`legacy/` : c'est la référence qui a servi à écrire les tests.

## 14. Risques

- **Portails purement JavaScript.** Hors périmètre, mais le moteur doit le
  détecter et le dire clairement plutôt que d'échouer en silence.
- **Dérive du portail B&B.** Les fixtures figent un instantané ; une refonte du
  portail les rend obsolètes. L'incident enregistré donne de quoi les
  rafraîchir.
- **Notarisation.** Une app non signée distribuée en `.zip` est bloquée par
  Gatekeeper. Homebrew compilant depuis les sources, le problème ne se pose pas
  pour le chemin d'installation retenu ; il se poserait pour une distribution
  `.dmg` ultérieure.
- **Faux positif de captivité.** Un réseau qui casse la sonde Apple sans être
  captif déclencherait des tentatives inutiles. Le backoff les borne.

## 15. Découpage

Le périmètre dépasse un seul plan d'implémentation confortable. Trois phases,
chacune livrable et vérifiable seule :

1. **Noyau et CLI** — `CaptiveKit` + `captive-watchdog`, parité fonctionnelle
   avec la v1 Python, suite de tests complète sur fixtures réelles. Critère de
   sortie : une coupure réelle rattrapée par le CLI seul.
2. **App menubar** — statut, dernier renouvellement, reconnexion manuelle,
   logs et incidents, historique, éditeur de profils. Critère de sortie :
   l'agent Python est désinstallé et l'app assure le service.
3. **Distribution** — formule Homebrew, CI, garde-fou d'anonymisation,
   README, bascule du dépôt en public.

## 16. Critères d'acceptation

1. `swift build` et `swift test` passent sur une machine neuve, sans dépendance
   hors toolchain Apple.
2. Tous les tests de la section 12 passent.
3. Une coupure réelle sur le réseau B&B est rattrapée par la v2 seule, en moins
   de 30 secondes, et l'événement apparaît dans l'historique du menubar.
4. Ajouter un réseau inconnu ne demande aucun code : soit le générique suffit,
   soit `profile learn` produit un profil qui suffit.
5. Le garde-fou CI rejette un commit contenant un motif personnel.
6. `brew install` depuis le tap produit une installation fonctionnelle.
