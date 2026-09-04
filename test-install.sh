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

# --- payload digest ----------------------------------------------------
setup
out=$(installer)
has "digest/good digest installs" "$out" "installed"
eq  "digest/target exists" "$([[ -f $FAKE/.claude/statusline.sh ]] && echo yes)" "yes"
eq  "digest/target is executable" "$([[ -x $FAKE/.claude/statusline.sh ]] && echo yes)" "yes"
eq  "digest/target matches payload" \
    "$(sha256sum < "$FAKE/.claude/statusline.sh" | cut -d' ' -f1)" \
    "$(sha256sum < "$REPO_DIR/statusline.sh" | cut -d' ' -f1)"
teardown

setup
tampered=$(mktemp)
cat "$REPO_DIR/statusline.sh" > "$tampered"
printf '\n# tampered\n' >> "$tampered"
PAYLOAD="$tampered"
out=$(installer)
has "digest/mismatch is reported"  "$out" "digest mismatch"
has "digest/mismatch shows expected" "$out" "expected:"
has "digest/mismatch shows got"      "$out" "got:"
installer >/dev/null 2>&1; eq "digest/mismatch exits 1" "$?" "1"
eq "digest/mismatch installed nothing" "$([[ -e $FAKE/.claude/statusline.sh ]] && echo yes || echo no)" "no"
rm -f "$tampered"
teardown

# --- settings.json -----------------------------------------------------
setup                                    # no settings.json at all
installer >/dev/null
eq "settings/created from nothing" \
   "$(jq -r '.statusLine.command' "$FAKE/.claude/settings.json")" \
   "bash ~/.claude/statusline.sh"
eq "settings/type is command" \
   "$(jq -r '.statusLine.type' "$FAKE/.claude/settings.json")" "command"
teardown

setup                                    # existing keys must survive
cat > "$FAKE/.claude/settings.json" <<'JSON'
{"theme":"dark","autoMode":true,"permissions":{"allow":["Bash(ls:*)"]}}
JSON
installer >/dev/null
eq "settings/theme survives"       "$(jq -r '.theme' "$FAKE/.claude/settings.json")" "dark"
eq "settings/autoMode survives"    "$(jq -r '.autoMode' "$FAKE/.claude/settings.json")" "true"
eq "settings/permissions survive"  "$(jq -r '.permissions.allow[0]' "$FAKE/.claude/settings.json")" "Bash(ls:*)"
eq "settings/statusLine added"     "$(jq -r '.statusLine.command' "$FAKE/.claude/settings.json")" "bash ~/.claude/statusline.sh"
eq "settings/backup was taken"     "$(ls "$FAKE/.claude" | grep -c 'settings.json.bak.')" "1"
eq "settings/backup holds the original" \
   "$(jq -r '.statusLine // "none"' "$FAKE"/.claude/settings.json.bak.*)" "none"
teardown

setup                                    # invalid JSON must be left alone
printf '{ this is not json' > "$FAKE/.claude/settings.json"
out=$(installer)
has "settings/invalid json reported" "$out" "not valid JSON"
installer >/dev/null 2>&1; eq "settings/invalid json exits 1" "$?" "1"
eq "settings/invalid json untouched" \
   "$(cat "$FAKE/.claude/settings.json")" "{ this is not json"
teardown

echo
echo "passed: $PASS   failed: $FAIL"
[[ $FAIL -eq 0 ]]
