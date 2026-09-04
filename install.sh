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
