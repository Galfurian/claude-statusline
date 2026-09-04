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
VERSION="v1.0.0"
SHA256="3c11f8ff97a90e69b0918bbf4530ce49099b1901c3a25a5a180644a1128fd64a"

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

read_statusline() {
    [[ -f $SETTINGS ]] || { printf '' ; return 0; }
    jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null || printf ''
}

backup_settings() {
    local path
    path="${SETTINGS}.bak.$(date +%Y%m%d_%H%M%S)"
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

    # No backup on the paths that proceed: write_statusline_key takes one
    # right before it changes anything. A backup is only worth taking here
    # on the paths that stop, where nothing else will take it.
    if [[ -t 0 ]]; then
        local answer=""
        read -r -p "replace it with claude-statusline? [y/N] " answer
        case $answer in
            [yY]|[yY][eE][sS]) return 0 ;;
        esac
        note "left as it was — nothing changed"
        exit 2
    fi

    note "backed up $(backup_settings)"
    printf 'not replacing it. To replace it, run:\n    bash install.sh --force\n'
    exit 2
}

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
        if (( DRY_RUN )); then
            printf 'dry-run: would remove %s\n' "$TARGET"
        else
            rm -f "$TARGET" || die "cannot remove ${TARGET}"
            note "removed ${TARGET}"
        fi
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

main() {
    parse_args "$@"
    preflight

    [[ $ACTION == uninstall ]] && uninstall

    local state
    state=$(classify_existing)

    (( DRY_RUN )) && plan_only "$state"

    # settings.json already points at us, so this is an update whatever the
    # state of the file on disk: refresh the script, never touch the key.
    # If the script is already the pinned one, say so and stop, so running
    # the one-liner twice is harmless.
    if [[ $state == ours ]]; then
        fetch_payload
        if [[ -x $TARGET && $(sha_of "$TARGET") == "$SHA256" ]]; then
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

main "$@"
