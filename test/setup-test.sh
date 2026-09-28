#!/bin/bash
#
# End-to-end tests for ./setup, the one-command install.
#
# This is the script nobody runs twice on the same machine, which is how it
# shipped with a hole in it: a failed `omarchy plugin add` ended the run through
# set -e, so a desktop could come out with panels installed and no catalog --
# every panel string back in English, and the only symptom being English text.
# The developers' own machines were assembled by hand and never showed it.
#
# So setup runs here against a throwaway HOME with `omarchy` and `localectl`
# stubbed on PATH: no plugin is fetched, no system locale is touched, and the
# assertions are about what lands in HOME.
#
# Usage: test/setup-test.sh      (needs bash and jq; nothing else)

set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
failures=0

ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; failures=$((failures + 1)); }
check() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: got '$2', want '$3'"; fi; }

# A fake Omarchy: `plugin add` installs from the working tree rather than from
# git, which is also what keeps the test offline. PANEL_FAIL names one repo whose
# install fails, standing in for an unreachable or not-yet-published fork.
make_stubs() {
  local bin=$1
  mkdir -p "$bin"
  cat > "$bin/omarchy" <<'STUB'
#!/bin/bash
set -uo pipefail
case "${1:-} ${2:-}" in
  "plugin add")
    repo=$3
    [[ -n ${PANEL_FAIL:-} && $repo == *"$PANEL_FAIL"* ]] && { echo "stub: $repo unreachable" >&2; exit 1; }
    name=$(basename "$repo" .git)
    if [[ $name == omarchy-language ]]; then
      id=$(jq -r .id "$STUB_REPO/manifest.json")
      mkdir -p "$HOME/.config/omarchy/plugins/$id"
      # tar rather than cp -r: the working tree carries .git, and copying that
      # into every fixture would be most of the run's time for nothing.
      tar -c --exclude=.git --exclude=.github -C "$STUB_REPO" . |
        tar -x -C "$HOME/.config/omarchy/plugins/$id"
    else
      # The forks are not under test here; an empty folder is enough to stand
      # for "installed", which is all setup looks at. omarchy-system-update-l10n
      # installs as sbelcl.system-update, so the id is the middle of the name.
      id="sbelcl.${name#omarchy-}"; id="${id%-l10n}"
      mkdir -p "$HOME/.config/omarchy/plugins/$id"
    fi
    ;;
  "plugin update") ;;
  "plugin validate") ;;
  "plugin list") ;;
  *) echo "stub: unhandled '$*'" >&2; exit 64 ;;
esac
STUB
  cat > "$bin/localectl" <<'STUB'
#!/bin/bash
# status reports the locale LOCALECTL_CURRENT says, and set-locale fails when
# LOCALECTL_FAIL is set -- a cancelled password prompt.
case "${1:-}" in
  status) echo "System Locale: LANG=${LOCALECTL_CURRENT:-en_US.UTF-8}" ;;
  set-locale) [[ -n ${LOCALECTL_FAIL:-} ]] && exit 1 ;;
esac
exit 0
STUB
  chmod +x "$bin/omarchy" "$bin/localectl"
}

# One setup run in its own HOME. Echoes the exit status, leaves the tree behind
# for the assertions, and prints the output only when something is wrong.
run_setup() {
  local home=$1; shift
  mkdir -p "$home"
  printf 'sl_SI.UTF-8 UTF-8\nru_RU.UTF-8 UTF-8\n' > "$home/SUPPORTED"
  ( export HOME="$home" STUB_REPO="$REPO" \
      PATH="$home/bin:$PATH" LOCALE_SUPPORTED="$home/SUPPORTED"
    make_stubs "$home/bin"
    cd "$REPO" && ./setup "$@" > "$home/out.txt" 2>&1 )
  echo $?
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- the happy path, which is also the one that was never tested -------------

echo "setup installs the catalog the panels read"
status=$(run_setup "$tmp/clean" sl_SI.UTF-8 --with-panels --no-menu)
check "exits 0" "$status" "0"
if [[ -f "$tmp/clean/.config/omarchy/locales/sl.json" ]]; then
  ok "catalog landed at ~/.config/omarchy/locales/sl.json"
  check "catalog is the shipped one" \
    "$(jq 'length' "$tmp/clean/.config/omarchy/locales/sl.json")" \
    "$(jq 'length' "$REPO/locales/sl.json")"
else
  bad "catalog landed at ~/.config/omarchy/locales/sl.json"
  sed 's/^/      /' "$tmp/clean/out.txt"
fi
[[ -d "$tmp/clean/.config/omarchy/plugins/sbelcl.reminders" ]] &&
  ok "panels installed" || bad "panels installed"

# --- a fork that cannot be fetched must not cost the catalog -----------------

echo "a panel that fails to install does not take the catalog with it"
# Exported rather than prefixed onto the call: bash does not pass a variable
# assignment that precedes a *function* name down to that function's children,
# which is where the stub reads it.
export PANEL_FAIL=omarchy-tray-l10n
status=$(run_setup "$tmp/panelfail" sl_SI.UTF-8 --with-panels --no-menu)
unset PANEL_FAIL
check "exits non-zero" "$((status != 0))" "1"
[[ -f "$tmp/panelfail/.config/omarchy/locales/sl.json" ]] &&
  ok "catalog installed anyway" || bad "catalog installed anyway"
grep -q "omarchy-tray-l10n" "$tmp/panelfail/out.txt" &&
  ok "names the panel it could not install" || bad "names the panel it could not install"
grep -q "Done, except for" "$tmp/panelfail/out.txt" &&
  ok "reports the run as partial" || bad "reports the run as partial"

# --- a cancelled password prompt is not the end of the run ------------------

echo "a refused localectl leaves the rest of the install standing"
export LOCALECTL_FAIL=1
status=$(run_setup "$tmp/localefail" sl_SI.UTF-8 --no-menu)
unset LOCALECTL_FAIL
check "exits non-zero" "$((status != 0))" "1"
[[ -f "$tmp/localefail/.config/omarchy/locales/sl.json" ]] &&
  ok "catalog installed anyway" || bad "catalog installed anyway"
grep -q "set the system language" "$tmp/localefail/out.txt" &&
  ok "says the language was not set" || bad "says the language was not set"

# --- a language with no catalog is not a failure ----------------------------

echo "a language the repo has no catalog for is reported, not failed"
export LOCALECTL_CURRENT=de_DE.UTF-8
status=$(run_setup "$tmp/nocat" de_DE.UTF-8 --no-menu)
unset LOCALECTL_CURRENT
check "refuses a locale glibc does not list" "$((status != 0))" "1"
grep -q "SUPPORTED" "$tmp/nocat/out.txt" &&
  ok "says why" || bad "says why"

# --- idempotence -------------------------------------------------------------

echo "a second run changes nothing"
before=$(jq -S . "$tmp/clean/.config/omarchy/locales/sl.json")
status=$(run_setup "$tmp/clean" sl_SI.UTF-8 --with-panels --no-menu)
check "exits 0" "$status" "0"
check "catalog untouched" "$(jq -S . "$tmp/clean/.config/omarchy/locales/sl.json")" "$before"

echo
if (( failures )); then
  echo "$failures failing"
  exit 1
fi
echo "setup ok"
