#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${SPARE_VERSION:-0.2.0}"
BUILD="${SPARE_BUILD:-2}"
APP="$(pwd)/dist/Spare.app"
swift build -c release --arch arm64
BIN_PATH="$(swift build -c release --arch arm64 --show-bin-path)"
FRAMEWORK=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
ditto Sources/Spare/Resources "$APP/Contents/Resources"
cp "$BIN_PATH/Spare" "$APP/Contents/MacOS/Spare"
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Spare</string>
<key>CFBundleIdentifier</key><string>com.opyuii.spare</string>
<key>CFBundleName</key><string>Spare</string>
<key>CFBundleDisplayName</key><string>Spare</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Spare asks Finder to move items that need a password to the Trash, and to empty the Trash when you ask.</string>
<key>SUEnableAutomaticChecks</key><false/>
<key>SUAutomaticallyUpdate</key><false/>
<key>SUEnableInstallerLauncherService</key><true/>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>SURequireSignedFeed</key><true/>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD" "$APP/Contents/Info.plist"
# The update feed and its key exist once the first release is published; until then builds don't check for updates.
PUBLIC_KEY="$(python3 -c 'import json; print(json.load(open("updates/config.json")).get("public_key", ""))')"
FEED_URL="$(python3 -c 'import json; print(json.load(open("updates/config.json")).get("feed_url", ""))')"
if [ -n "$PUBLIC_KEY" ]; then
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PUBLIC_KEY" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $FEED_URL" "$APP/Contents/Info.plist"
fi
# Sparkle keeps its upstream signatures, including its nested helpers. A stable identity keeps Full Disk Access
# across updates; an ad-hoc signature changes with every build.
SIGNING_KEYCHAIN="$(bash scripts/signing-identity.sh)"
codesign --force --keychain "$SIGNING_KEYCHAIN" --sign "Spare Local Signing" "$APP"
LEAF="$(codesign -d --requirements - "$APP" 2>&1 | sed -n 's/.*certificate leaf = H"\([0-9a-f]*\)".*/\1/p')"
if [ -z "$LEAF" ]; then
    echo "Spare was not signed with the stable identity." >&2
    exit 1
fi
if [ -f updates/signing-certificate.txt ] && [ "$LEAF" != "$(cat updates/signing-certificate.txt)" ]; then
    echo "Signed with a different certificate than earlier releases; Full Disk Access would be lost on update." >&2
    exit 1
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP ($VERSION, build $BUILD)"
SIZE=$(du -sk "$APP" | cut -f1)
[ "$SIZE" -lt 40960 ] || { echo "App exceeds 40 MB"; exit 1; }
