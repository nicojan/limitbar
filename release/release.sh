#!/bin/zsh
# Builds a release of Limitbar: universal binary, Sparkle linked in, Developer ID signed with the Hardened Runtime,
# the app and the DMG both notarized and stapled. Publishes nothing. Steps and the publishing half: release/DISTRIBUTION.md.
#
#   release/release.sh                              -> build/release-<version>-<build>/Limitbar-<version>.dmg
#   NOTARY_PROFILE= release/release.sh              -> signed but not notarized: a local test build
#   SIGN_ID=- NOTARY_PROFILE= release/release.sh    -> ad-hoc signed: CI's check that the Sparkle build compiles and links
#   INFO_PLIST=path  OUT=dir                        -> another Info.plist (an older test build) or output folder
set -euo pipefail
cd "$(dirname "$0")/.."

SPARKLE_VERSION=2.10.1
SPARKLE_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
SIGN_ID="${SIGN_ID-Developer ID Application: Nico Jan (3CY4DX3K45)}"
NOTARY_PROFILE="${NOTARY_PROFILE-chorus-notary}"   # same Apple account as Chorus; `xcrun notarytool store-credentials` made it
PLIST="${INFO_PLIST:-Info.plist}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
OUT="${OUT:-build/release-$VERSION-$BUILD}"
DMG_NAME="Limitbar-$VERSION.dmg"
[ -e "$OUT/$DMG_NAME" ] || [ -e "$OUT/Limitbar.app" ] && { echo "$OUT already has a build; bump the version or pass OUT=another/folder" >&2; exit 1; }
if [ -n "$NOTARY_PROFILE" ]; then
  # A real release must be newer than everything published: Sparkle compares CFBundleVersion, and a reused
  # number would never be offered. (./test.sh checks the same once the appcast has the new item.)
  python3 -I - docs/appcast.xml "$BUILD" <<'PY' || exit 1
import sys, xml.etree.ElementTree as ET
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
builds = [int(i.findtext(S + "version")) for i in ET.parse(sys.argv[1]).getroot().findall("channel/item")]
if builds and int(sys.argv[2]) <= max(builds):
    sys.exit(f"CFBundleVersion {sys.argv[2]} is not above the published {max(builds)}; bump it in Info.plist")
PY
fi

# Sparkle: the official release archive, checked against the pinned hash, cached in .build/ (ignored by git).
CACHE=".build/sparkle-$SPARKLE_VERSION"
if [ ! -d "$CACHE/Sparkle.framework" ]; then
  mkdir -p .build
  TARBALL=".build/Sparkle-$SPARKLE_VERSION.tar.xz"
  curl -fsSL -o "$TARBALL" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  echo "$SPARKLE_SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null || { echo "Sparkle archive hash mismatch" >&2; exit 1; }
  [ -e "$CACHE" ] && { echo "$CACHE exists but has no Sparkle.framework; delete it and rerun" >&2; exit 1; }
  UNPACK="$(mktemp -d)"
  tar -xJf "$TARBALL" -C "$UNPACK" && mv "$UNPACK" "$CACHE"
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Limitbar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" -F "$CACHE" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/Core.swift Sources/Settings.swift Sources/Updater.swift Sources/main.swift -o "$WORK/Limitbar-$arch"
done
lipo -create "$WORK/Limitbar-arm64" "$WORK/Limitbar-x86_64" -output "$APP/Contents/MacOS/Limitbar"
cp "$PLIST" "$APP/Contents/Info.plist"
cp Resources/Limitbar.icns "$APP/Contents/Resources/"
ditto "$CACHE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# The XPC services are only for sandboxed apps; Limitbar isn't sandboxed, and Sparkle's docs say to drop them.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

# Sign from the inside out (no --deep): Sparkle's helpers, then the framework, then the app.
# Ad-hoc signatures carry no Team ID, so the Hardened Runtime's library validation would refuse Sparkle; CI's ad-hoc
# build goes without it. A Developer ID build has the runtime on, as notarization requires.
sign() {
  if [ "$SIGN_ID" = - ]; then codesign --force --sign - "$@"
  else codesign --force --sign "$SIGN_ID" -o runtime --timestamp "$@"; fi
}
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPK/Autoupdate"
sign "$SPK/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --identifier com.nicojan.limitbar "$APP"
codesign --verify --deep --strict "$APP"

notarize() {   # submit, wait, and fail loudly, with Apple's log when there is one, if it isn't accepted
  local result id
  result="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json 2>&1)" || true
  id="$(print -r -- "$result" | python3 -I -c 'import json,sys
try: d = json.loads(sys.stdin.read())
except ValueError: d = {}
print(d.get("id", "") if d.get("status") != "Accepted" else "ACCEPTED")')"
  [ "$id" = ACCEPTED ] && return 0
  [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  echo "notarization of $1 failed: $result" >&2
  exit 1
}

if [ -n "$NOTARY_PROFILE" ]; then
  # The app gets its own ticket, so Gatekeeper accepts it offline after Sparkle unpacks it from the DMG.
  ditto -c -k --keepParent "$APP" "$WORK/Limitbar.zip"
  notarize "$WORK/Limitbar.zip"
  xcrun stapler staple "$APP"
fi

# A plain drag-to-Applications image. hdiutil, not create-dmg: the layout tool drives Finder and takes the screen.
mkdir -p "$WORK/dmg"
ditto "$APP" "$WORK/dmg/Limitbar.app"
ln -s /Applications "$WORK/dmg/Applications"
mkdir -p "$OUT"
hdiutil create -volname Limitbar -srcfolder "$WORK/dmg" -ov -format UDZO -quiet "$WORK/$DMG_NAME"
[ "$SIGN_ID" = - ] || codesign --force --sign "$SIGN_ID" --timestamp "$WORK/$DMG_NAME"

if [ -n "$NOTARY_PROFILE" ]; then
  notarize "$WORK/$DMG_NAME"
  xcrun stapler staple "$WORK/$DMG_NAME"
  spctl -a -vv -t open --context context:primary-signature "$WORK/$DMG_NAME"
  spctl -a -vv "$APP"
fi

mv "$WORK/$DMG_NAME" "$OUT/$DMG_NAME"
ditto "$APP" "$OUT/Limitbar.app"
echo "built $OUT/$DMG_NAME ($VERSION, build $BUILD)"
echo "sha256 $(shasum -a 256 "$OUT/$DMG_NAME" | cut -d' ' -f1)"
if [ -n "$NOTARY_PROFILE" ]; then
  # Sparkle's EdDSA signature of the final, stapled DMG (stapling changes the bytes, so this comes last).
  # The private key is in the login Keychain, shared with Chorus and WatchMeType.
  "$CACHE/bin/sign_update" "$OUT/$DMG_NAME"
fi
