# claude-statusline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the already-working two-line Claude Code statusline as a small public repo with a verifiable one-line installer.

**Architecture:** Two shell artifacts. `statusline.sh` is the render — it exists, is tested (47 assertions), and is copied into the repo unchanged in Task 1. `install.sh` is written from scratch here, in bash, with the pinned `VERSION` and expected `SHA256` of the payload baked in at release time; it verifies the digest before installing and merges a single `statusLine` key into `~/.claude/settings.json` atomically. A test hook (`STATUSLINE_PAYLOAD_FILE`) lets the installer be tested against a local payload with a fake `HOME`, so no test ever touches the real `~/.claude` or the network.

**Tech Stack:** bash 4.2+, `jq`, `curl`, `sha256sum`/`shasum`, `git`, GitHub Actions, `shellcheck`, `gh` CLI (release only).

**Spec:** `docs/superpowers/specs/2026-09-04-claude-statusline-repo-design.md`

## Global Constraints

- Repo `Galfurian/claude-statusline`, public, MIT, default branch `main`.
- Target: **bash 4.2+** on Linux and modern macOS. No bash 3.2 compatibility code. The installer enforces the floor via its own `BASH_VERSINFO`.
- `statusline.sh` is the **only** file installed into `~/.claude`. Installed path: `~/.claude/statusline.sh`, mode `755`.
- The settings command string is exactly `bash ~/.claude/statusline.sh`.
- Published one-liner: `bash -c "$(curl -fsSL https://github.com/Galfurian/claude-statusline/releases/latest/download/install.sh)"` — not `sh -c` (on Debian/Ubuntu `sh` is dash, and there is no `$0` to re-exec when the script arrives as a string), not `curl | bash` (stdin would not be a terminal, so the installer could not ask).
- Three rules that must never be violated, being the three defects found in the audited installer: **(1)** no code path may overwrite `settings.json` wholesale — if the `jq` merge fails, stop and print the manual command; **(2)** every write is temp file → `jq -e` validation → `mv`; **(3)** a digest mismatch aborts the install and prints expected vs got.
- Exit codes: `0` done, `1` error, `2` conflict not resolved.
- Bars are 10 cells wide (one cell = 10%) for all three bars; colour steps at 50 / 75 / 90.
- No test may write outside its own `mktemp -d`, and no test may hit the network.

---

### Task 1: Seed the repo with the tested statusline

Brings the existing, passing artifact under version control and gives the repo a licence. The sources are the working copies produced in this session: `~/desktop/statusline.sh` and `/tmp/claude-1000/-home-enrico-repositories-personal-moonlit-society/1055fe4e-e6a7-4f58-a59e-be87f941e7e5/scratchpad/sl/test.sh`.

**Files:**
- Create: `statusline.sh` (copy of `~/desktop/statusline.sh`, unchanged)
- Create: `test.sh` (copy of the scratchpad `test.sh`, unchanged)
- Create: `LICENSE` (MIT, holder "Enrico Fraccaroli", year 2026)
- Create: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `statusline.sh` at the repo root — the payload every later task installs and digests. `./test.sh [path-to-statusline.sh]` exits 0 when all assertions pass and prints a final `passed: N   failed: M` line.

- [ ] **Step 1: Copy the two files in and make them executable**

```bash
cd ~/repositories/personal/claude-statusline
cp ~/desktop/statusline.sh statusline.sh
cp /tmp/claude-1000/-home-enrico-repositories-personal-moonlit-society/1055fe4e-e6a7-4f58-a59e-be87f941e7e5/scratchpad/sl/test.sh test.sh
chmod 755 statusline.sh test.sh
```

- [ ] **Step 2: Run the suite to confirm it passes in its new home**

Run: `./test.sh`
Expected: last line `passed: 47   failed: 0`, exit 0.

- [ ] **Step 3: Add LICENSE and .gitignore**

`LICENSE` is the standard MIT text with `Copyright (c) 2026 Enrico Fraccaroli`.

`.gitignore`:

```gitignore
*.bak
*.tmp
.DS_Store
```

- [ ] **Step 4: Commit**

```bash
git add statusline.sh test.sh LICENSE .gitignore
git commit -m "feat: the statusline, and the 47 assertions that hold it"
```

---

### Task 2: install.sh skeleton — argument parsing and preflight

The installer that validates its environment and does nothing else yet. Its gate is that a wrong environment fails loudly and early, before anything is written.

**Files:**
- Create: `install.sh`
- Create: `test-install.sh`

**Interfaces:**
- Consumes: `statusline.sh` from Task 1 (only as the digest target later).
- Produces, all relied on by Tasks 3-6:
  - shell variables `VERSION`, `SHA256`, `REPO`, `CLAUDE_DIR`, `TARGET`, `SETTINGS`, `COMMAND`, `DRY_RUN`, `FORCE`, `ACTION`
  - functions `die MESSAGE...` (prints `error: MESSAGE` to stderr, exits 1), `note MESSAGE...` (prints to stdout), `preflight` (no args), `sha_of FILE` (echoes the hex digest), `parse_args "$@"`
  - `ACTION` is one of `install` or `uninstall`; `--version` and `--help` print and exit 0 inside `parse_args`
- Test harness produced here and reused by Tasks 3-6: `setup` (sets `$FAKE` to a fresh temp HOME with `.claude/`), `teardown`, `installer ARGS...` (runs `install.sh` under the fake HOME with the payload hook), `ok`/`bad`/`eq`/`has`/`hasnot` assertion helpers, and the `PASS`/`FAIL` counters.

- [ ] **Step 1: Write the failing tests**

`test-install.sh`:

```bash
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x test-install.sh && ./test-install.sh`
Expected: FAIL — `install.sh` does not exist yet, every assertion reports "No such file or directory".

- [ ] **Step 3: Write the minimal installer**

`install.sh`:

```bash
#!/usr/bin/env bash
#
# install.sh — installer for claude-statusline (https://github.com/Galfurian/claude-statusline)
#
# Usage:
#   bash -c "$(curl -fsSL https://github.com/Galfurian/claude-statusline/releases/latest/download/install.sh)"
#
# Or, to read it before running it, which is the better habit:
#   curl -fsSL https://github.com/Galfurian/claude-statusline/releases/latest/download/install.sh -o install.sh
#   less install.sh && bash install.sh
#
# It installs one file, ~/.claude/statusline.sh, and adds one key,
# .statusLine, to ~/.claude/settings.json. Nothing else is touched.

set -uo pipefail

# Injected by scripts/release.sh — the pinned payload and its digest.
VERSION="v0.0.0-dev"
SHA256="0000000000000000000000000000000000000000000000000000000000000000"

REPO="Galfurian/claude-statusline"
CLAUDE_DIR="${HOME}/.claude"
TARGET="${CLAUDE_DIR}/statusline.sh"
SETTINGS="${CLAUDE_DIR}/settings.json"
COMMAND="bash ~/.claude/statusline.sh"

DRY_RUN=0
FORCE=0
ACTION="install"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

usage() {
    cat <<USAGE
claude-statusline installer ${VERSION}

  install.sh                install or update the statusline
  install.sh --force        replace another tool's statusLine without asking
  install.sh --dry-run      print what would happen, write nothing
  install.sh --uninstall    remove the statusline and its settings key
  install.sh --version      print the pinned version
  install.sh --help         this text
USAGE
}

parse_args() {
    while (( $# )); do
        case $1 in
            --force)     FORCE=1 ;;
            --dry-run)   DRY_RUN=1 ;;
            --uninstall) ACTION="uninstall" ;;
            --version)   printf '%s\n' "$VERSION"; exit 0 ;;
            -h|--help)   usage; exit 0 ;;
            *)           die "unknown option: $1 (try --help)" ;;
        esac
        shift
    done
}

# The bash floor is checked against this script's own interpreter: with
# `bash -c "$(curl ...)"` on a stock macOS that is bash 3.2, and the user
# needs to hear it here rather than watch the statusline misbehave later.
preflight() {
    if (( BASH_VERSINFO[0] < 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2 ) )); then
        die "bash 4.2 or newer is required, this is ${BASH_VERSION}. On macOS: brew install bash"
    fi
    command -v jq   >/dev/null 2>&1 || die "jq not found — install it and run this again"
    command -v curl >/dev/null 2>&1 || die "curl not found — install it and run this again"
    command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
        || die "neither sha256sum nor shasum found — cannot verify the download"
    mkdir -p "$CLAUDE_DIR" 2>/dev/null || die "cannot create ${CLAUDE_DIR}"
    [[ -w $CLAUDE_DIR ]] || die "${CLAUDE_DIR} is not writable"
}

sha_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

main() {
    parse_args "$@"
    preflight
    note "preflight ok (${VERSION})"
}

main "$@"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test-install.sh`
Expected: `failed: 0`.

- [ ] **Step 5: Commit**

```bash
git add install.sh test-install.sh
git commit -m "feat: the installer checks its ground before it touches anything"
```

---

### Task 3: Fetch and verify the payload

The digest gate. This is the property that makes the one-liner defensible, so it gets its own task and its own reviewer.

`scripts/sync-digest.sh` exists because the tests need the committed `SHA256` to match the committed `statusline.sh`: the good-digest case installs the repo's real payload, and the bad-digest case installs a tampered copy. Task 7's CI check enforces the same invariant.

**Files:**
- Create: `scripts/sync-digest.sh`
- Modify: `install.sh` (add `fetch_payload`, `install_payload`; call them from `main`)
- Modify: `test-install.sh` (add the digest and install-file cases)

**Interfaces:**
- Consumes: `sha_of FILE`, `die`, `note`, `TARGET`, `VERSION`, `SHA256`, `REPO` from Task 2.
- Produces: `fetch_payload` (sets `$PAYLOAD` to a verified temp file, exits 1 on mismatch), `install_payload` (copies `$PAYLOAD` to `$TARGET` with mode 755), and `scripts/sync-digest.sh` (rewrites the `SHA256="..."` line in `install.sh` from the current `statusline.sh`).

- [ ] **Step 1: Write the failing tests**

Append to `test-install.sh`, before the final summary:

```bash
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `./test-install.sh`
Expected: the digest cases fail — nothing is installed and the word `installed` never appears.

- [ ] **Step 3: Write sync-digest.sh and run it**

`scripts/sync-digest.sh`:

```bash
#!/usr/bin/env bash
# Rewrites the SHA256 line in install.sh from the current statusline.sh.
# Run this after every change to statusline.sh; CI fails if they drift.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

digest_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

digest=$(digest_of "$root/statusline.sh")
tmp=$(mktemp)
sed "s/^SHA256=\".*\"$/SHA256=\"${digest}\"/" "$root/install.sh" > "$tmp"
grep -q "^SHA256=\"${digest}\"$" "$tmp" || { rm -f "$tmp"; echo "sync-digest: SHA256 line not found in install.sh" >&2; exit 1; }
mv "$tmp" "$root/install.sh"
chmod 755 "$root/install.sh"
echo "install.sh SHA256 = ${digest}"
```

Run: `chmod +x scripts/sync-digest.sh && ./scripts/sync-digest.sh`
Expected: prints the digest; `git diff install.sh` shows only the `SHA256=` line changed.

- [ ] **Step 4: Add fetch and install to install.sh**

Insert after `sha_of`:

```bash
# STATUSLINE_PAYLOAD_FILE is a test hook: it substitutes a local file for
# the download. The digest is verified either way, so the hook cannot be
# used to smuggle an unverified payload past the check.
fetch_payload() {
    PAYLOAD=$(mktemp) || die "cannot create a temp file"
    if [[ -n ${STATUSLINE_PAYLOAD_FILE:-} ]]; then
        cp "$STATUSLINE_PAYLOAD_FILE" "$PAYLOAD" || die "cannot read ${STATUSLINE_PAYLOAD_FILE}"
    else
        local url="https://github.com/${REPO}/releases/download/${VERSION}/statusline.sh"
        curl -fsSL "$url" -o "$PAYLOAD" || { rm -f "$PAYLOAD"; die "download failed: ${url}"; }
    fi

    local got
    got=$(sha_of "$PAYLOAD")
    if [[ $got != "$SHA256" ]]; then
        rm -f "$PAYLOAD"
        printf 'error: digest mismatch, refusing to install\n  expected: %s\n  got:      %s\n' \
            "$SHA256" "$got" >&2
        exit 1
    fi
}

install_payload() {
    install -m 755 "$PAYLOAD" "$TARGET" || die "cannot write ${TARGET}"
    rm -f "$PAYLOAD"
    note "installed ${TARGET} (${VERSION})"
}
```

And extend `main`:

```bash
main() {
    parse_args "$@"
    preflight
    fetch_payload
    install_payload
}
```

- [ ] **Step 5: Run both suites**

Run: `./test.sh && ./test-install.sh`
Expected: `failed: 0` from both.

- [ ] **Step 6: Commit**

```bash
git add install.sh test-install.sh scripts/sync-digest.sh
git commit -m "feat: the payload is pinned, and the digest is the gate"
```

---

### Task 4: Wire settings.json on a fresh install

The atomic-write rules live here. The reviewer's question for this task is narrow: can any input make this clobber a settings file?

**Files:**
- Modify: `install.sh` (add `read_statusline`, `backup_settings`, `write_statusline_key`; call from `main`)
- Modify: `test-install.sh` (add the settings cases)

**Interfaces:**
- Consumes: `die`, `note`, `SETTINGS`, `COMMAND`, `DRY_RUN` from Task 2.
- Produces: `read_statusline` (echoes `.statusLine.command`, empty when absent or unreadable), `backup_settings` (echoes the backup path it created), `write_statusline_key` (merges the key atomically or dies without touching the file).

- [ ] **Step 1: Write the failing tests**

Append to `test-install.sh`:

```bash
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `./test-install.sh`
Expected: the settings cases fail — `settings.json` is never created, and the invalid file produces no message.

- [ ] **Step 3: Implement the settings wiring**

Insert before `main`:

```bash
read_statusline() {
    [[ -f $SETTINGS ]] || { printf '' ; return 0; }
    jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null || printf ''
}

backup_settings() {
    local path="${SETTINGS}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$SETTINGS" "$path" || die "cannot write the backup ${path}"
    printf '%s\n' "$path"
}

# Temp file, validate, then mv. If the merge fails the original is never
# opened for writing, and the user gets the manual command instead of a
# truncated settings file.
write_statusline_key() {
    local tmp
    tmp=$(mktemp) || die "cannot create a temp file"

    if [[ -f $SETTINGS ]]; then
        jq -e . "$SETTINGS" >/dev/null 2>&1 \
            || die "${SETTINGS} is not valid JSON — leaving it untouched. Fix it, then run this again."
        note "backed up $(backup_settings)"
        jq --arg c "$COMMAND" '.statusLine = {type: "command", command: $c}' "$SETTINGS" > "$tmp" \
            || { rm -f "$tmp"; die "the jq merge failed — ${SETTINGS} is untouched. Add this key by hand: \"statusLine\": {\"type\": \"command\", \"command\": \"${COMMAND}\"}"; }
    else
        jq -n --arg c "$COMMAND" '{statusLine: {type: "command", command: $c}}' > "$tmp" \
            || { rm -f "$tmp"; die "cannot generate ${SETTINGS}"; }
    fi

    jq -e . "$tmp" >/dev/null 2>&1 \
        || { rm -f "$tmp"; die "produced invalid JSON — ${SETTINGS} is untouched"; }
    mv "$tmp" "$SETTINGS" || { rm -f "$tmp"; die "cannot replace ${SETTINGS}"; }
    note "configured ${SETTINGS}"
}
```

And extend `main`:

```bash
main() {
    parse_args "$@"
    preflight
    fetch_payload
    install_payload
    write_statusline_key
    note "done — start a new Claude Code session to see it"
}
```

- [ ] **Step 4: Run the tests**

Run: `./test-install.sh`
Expected: `failed: 0`.

- [ ] **Step 5: Commit**

```bash
git add install.sh test-install.sh
git commit -m "feat: one key merged into settings.json, atomically or not at all"
```

---

### Task 5: The conflict decision table

Four cases, one of which asks a question. The non-tty branch is what makes the one-liner safe for people who pipe it anyway.

**Files:**
- Modify: `install.sh` (add `classify_existing`, `resolve_conflict`; branch in `main`)
- Modify: `test-install.sh` (add the four cases plus `--force`)

**Interfaces:**
- Consumes: `read_statusline`, `write_statusline_key`, `backup_settings`, `install_payload`, `COMMAND`, `FORCE`, `note`, `die` from Tasks 2-4.
- Produces: `classify_existing` (echoes `fresh`, `ours`, or `foreign`), `resolve_conflict` (returns 0 to proceed, exits 2 when refused).

- [ ] **Step 1: Write the failing tests**

Append to `test-install.sh`:

```bash
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `./test-install.sh`
Expected: the conflict cases fail — the foreign command is currently overwritten without asking and the exit code is 0, not 2.

- [ ] **Step 3: Implement the decision table**

Insert before `main`:

```bash
classify_existing() {
    local current
    current=$(read_statusline)
    if   [[ -z $current ]];            then printf 'fresh\n'
    elif [[ $current == "$COMMAND" ]]; then printf 'ours\n'
    else                                    printf 'foreign\n'
    fi
}

# Only reached for a foreign statusLine. --force proceeds; a terminal gets
# asked; a pipe gets the prudent path, because a question nobody can answer
# is not a safeguard.
resolve_conflict() {
    local current
    current=$(read_statusline)

    if (( FORCE )); then
        note "replacing the existing statusLine (--force): ${current}"
        return 0
    fi

    printf 'found another statusLine already configured:\n    %s\n' "$current"
    note "backed up $(backup_settings)"

    if [[ -t 0 ]]; then
        local answer=""
        read -r -p "replace it with claude-statusline? [y/N] " answer
        case $answer in
            [yY]|[yY][eE][sS]) return 0 ;;
        esac
        note "left as it was — nothing changed"
        exit 2
    fi

    printf 'not replacing it. To replace it, run:\n    bash install.sh --force\n'
    exit 2
}
```

And branch in `main`:

```bash
main() {
    parse_args "$@"
    preflight

    local state
    state=$(classify_existing)
    [[ $state == foreign ]] && resolve_conflict

    fetch_payload
    install_payload

    if [[ $state == ours ]]; then
        note "update only — settings.json already points here, leaving it alone"
    else
        write_statusline_key
    fi
    note "done — start a new Claude Code session to see it"
}
```

- [ ] **Step 4: Run the tests**

Run: `./test-install.sh`
Expected: `failed: 0`.

- [ ] **Step 5: Check the interactive branch by hand, since no test covers a tty**

Run, in a real terminal:

```bash
FAKE=$(mktemp -d); mkdir -p "$FAKE/.claude"
printf '{"statusLine":{"type":"command","command":"bash ~/.claude/other.sh"}}' > "$FAKE/.claude/settings.json"
HOME="$FAKE" STATUSLINE_PAYLOAD_FILE=./statusline.sh bash ./install.sh
```

Expected: it prints the foreign command, asks `replace it with claude-statusline? [y/N]`, and pressing Enter leaves the foreign command in place with exit code 2. Then repeat and answer `y`: the command becomes ours.

- [ ] **Step 6: Commit**

```bash
git add install.sh test-install.sh
git commit -m "feat: an update is not a replacement, and a pipe is not a prompt"
```

---

### Task 6: --dry-run, --uninstall, and idempotency

**Files:**
- Modify: `install.sh` (add `plan_only`, `uninstall`; honour `DRY_RUN`; report an already-current install)
- Modify: `test-install.sh` (add the cases)

**Interfaces:**
- Consumes: everything from Tasks 2-5.
- Produces: `plan_only STATE` (prints the planned actions, exits 0), `uninstall` (removes `$TARGET` and the `.statusLine` key, exits 0).

- [ ] **Step 1: Write the failing tests**

Append to `test-install.sh`:

```bash
# --- dry-run, uninstall, idempotency -----------------------------------
setup
out=$(installer --dry-run)
has "dry-run/announces itself"      "$out" "dry-run"
has "dry-run/names the target"      "$out" "statusline.sh"
eq  "dry-run/wrote no script"       "$([[ -e $FAKE/.claude/statusline.sh ]] && echo yes || echo no)" "no"
eq  "dry-run/wrote no settings"     "$([[ -e $FAKE/.claude/settings.json ]] && echo yes || echo no)" "no"
installer --dry-run >/dev/null; eq "dry-run/exits 0" "$?" "0"
teardown

setup                                    # a second run must be a no-op
installer >/dev/null
first=$(cat "$FAKE/.claude/settings.json")
out=$(installer)
has "idempotent/second run says already current" "$out" "already"
eq  "idempotent/settings unchanged" "$(cat "$FAKE/.claude/settings.json")" "$first"
eq  "idempotent/one backup only"    "$(ls "$FAKE/.claude" | grep -c 'settings.json.bak.')" "0"
teardown

setup                                    # uninstall leaves the neighbours alone
cat > "$FAKE/.claude/settings.json" <<'JSON'
{"theme":"dark","autoMode":true}
JSON
installer >/dev/null
out=$(installer --uninstall)
has "uninstall/says so"            "$out" "removed"
eq  "uninstall/script is gone"     "$([[ -e $FAKE/.claude/statusline.sh ]] && echo yes || echo no)" "no"
eq  "uninstall/key is gone"        "$(jq -r '.statusLine // "none"' "$FAKE/.claude/settings.json")" "none"
eq  "uninstall/theme survives"     "$(jq -r '.theme' "$FAKE/.claude/settings.json")" "dark"
eq  "uninstall/autoMode survives"  "$(jq -r '.autoMode' "$FAKE/.claude/settings.json")" "true"
installer --uninstall >/dev/null 2>&1; eq "uninstall/is idempotent, exits 0" "$?" "0"
teardown
```

- [ ] **Step 2: Run to verify they fail**

Run: `./test-install.sh`
Expected: `--dry-run` currently installs for real, and `--uninstall` does nothing.

- [ ] **Step 3: Implement**

Insert before `main`:

```bash
plan_only() {
    local state="$1"
    printf 'dry-run: nothing will be written.\n'
    printf 'dry-run: would install %s (%s)\n' "$TARGET" "$VERSION"
    case $state in
        fresh)   printf 'dry-run: would add .statusLine to %s\n' "$SETTINGS" ;;
        ours)    printf 'dry-run: would refresh the script; %s already points here\n' "$SETTINGS" ;;
        foreign) printf 'dry-run: would ask before replacing "%s" in %s\n' "$(read_statusline)" "$SETTINGS" ;;
    esac
    exit 0
}

uninstall() {
    local removed=0

    if [[ -e $TARGET ]]; then
        (( DRY_RUN )) && { printf 'dry-run: would remove %s\n' "$TARGET"; } || {
            rm -f "$TARGET" || die "cannot remove ${TARGET}"
            note "removed ${TARGET}"
        }
        removed=1
    fi

    if [[ -f $SETTINGS ]] && [[ $(read_statusline) == "$COMMAND" ]]; then
        if (( DRY_RUN )); then
            printf 'dry-run: would remove .statusLine from %s\n' "$SETTINGS"
        else
            jq -e . "$SETTINGS" >/dev/null 2>&1 \
                || die "${SETTINGS} is not valid JSON — leaving it untouched"
            note "backed up $(backup_settings)"
            local tmp
            tmp=$(mktemp) || die "cannot create a temp file"
            jq 'del(.statusLine)' "$SETTINGS" > "$tmp" \
                || { rm -f "$tmp"; die "the jq edit failed — ${SETTINGS} is untouched"; }
            jq -e . "$tmp" >/dev/null 2>&1 \
                || { rm -f "$tmp"; die "produced invalid JSON — ${SETTINGS} is untouched"; }
            mv "$tmp" "$SETTINGS" || { rm -f "$tmp"; die "cannot replace ${SETTINGS}"; }
            note "removed .statusLine from ${SETTINGS}"
        fi
        removed=1
    fi

    (( removed )) || note "nothing to remove"
    exit 0
}
```

Then rewrite `main` to its final shape:

```bash
main() {
    parse_args "$@"
    preflight

    [[ $ACTION == uninstall ]] && uninstall

    local state
    state=$(classify_existing)

    (( DRY_RUN )) && plan_only "$state"

    # Already current: same version on disk, same key in settings. Say so
    # and stop, so running the one-liner twice is harmless.
    if [[ $state == ours && -x $TARGET ]]; then
        fetch_payload
        if [[ $(sha_of "$TARGET") == "$SHA256" ]]; then
            rm -f "$PAYLOAD"
            note "already at ${VERSION} — nothing to do"
            exit 0
        fi
        install_payload
        note "update only — settings.json already points here, leaving it alone"
        note "done — restart Claude Code to pick it up"
        exit 0
    fi

    [[ $state == foreign ]] && resolve_conflict

    fetch_payload
    install_payload
    write_statusline_key
    note "done — start a new Claude Code session to see it"
}
```

- [ ] **Step 4: Run both suites**

Run: `./test.sh && ./test-install.sh`
Expected: `failed: 0` from both.

- [ ] **Step 5: Commit**

```bash
git add install.sh test-install.sh
git commit -m "feat: dry-run, uninstall, and a second run that does nothing"
```

---

### Task 7: CI

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `./test.sh`, `./test-install.sh`, `./scripts/sync-digest.sh`.
- Produces: a `ci` workflow that fails on a shellcheck finding, a failing assertion, or a digest that has drifted from `statusline.sh`.

- [ ] **Step 1: Write the workflow**

```yaml
name: ci

on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: bash and jq versions
        run: bash --version | head -1 && jq --version

      - name: shellcheck
        run: shellcheck -S warning statusline.sh install.sh test.sh test-install.sh scripts/*.sh

      - name: render tests
        run: ./test.sh

      - name: installer tests
        run: ./test-install.sh

      # The installer pins a digest. If statusline.sh changed without
      # scripts/sync-digest.sh being run, the pin is a lie — fail here
      # rather than ship a release that cannot install itself.
      - name: digest is in sync
        run: |
          ./scripts/sync-digest.sh
          git diff --exit-code install.sh
```

- [ ] **Step 2: Run the same checks locally**

Run:

```bash
shellcheck -S warning statusline.sh install.sh test.sh test-install.sh scripts/*.sh
./test.sh && ./test-install.sh
./scripts/sync-digest.sh && git diff --exit-code install.sh && echo "digest in sync"
```

Expected: shellcheck silent, both suites `failed: 0`, digest in sync. Fix any shellcheck finding now — CI will not accept it later. If `shellcheck` is not installed: `sudo apt install shellcheck`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: shellcheck, both suites, and a digest that cannot drift"
```

---

### Task 8: README and the release script

**Files:**
- Create: `README.md`
- Create: `scripts/release.sh`

**Interfaces:**
- Consumes: `scripts/sync-digest.sh` from Task 3.
- Produces: `scripts/release.sh <vX.Y.Z>` — syncs the digest, sets `VERSION`, commits, tags, and creates the GitHub release with both files as assets.

- [ ] **Step 1: Write the README**

It must contain, in this order: what it is with the two-line sample render; the one-liner from Global Constraints; the read-it-first variant; what it installs (exactly two things: `~/.claude/statusline.sh` and one `.statusLine` key) and what it never touches; requirements (bash 4.2+, `jq`; `git` optional); the tuning table (`BAR_W_CTX`, `BAR_W_LIM`, `T_MEDIUM`, `T_WARN`, `T_CRIT`, `G_FILL`, `G_EMPTY`, `NO_COLOR`) with the note that one cell is 10%; `--dry-run`, `--force`, `--uninstall`; a "why you can check this" section naming the tag pin and the digest; and `./test.sh && ./test-install.sh` for contributors.

- [ ] **Step 2: Write scripts/release.sh**

```bash
#!/usr/bin/env bash
# Cuts a release: sync the digest, pin the version, tag, publish.
# Usage: scripts/release.sh v1.0.0
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

version="${1:-}"
[[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 vX.Y.Z" >&2; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "working tree is dirty" >&2; exit 1; }

./test.sh
./test-install.sh

./scripts/sync-digest.sh
tmp=$(mktemp)
sed "s/^VERSION=\".*\"$/VERSION=\"${version}\"/" install.sh > "$tmp"
grep -q "^VERSION=\"${version}\"$" "$tmp" || { echo "VERSION line not found" >&2; exit 1; }
mv "$tmp" install.sh
chmod 755 install.sh

# The digest must match after pinning, or the release cannot install itself.
./test-install.sh

git add install.sh
git commit -m "release: ${version}"
git tag -a "$version" -m "${version}"
git push origin main --follow-tags
gh release create "$version" statusline.sh install.sh \
    --title "$version" \
    --notes "Install: \`bash -c \"\$(curl -fsSL https://github.com/Galfurian/claude-statusline/releases/latest/download/install.sh)\"\`"
echo "released ${version}"
```

- [ ] **Step 3: Verify the release script refuses bad input, without releasing**

Run:

```bash
./scripts/release.sh          ; echo "exit=$?"   # expect usage, exit 1
./scripts/release.sh 1.0.0    ; echo "exit=$?"   # expect usage, exit 1
touch dirty-file && ./scripts/release.sh v1.0.0 ; echo "exit=$?"  # expect dirty tree, exit 1
rm -f dirty-file
```

Expected: all three exit 1 before touching git.

- [ ] **Step 4: Commit**

```bash
git add README.md scripts/release.sh
git commit -m "docs: the README, and a release that cannot ship an unpinned digest"
```

---

### Task 9: Publish — STOP for approval first

The two irreversible actions in this plan. **Do not run this task without Enrico saying go.** Everything before it is local and reversible; this makes the repo public under his name and puts a URL into the world.

**Files:** none.

**Interfaces:**
- Consumes: a green working tree from Tasks 1-8.
- Produces: the public repo and the `v1.0.0` release backing the one-liner.

- [ ] **Step 1: Confirm the local state is green**

Run: `./test.sh && ./test-install.sh && git status --porcelain && git log --oneline`
Expected: both suites `failed: 0`, clean tree, the eight commits from Tasks 1-8.

- [ ] **Step 2: Ask Enrico to approve publishing, and wait**

Show him the repo name, the one-liner, and the file list. Do not proceed on silence.

- [ ] **Step 3: Create the public repo and push**

```bash
gh repo create Galfurian/claude-statusline --public --source=. --remote=origin --push
```

- [ ] **Step 4: Wait for CI to pass on main**

Run: `gh run watch`
Expected: the `ci` job succeeds. If it fails, fix it and push before releasing — a release cut from a red main ships a broken installer.

- [ ] **Step 5: Cut v1.0.0**

Run: `./scripts/release.sh v1.0.0`
Expected: both suites pass, the tag is pushed, and the release carries `statusline.sh` and `install.sh` as assets.

- [ ] **Step 6: Verify the published one-liner end to end, against a fake HOME**

```bash
FAKE=$(mktemp -d); mkdir -p "$FAKE/.claude"
HOME="$FAKE" bash -c "$(curl -fsSL https://github.com/Galfurian/claude-statusline/releases/latest/download/install.sh)"
jq . "$FAKE/.claude/settings.json"
echo '{"context_window":{"used_percentage":42,"context_window_size":1000000},"workspace":{"current_dir":"'"$PWD"'"}}' \
  | bash "$FAKE/.claude/statusline.sh"
rm -rf "$FAKE"
```

Expected: the installer downloads from the release, verifies the digest, writes both things into the fake HOME, and the installed script renders a bar with four cells lit at 42%. This is the first run that exercises the real URL and the real digest.

---

## Self-Review

**Spec coverage.** Goal → Tasks 1, 9. Non-goals → nothing in the plan adds them. Artifact properties → Task 1 carries them in with the file and `test.sh` guards them. Distribution and trust chain → Tasks 3 (digest), 8 (release assets), 9 (published URL verified). install.sh contract: CLI → Tasks 2, 6; preflight → Task 2; decision table → Task 5; the three non-negotiable rules → Tasks 3 (rule 3), 4 (rules 1, 2), 6 (rules 1, 2 on uninstall); idempotency → Task 6. Testing → Tasks 2-6 build `test-install.sh` case by case; Task 7 runs both suites plus shellcheck plus the digest check. Release process → Task 8. Repo layout → Tasks 1, 2, 3, 7, 8 together create every path listed.

**Placeholders.** None: every code step carries the actual code, every run step carries the command and the expected result. Task 8 Step 1 specifies the README by required content rather than full prose, which is prose to write, not a decision to defer.

**Type consistency.** `die`/`note` (Task 2) are used unchanged throughout. `sha_of FILE` (Task 2) is consumed by `fetch_payload` and by the already-current check in Task 6. `fetch_payload` sets `$PAYLOAD`, consumed by `install_payload` in Task 3 and by Task 6. `read_statusline`, `backup_settings`, `write_statusline_key` (Task 4) are consumed by Tasks 5 and 6. `classify_existing` returns exactly `fresh|ours|foreign`, and all three are handled in Task 5's `main` and in Task 6's `plan_only` and final `main`. `ACTION` is set in Task 2 and read in Task 6. `STATUSLINE_PAYLOAD_FILE` is the only test hook, introduced in Task 3 and used by the Task 2 harness — which means the Task 2 harness sets a variable the installer ignores until Task 3, harmlessly and deliberately, so the harness never has to change.

**One inconsistency found and fixed while reviewing:** Task 5's `main` wrote the settings key for state `ours`, which contradicted the spec's "do not touch settings.json" for an update. Task 6's final `main` supersedes it, and Task 5's tests already assert the byte-identical settings file, so the contradiction cannot survive Task 5's own gate.
