#!/bin/sh
# Garde-fou : échoue si un fichier de l'index git contient une donnée personnelle.
# Lancé par .githooks/pre-commit et par la CI. Travaille sur l'index (--cached),
# c'est-à-dire exactement ce qui va être commité.
# Les motifs sont écrits de façon à ne jamais se reconnaître eux-mêmes.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2
status=0

# check <libellé> <ERE interdite> <ERE des correspondances tolérées>
# La sortie de git grep -o est « fichier:ligne:correspondance » : les motifs
# tolérés s'ancrent donc sur la fin de ligne.
check() {
  hits=$(git grep --cached -I -n -o -E -e "$2" -- . 2>/dev/null | /usr/bin/sed -E "/$3/d")
  if [ -n "$hits" ]; then
    printf '✗ %s :\n%s\n' "$1" "$hits" >&2
    status=1
  fi
}

check "adresse IPv4 privée" \
  '(^|[^0-9.])(10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]{1,3}\.[0-9]{1,3}($|[^0-9])' '^$'
check "adresse e-mail" '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
  '@(example\.(com|org|net)|users\.noreply\.github\.com|anthropic\.com)$'
check "adresse MAC" '[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}' ':00(:00){5}$'
check "MAC en paramètre" '(mac|Calling-Station-Id|Called-Station-Id)=[0-9A-Fa-f]{12}' '=0{12}$'
check "identifiant de session généré" '[0-9A-F]{12}_[0-9]{10}' ':0{12}_[0-9]{10}$'
check "NAS-ID" 'NAS-ID=[0-9A-Fa-f]+-[0-9A-Fa-f]+' '=0+-0+$'
check "identifiant d'hôtel" '(hotelid(=|%3[dD])|bb_)[0-9]+' '(=|%3[dD]|bb_)0+$'
check "jeton CSRF" 'csrf_token.{0,40}value="[A-Za-z0-9+/=]{16,}"' '^$'
check "script analytics" 'go-mpuls[e]|BOOM[R]' '^$'

if [ -f .scrub-local ]; then
  pat=$(mktemp)
  /usr/bin/sed '/^[[:space:]]*$/d' .scrub-local > "$pat"
  if [ -s "$pat" ]; then
    hits=$(git grep --cached -I -n -i -F -f "$pat" -- . 2>/dev/null)
    if [ -n "$hits" ]; then
      printf '✗ littéral de .scrub-local :\n%s\n' "$hits" >&2
      status=1
    fi
  fi
  rm -f "$pat"
fi

[ $status -eq 0 ] && echo "✓ anonymat : aucun motif personnel dans l'index"
exit $status
