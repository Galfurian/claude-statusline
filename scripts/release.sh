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
