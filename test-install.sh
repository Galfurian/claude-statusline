#!/usr/bin/env bash
# Tests for install.sh. Never touches the real HOME and never uses the network:
# every case runs against a temp HOME with the payload injected from disk.
INSTALLER="${1:-$(dirname "$0")/install.sh}"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; printf '    got: %q\n' "$2"; }
eq()   { [[ "$2" == "$3" ]] && ok || bad "$1 — expected '$3'" "$2"; }
has()    { [[ "$2" == *"$3"* ]] && ok || bad "$1 — expected to contain: $3" "$2"; }
hasnot() { [[ "$2" != *"$3"* ]] && ok || bad "$1 — expected NOT to contain: $3" "$2"; }

setup() {
    FAKE=$(mktemp -d)
    mkdir -p "$FAKE/.claude"
    PAYLOAD="$REPO_DIR/statusline.sh"
}
teardown() { rm -rf "$FAKE"; }

# Runs the installer with a fake HOME and the payload taken from disk.
installer() {
    HOME="$FAKE" STATUSLINE_PAYLOAD_FILE="$PAYLOAD" bash "$INSTALLER" "$@" 2>&1
}

echo "== install.sh tests =="

# --- preflight and arguments -------------------------------------------
setup
has "args/--version prints the version" "$(installer --version)" "v"
installer --version >/dev/null; eq "args/--version exits 0" "$?" "0"
has "args/--help mentions --uninstall" "$(installer --help)" "--uninstall"
has "args/unknown flag is rejected" "$(installer --nope)" "unknown option"
installer --nope >/dev/null 2>&1; eq "args/unknown flag exits 1" "$?" "1"

# A missing dependency must fail before anything is written. PATH is
# emptied except for a shim directory, so `jq` cannot be found.
shim=$(mktemp -d)
for c in bash cat cp mv rm mktemp date sed grep printf curl sha256sum; do
    p=$(command -v "$c") && ln -sf "$p" "$shim/$c"
done
out=$(HOME="$FAKE" STATUSLINE_PAYLOAD_FILE="$PAYLOAD" PATH="$shim" bash "$INSTALLER" 2>&1)
has "preflight/missing jq is reported" "$out" "jq"
hasnot "preflight/missing jq wrote nothing" "$(ls "$FAKE/.claude")" "statusline.sh"
rm -rf "$shim"
teardown

echo
echo "passed: $PASS   failed: $FAIL"
[[ $FAIL -eq 0 ]]
