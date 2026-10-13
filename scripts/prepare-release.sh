#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?Usage: bash scripts/prepare-release.sh VERSION BUILD}"
BUILD="${2:?Provide an increasing numeric build number}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "Use a version such as 1.1.0 and a numeric build such as 2." >&2
    exit 1
fi
if [ -z "$(python3 -c 'import json; print(json.load(open("updates/config.json")).get("public_key", ""))')" ]; then
    echo "No update signing key yet. Create one with: .build/artifacts/sparkle/Sparkle/bin/generate_keys --account spare" >&2
    echo "and put its public key into updates/config.json." >&2
    exit 1
fi
SPARE_VERSION="$VERSION" SPARE_BUILD="$BUILD" bash scripts/build-app.sh
REPOSITORY="$(python3 -c 'import json; print(json.load(open("updates/config.json"))["repository"])')"
RELEASE_DIR="$(pwd)/dist/releases/$VERSION"
mkdir -p "$RELEASE_DIR"
if gh release view "v$VERSION" --repo "$REPOSITORY" >/dev/null 2>&1; then
    echo "This version is already published. Choose a new version and build number." >&2
    exit 1
fi
rm -f "$RELEASE_DIR/appcast.xml"
# Retain previous signed feed entries without editing their signed contents.
LATEST_TAG="$(gh release list --repo "$REPOSITORY" --limit 1 --json tagName --jq '.[0].tagName // empty')"
if [ -n "$LATEST_TAG" ]; then
    gh release download "$LATEST_TAG" --repo "$REPOSITORY" --pattern appcast.xml --dir "$RELEASE_DIR" --clobber
    python3 - "$RELEASE_DIR/appcast.xml" "$BUILD" <<'PYORDER'
import sys, xml.etree.ElementTree as ET
versions = [int(n.text) for n in ET.parse(sys.argv[1]).getroot().iter('{http://www.andymatuschak.org/xml-namespaces/sparkle}version')]
assert int(sys.argv[2]) > max(versions, default=0), 'Build number must increase'
PYORDER
fi
ditto -c -k --sequesterRsrc --keepParent dist/Spare.app "$RELEASE_DIR/Spare-$VERSION.zip"
python3 scripts/appcast.py "$RELEASE_DIR" "$VERSION" "$BUILD"
.build/artifacts/sparkle/Sparkle/bin/sign_update --account spare "$RELEASE_DIR/appcast.xml"
python3 scripts/verify-release.py "$RELEASE_DIR/appcast.xml" "$RELEASE_DIR/Spare-$VERSION.zip" "$BUILD"
echo "Signed release prepared in $RELEASE_DIR"
