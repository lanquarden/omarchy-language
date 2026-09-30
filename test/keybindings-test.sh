#!/bin/bash
#
# Tests for menu-keybindings, the Super+K menu in the system language.
#
# Omarchy's omarchy-menu-keybindings and omarchy-menu-select are stubbed on
# PATH: the stub menu shows fixed rows and picks one, and the stub keybindings
# script prints what it would have dispatched. What is under test is the part
# in between -- that the rows reach the menu translated and the pick comes back
# as the English row the real script knows how to dispatch.
#
# Usage: test/keybindings-test.sh      (needs bash and awk; nothing else)

set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
failures=0

ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; failures=$((failures + 1)); }
check() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: got '$2', want '$3'"; fi; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# The rows as omarchy-menu-keybindings hands them to the menu: the key combo
# padded to 35, an arrow, the description.
cat > "$tmp/bin/omarchy-menu-keybindings" <<'STUB'
#!/bin/bash
records='SUPER + K                           → Keybindings
SUPER + 3                           → Switch to workspace 3
SUPER + PRINT                       → Screenshot
SUPER SHIFT + N                     → Signal'
picked=$(printf '%s\n' "$records" | omarchy-menu-select 'Keybindings' -- --width 800 --height 500)
echo "DISPATCH $picked"
STUB

# Shows nothing; records what it was given, and picks the row matching PICK.
cat > "$tmp/bin/omarchy-menu-select" <<'STUB'
#!/bin/bash
echo "$1" > "$SHOWN.prompt"
cat > "$SHOWN"
grep -m1 -F -- "$PICK" "$SHOWN"
STUB
chmod +x "$tmp/bin/"*

run() {
  PICK=$1 LANG=$2 SHOWN="$tmp/shown" PATH="$tmp/bin:$PATH" "$REPO/menu-keybindings"
}

echo "rows reach the menu in the system language"
out=$(run "Zaslonska slika" sl_SI.UTF-8)
check "prompt translated" "$(cat "$tmp/shown.prompt")" "Bližnjice"
check "description translated" "$(sed -n 3p "$tmp/shown" | sed 's/.*→ //')" "Zaslonska slika"
check "key combo untouched" "$(sed -n 3p "$tmp/shown" | sed 's/ *→.*//')" "SUPER + PRINT"
check "trailing number carried over" "$(sed -n 2p "$tmp/shown" | sed 's/.*→ //')" \
  "Preklopi na delovno površino 3"
check "a name not in the table stays" "$(sed -n 4p "$tmp/shown" | sed 's/.*→ //')" "Signal"

echo "the pick comes back as the English row"
check "plain row" "$out" "DISPATCH SUPER + PRINT                       → Screenshot"
out=$(run "delovno površino 3" sl_SI.UTF-8)
check "numbered row" "$out" "DISPATCH SUPER + 3                           → Switch to workspace 3"
out=$(run "nothing matches this" sl_SI.UTF-8)
check "a cancelled menu picks nothing" "$out" "DISPATCH "
ls "${XDG_RUNTIME_DIR:-/tmp}"/menu-keybindings.* >/dev/null 2>&1 &&
  bad "leaves no temp file behind" || ok "leaves no temp file behind"

echo "a language with no table is Omarchy's menu, unchanged"
out=$(run "Screenshot" de_DE.UTF-8)
check "prompt English" "$(cat "$tmp/shown.prompt")" "Keybindings"
check "rows English" "$(sed -n 3p "$tmp/shown" | sed 's/.*→ //')" "Screenshot"
check "pick passes through" "$out" "DISPATCH SUPER + PRINT                       → Screenshot"

echo "bind and unbind leave the rest of bindings.lua alone"
cat > "$tmp/bindings.lua" <<'LUA'
-- Keep only your personal keybinding overrides here.
o.bind("SUPER + SHIFT + R", "SSH", "alacritty -e ssh your-server")
LUA
cp "$tmp/bindings.lua" "$tmp/original.lua"
export HYPR_BINDINGS="$tmp/bindings.lua"
"$REPO/menu-keybindings" bind >/dev/null
check "block added" "$(grep -c 'o.bind("SUPER + K", "Keybindings", path)' "$tmp/bindings.lua")" "1"
check "unbinds Omarchy's first" "$(grep -c 'hl.unbind("SUPER + K")' "$tmp/bindings.lua")" "1"
check "status says bound" "$("$REPO/menu-keybindings" status | cut -d' ' -f1)" "bound=yes"
first=$(cat "$tmp/bindings.lua")
"$REPO/menu-keybindings" bind >/dev/null
check "a second bind changes nothing" "$(cat "$tmp/bindings.lua")" "$first"
"$REPO/menu-keybindings" unbind >/dev/null
check "unbind restores the file exactly" "$(cat "$tmp/bindings.lua")" "$(cat "$tmp/original.lua")"
check "status says unbound" "$("$REPO/menu-keybindings" status | cut -d' ' -f1)" "bound=no"
unset HYPR_BINDINGS

echo
if (( failures )); then
  echo "$failures failing"
  exit 1
fi
echo "keybindings ok"
