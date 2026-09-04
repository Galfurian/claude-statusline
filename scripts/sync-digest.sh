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
