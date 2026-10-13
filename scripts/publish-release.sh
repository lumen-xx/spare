#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?Usage: bash scripts/publish-release.sh VERSION}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then exit 1; fi
REPOSITORY="$(python3 -c 'import json; print(json.load(open("updates/config.json"))["repository"])')"
LEGACY="$(python3 -c 'import json; print(json.load(open("updates/config.json")).get("legacy_repository", ""))')"
RELEASE_DIR="dist/releases/$VERSION"
if [ ! -f "$RELEASE_DIR/appcast.xml" ] || [ ! -f "$RELEASE_DIR/Spare-$VERSION.zip" ] || [ ! -f docs/RELEASE_NOTES.md ]; then
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
# The app and its signed feed are assets of the release; the feed URL is releases/latest/download/appcast.xml.
gh release create "v$VERSION" \
    "$RELEASE_DIR/Spare-$VERSION.zip" "$RELEASE_DIR/appcast.xml" \
    --repo "$REPOSITORY" --title "Spare $VERSION" \
    --notes-file docs/RELEASE_NOTES.md --latest
# Builds up to 0.3.1 read their feed from the old releases repository. It gets the same signed feed, whose downloads
# point here, so those copies update to a build that reads the new feed.
if [ -n "$LEGACY" ]; then
    LEGACY_CHECKOUT="$(pwd)/work/legacy-feed"
    [ -d "$LEGACY_CHECKOUT/.git" ] || gh repo clone "$LEGACY" "$LEGACY_CHECKOUT"
    git -C "$LEGACY_CHECKOUT" pull --ff-only origin main
    cp "$RELEASE_DIR/appcast.xml" "$LEGACY_CHECKOUT/appcast.xml"
    cp docs/LEGACY_README.md "$LEGACY_CHECKOUT/README.md"
    git -C "$LEGACY_CHECKOUT" add appcast.xml README.md
    if ! git -C "$LEGACY_CHECKOUT" diff --cached --quiet; then
        git -C "$LEGACY_CHECKOUT" commit -m "Spare $VERSION: downloads and updates now come from $REPOSITORY"
        git -C "$LEGACY_CHECKOUT" push origin HEAD:main
    fi
fi
