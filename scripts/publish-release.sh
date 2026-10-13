#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?Usage: bash scripts/publish-release.sh VERSION}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then exit 1; fi
REPOSITORY="$(python3 -c 'import json; print(json.load(open("updates/config.json"))["repository"])')"
RELEASE_DIR="dist/releases/$VERSION"
if [ ! -f "$RELEASE_DIR/appcast.xml" ] || [ ! -f "$RELEASE_DIR/Spare-$VERSION.zip" ]; then
    echo "Prepare and verify this release first." >&2
    exit 1
fi
BUILD="$(python3 - "$RELEASE_DIR/Spare-$VERSION.zip" <<'PYBUILD'
import plistlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    print(plistlib.loads(archive.read('Spare.app/Contents/Info.plist'))['CFBundleVersion'])
PYBUILD
)"
python3 scripts/verify-release.py "$RELEASE_DIR/appcast.xml" "$RELEASE_DIR/Spare-$VERSION.zip" "$BUILD"
FEED_CHECKOUT="$(pwd)/work/releases-repository"
if [ ! -d "$FEED_CHECKOUT/.git" ]; then
    gh repo clone "$REPOSITORY" "$FEED_CHECKOUT"
fi
git -C "$FEED_CHECKOUT" checkout -B main
if ! git -C "$FEED_CHECKOUT" rev-parse HEAD >/dev/null 2>&1; then
    cp docs/RELEASE_README.md "$FEED_CHECKOUT/README.md"
    git -C "$FEED_CHECKOUT" add README.md
    git -C "$FEED_CHECKOUT" commit -m "Initialize binary releases repository"
    git -C "$FEED_CHECKOUT" push -u origin main
else
    git -C "$FEED_CHECKOUT" pull --ff-only origin main
fi
# GitHub release creation is explicit; preparation never publishes.
gh release create "v$VERSION" \
    "$RELEASE_DIR/Spare-$VERSION.zip" "$RELEASE_DIR/appcast.xml" \
    --repo "$REPOSITORY" --title "Spare $VERSION" \
    --notes-file docs/RELEASE_NOTES.md
cp "$RELEASE_DIR/appcast.xml" "$FEED_CHECKOUT/appcast.xml"
# The release page describes the current version, with its screenshots.
cp docs/RELEASE_README.md "$FEED_CHECKOUT/README.md"
mkdir -p "$FEED_CHECKOUT/images"
cp docs/images/*.png "$FEED_CHECKOUT/images/"
git -C "$FEED_CHECKOUT" add appcast.xml README.md images
git -C "$FEED_CHECKOUT" commit -m "Publish signed Spare $VERSION appcast"
git -C "$FEED_CHECKOUT" push -u origin main
