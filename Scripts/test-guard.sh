#!/bin/sh
# Auto-test du garde-fou : chaque fuite plantée doit faire échouer
# check-anonymity.sh, les valeurs lavées doivent passer. Les fuites sont
# assemblées à l'exécution pour que ce fichier reste lui-même propre.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

# run_case <pass|fail> <libellé> <contenu> [<littéral .scrub-local>]
run_case() {
  rm -rf "$work/repo"
  mkdir -p "$work/repo/Scripts"
  cp "$root/Scripts/check-anonymity.sh" "$work/repo/Scripts/"
  (cd "$work/repo" && git init -q && printf '%s\n' "$3" > sample.txt && git add .)
  [ $# -lt 4 ] || printf '%s\n' "$4" > "$work/repo/.scrub-local"
  if (cd "$work/repo" && sh Scripts/check-anonymity.sh >/dev/null 2>&1); then got=pass; else got=fail; fi
  if [ "$got" = "$1" ]; then echo "ok   $2"; else echo "FAIL $2 (attendu $1, obtenu $got)"; fail=1; fi
}

at=@; ten=10; c=168; m=aa:bb:cc; h6=abcdef; H6=ABCDEF; n4=1234; r=R
b64=QUJDREVGR0hJSktMTU5PUFFSU1RVVldY

run_case pass "valeurs lavées" "ip 192.0.2.1 1.1.1.1 guest${at}example.com mac=000000000000 00:00:00:00:00:00 NAS-ID=0000-000000 hotelid=0000 bb_0000 000000000000_1700000000"
run_case pass "IP publique voisine" "version 1${ten}.1.2.3"
run_case fail "IP privée 10/8" "sta ${ten}.20.30.40"
run_case fail "IP privée 192.168/16" "gw 192.${c}.1.1"
run_case fail "e-mail" "contact bob${at}corp.fr"
run_case fail "MAC" "${m}:dd:ee:ff"
run_case fail "MAC en paramètre" "mac=${h6}${h6}"
run_case fail "identifiant généré" "${H6}${H6}_1790000000"
run_case fail "NAS-ID" "NAS-ID=${n4}-${h6}"
run_case fail "hotelid" "hotelid=${n4}"
run_case fail "bb_NNNN" "https://notre.guide/bb_${n4}"
run_case fail "jeton CSRF" "<input name=\"csrf_token\" value=\"${b64}\">"
run_case fail "script analytics" "window.BOOM${r}_config"
run_case fail "littéral local" "Bonjour HUNTER-SECRET-TOKEN" "hunter-secret-token"
exit $fail
