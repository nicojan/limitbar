#!/bin/zsh
# Builds Limitbar.app (menu bar only, no Dock icon).
#   ./build.sh                           -> installs to ~/Applications and relaunches it (and the status-line wrapper to ~/.local/bin)
#   LIMITBAR_OUT=/some/folder ./build.sh -> builds there and does not launch (relative paths are from where you run it)
# Builds in a temp folder first, so a failed compile leaves the installed copy untouched and running.
set -e
if [ -n "$LIMITBAR_OUT" ]; then OUT_DIR="${LIMITBAR_OUT:A}"; fi   # absolute, resolved before the cd below
cd "$(dirname "$0")"
DEST="${OUT_DIR:-$HOME/Applications}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
NEW="$WORK/Limitbar.app"
mkdir -p "$NEW/Contents/MacOS"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  Sources/Core.swift Sources/Settings.swift Sources/main.swift -o "$NEW/Contents/MacOS/Limitbar"
cp Info.plist "$NEW/Contents/Info.plist"
mkdir -p "$NEW/Contents/Resources" && cp Resources/Limitbar.icns "$NEW/Contents/Resources/"   # drawn by scripts/make-icon.swift
codesign --force --sign - --identifier com.nicojan.limitbar "$NEW"

mkdir -p "$DEST"
BIN="$DEST/Limitbar.app/Contents/MacOS/Limitbar"
# Only the installed menu bar copy: exact command line, so a `--once` run or a dev copy elsewhere survives.
MATCH="^${BIN//./\\.}\$"
if [ -z "$OUT_DIR" ]; then
  pkill -f "$MATCH" 2>/dev/null || true
  for _ in {1..50}; do pgrep -f "$MATCH" >/dev/null || break; sleep 0.1; done   # let it exit before `open`
fi
rm -rf "$DEST/Limitbar.app"
mv "$NEW" "$DEST/Limitbar.app"
echo "built $DEST/Limitbar.app"
if [ -z "$OUT_DIR" ]; then
  # The status-line wrapper lives on the home volume, so Claude Code's status line works even if this repo's drive isn't mounted.
  mkdir -p "$HOME/.local/bin"
  cp scripts/statusline-tee.py "$HOME/.local/bin/limitbar-statusline.tmp" && chmod +x "$HOME/.local/bin/limitbar-statusline.tmp"
  mv "$HOME/.local/bin/limitbar-statusline.tmp" "$HOME/.local/bin/limitbar-statusline"
  echo "installed $HOME/.local/bin/limitbar-statusline"
  open "$DEST/Limitbar.app"
fi
