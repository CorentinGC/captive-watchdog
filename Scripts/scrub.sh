#!/bin/sh
# Lave une page de portail capturée avant de l'ajouter aux fixtures.
# Usage : Scripts/scrub.sh <entrée.html> <sortie.html>
# Les motifs génériques sont complétés par les littéraux de .scrub-local
# (un par ligne, jamais versionné) : adresse e-mail, adresse MAC, etc.
set -eu
[ $# -eq 2 ] || { echo "usage: $0 <entrée.html> <sortie.html>" >&2; exit 64; }
in=$1
out=$2
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp)
trap 'rm -f "$tmp" "$tmp.2"' EXIT

/usr/bin/sed -E \
  -e 's#<script>!function\(e\)\{var n="https://s[0-9]*\.go-mpuls[e]\.net/boomerang/.*</script>#<!-- analytics script removed -->#' \
  -e 's#(name="csrf_token"[^>]*value=")[^"]*"#\1CSRF_TOKEN_PLACEHOLDER"#g' \
  -e 's#(name="username"[^>]*value=")[^"]*"#\1000000000000_1700000000"#g' \
  -e 's#(name="password"[^>]*value=")[^"]*"#\1000000000000"#g' \
  -e 's#([?&;]url=)[0-9A-Fa-f]{16,}#\1ENCRYPTED_URL_PLACEHOLDER#g' \
  -e 's#((mac|Calling-Station-Id|Called-Station-Id)=)[0-9A-Fa-f]{12}#\1000000000000#g' \
  -e 's#(NAS-ID=)[0-9A-Fa-f]+-[0-9A-Fa-f]+#\10000-000000#g' \
  -e 's#(hotelid(=|%3[dD]))[0-9]+#\10000#g' \
  -e 's#bb_[0-9]+#bb_0000#g' \
  -e 's#(random=)[0-9A-Fa-f]+#\1RANDOM_PLACEHOLDER#g' \
  -e 's#[[:<:]](10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]{1,3}\.[0-9]{1,3}[[:>:]]#192.0.2.1#g' \
  -e 's#[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}#00:00:00:00:00:00#g' \
  -e 's#[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}#guest@example.com#g' \
  "$in" > "$tmp"

if [ -f "$root/.scrub-local" ]; then
  while IFS= read -r lit || [ -n "$lit" ]; do
    [ -n "$lit" ] || continue
    esc=$(printf '%s' "$lit" | /usr/bin/sed 's/[][\.*^$/&]/\\&/g')
    /usr/bin/sed "s/$esc/REDACTED/Ig" "$tmp" > "$tmp.2"
    mv "$tmp.2" "$tmp"
  done < "$root/.scrub-local"
fi
mv "$tmp" "$out"
