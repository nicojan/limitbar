#!/bin/zsh
# Compiles the pure logic with the test runner and runs it. No Xcode needed.
set -e; cd "$(dirname "$0")"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 5 Sources/Core.swift Tests/main.swift -o "$WORK/limitbar-tests"
"$WORK/limitbar-tests"

# The status-line wrapper: copies only rate_limits, always runs the wrapped command with the same stdin.
FAKE_HOME="$WORK/home"; mkdir -p "$FAKE_HOME"
IN='{"cwd":"/secret/path","rate_limits":{"five_hour":{"used_percentage":52}}}'
OUT_TEXT="$(printf %s "$IN" | HOME="$FAKE_HOME" scripts/statusline-tee.py /bin/sh -c 'cat; echo " wrapped"; exit 3')" && st=0 || st=$?
CACHE="$FAKE_HOME/Library/Application Support/Limitbar/latest.json"
[ "$OUT_TEXT" = "$IN wrapped" ] || { echo "FAIL wrapper: stdin/stdout not passed through: $OUT_TEXT"; exit 1; }
[ "$st" = 3 ] || { echo "FAIL wrapper: exit status not passed through ($st)"; exit 1; }
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert set(d)=={"written_at","rate_limits"} and d["rate_limits"]["five_hour"]["used_percentage"]==52' "$CACHE" \
  || { echo "FAIL wrapper: cache content"; exit 1; }
command grep -q secret "$CACHE" && { echo "FAIL wrapper: copied more than rate_limits"; exit 1; }
print -r -- 'not json' | HOME="$FAKE_HOME" scripts/statusline-tee.py /bin/echo still-runs | command grep -q still-runs || { echo "FAIL wrapper: bad input stopped the wrapped command"; exit 1; }
echo "wrapper: ok"
