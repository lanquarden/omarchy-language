#!/bin/bash
#
# Validate the translation data: the menu tables under translations/ and the
# panel catalogs under locales/.
#
# The data is copied verbatim into a running shell -- menu-translate pastes
# whole rows into the user's JSONC, and the catalogs are read by the forked
# panels -- so a malformed row shows up as a blank menu entry or an untranslated
# panel rather than an error. These are the checks that would have caught the
# damage: shape, duplicates, and the placeholders a translation has to carry
# over from its English key.
#
# It deliberately does not require every language to have every key. A menu
# table is allowed to translate more rows than another (ru_RU carries Shell and
# Stable, which sl_SI does not), and a missing row simply stays English.
#
# Usage: tools/check-translations.sh

set -euo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."

status=0

fail() {
  echo "  FAIL: $*" >&2
  status=1
}

# --- menu tables -----------------------------------------------------------

# Keyed by the English string, one "English<TAB>translation" per line, with
# # comments and blank lines ignored. Anything else is a row that menu-translate
# would copy into the menu half-formed.
for table in translations/*.tsv; do
  rows=$(grep -vc '^[[:space:]]*\(#\|$\)' "$table" || true)
  echo "$table: $rows rows"

  if grep -q $'\r' "$table"; then
    fail "$table has CRLF line endings"
  fi

  bad=$(awk -F'\t' '
    /^[[:space:]]*(#|$)/ { next }
    NF != 2                  { print "line " NR ": " NF " fields, want 2"; next }
    $1 == "" || $2 == ""     { print "line " NR ": empty field" }
    $1 ~ /^[[:space:]]|[[:space:]]$/ || $2 ~ /^[[:space:]]|[[:space:]]$/ {
                               print "line " NR ": leading or trailing space" }
    $1 ~ /%1/ && $2 !~ /%1/  { print "line " NR ": translation drops %1: " $1 }
  ' "$table")
  [ -z "$bad" ] || fail "$table: $(echo "$bad" | tr '\n' ';')"

  # A duplicate key is the quiet one: the table still parses, and whichever row
  # loses is simply never applied.
  dupes=$(grep -v '^[[:space:]]*\(#\|$\)' "$table" | cut -f1 | sort | uniq -d)
  [ -z "$dupes" ] || fail "$table has duplicate keys: $(echo "$dupes" | tr '\n' ' ')"
done

# --- panel catalogs --------------------------------------------------------

# The catalogs are not required to agree on keys, for the same reason the menu
# tables are not: a language may carry a string the others have not reached yet,
# and a key a catalog lacks simply stays English there. Holding them in lockstep
# would mean every new string waits for all three native speakers. Coverage is
# reported against the reference so the gap stays visible, but only malformed
# data fails the run.
reference=locales/sl.json

for catalog in locales/*.json; do
  if ! jq empty "$catalog" 2>/dev/null; then
    fail "$catalog is not valid JSON"
    continue
  fi

  echo "$catalog: $(jq 'length' "$catalog") keys"

  [ "$(jq '[..|strings|select(. == "")]|length' "$catalog")" = 0 ] ||
    fail "$catalog has empty translations"

  if [ "$catalog" != "$reference" ]; then
    missing=$(jq -r -n --slurpfile r "$reference" --slurpfile c "$catalog" \
      '($r[0]|keys) - ($c[0]|keys) | join(" ")')
    extra=$(jq -r -n --slurpfile r "$reference" --slurpfile c "$catalog" \
      '($c[0]|keys) - ($r[0]|keys) | join(" ")')
    [ -z "$missing" ] || echo "  note: not in $catalog, stays English: $missing"
    [ -z "$extra" ] || echo "  note: ahead of $reference: $extra"
  fi

  # %1 is substituted by the caller; a translation that drops it loses the
  # number or name the string was built around.
  dropped=$(jq -r 'to_entries[]
    | select(.key | test("%1"))
    | select([.value | ..| strings] | map(test("%1")) | all | not)
    | .key' "$catalog")
  [ -z "$dropped" ] || fail "$catalog drops %1 in: $(echo "$dropped" | tr '\n' ' ')"
done

[ $status = 0 ] && echo "translations ok"
exit $status
