#!/bin/zsh
# Builds Limitbar.app (menu bar only, no Dock icon).
#   ./build.sh                  -> installs to ~/Applications and launches it
#   OUT=/some/folder ./build.sh -> builds there and does not launch
# Builds in a temp folder first, so a failed compile leaves the installed copy untouched and running.
set -e; cd "$(dirname "$0")"
DEST="${OUT:-$HOME/Applications}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
NEW="$WORK/Limitbar.app"
mkdir -p "$NEW/Contents/MacOS"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  Sources/Core.swift Sources/main.swift -o "$NEW/Contents/MacOS/Limitbar"
cp Info.plist "$NEW/Contents/Info.plist"
codesign --force --sign - --identifier com.nicojan.limitbar "$NEW"

mkdir -p "$DEST"
if [ -z "$OUT" ]; then pkill -x Limitbar 2>/dev/null || true; fi
rm -rf "$DEST/Limitbar.app"
mv "$NEW" "$DEST/Limitbar.app"
echo "built $DEST/Limitbar.app"
if [ -z "$OUT" ]; then open "$DEST/Limitbar.app"; fi
