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

# --- conflicts ---------------------------------------------------------
setup                                    # ours already there: an update
cat > "$FAKE/.claude/settings.json" <<'JSON'
{"theme":"dark","statusLine":{"type":"command","command":"bash ~/.claude/statusline.sh"}}
JSON
before=$(cat "$FAKE/.claude/settings.json")
out=$(installer)
has "conflict/ours says update" "$out" "update"
eq  "conflict/ours leaves settings byte-identical" "$(cat "$FAKE/.claude/settings.json")" "$before"
eq  "conflict/ours takes no backup" "$(ls "$FAKE/.claude" | grep -c 'settings.json.bak.')" "0"
eq  "conflict/ours still refreshed the script" \
    "$([[ -x $FAKE/.claude/statusline.sh ]] && echo yes)" "yes"
teardown

setup                                    # someone else's, no tty
cat > "$FAKE/.claude/settings.json" <<'JSON'
{"statusLine":{"type":"command","command":"bash ~/.claude/other-tool.sh"}}
JSON
out=$(installer < /dev/null)
has "conflict/foreign reports what it found" "$out" "other-tool.sh"
has "conflict/foreign suggests --force"      "$out" "--force"
installer < /dev/null >/dev/null 2>&1; eq "conflict/foreign exits 2" "$?" "2"
eq "conflict/foreign kept the foreign command" \
   "$(jq -r '.statusLine.command' "$FAKE/.claude/settings.json")" "bash ~/.claude/other-tool.sh"
eq "conflict/foreign took a backup" "$(ls "$FAKE/.claude" | grep -c 'settings.json.bak.')" "1"
teardown

setup                                    # someone else's, with --force
cat > "$FAKE/.claude/settings.json" <<'JSON'
{"keep":"me","statusLine":{"type":"command","command":"bash ~/.claude/other-tool.sh"}}
JSON
installer --force < /dev/null >/dev/null
eq "conflict/--force replaces" \
   "$(jq -r '.statusLine.command' "$FAKE/.claude/settings.json")" "bash ~/.claude/statusline.sh"
eq "conflict/--force keeps other keys" "$(jq -r '.keep' "$FAKE/.claude/settings.json")" "me"
teardown

echo
echo "passed: $PASS   failed: $FAIL"
[[ $FAIL -eq 0 ]]
