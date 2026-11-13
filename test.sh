#!/bin/zsh
# Compiles the pure logic with the test runner and runs it. No Xcode needed.
set -e; cd "$(dirname "$0")"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 5 Sources/Core.swift Tests/main.swift -o "$WORK/limitbar-tests"
"$WORK/limitbar-tests"

# The status-line wrapper: copies only percentages and reset times, always runs the wrapped command on the same stdin.
W=scripts/statusline-tee.py
FAKE_HOME="$WORK/home"; mkdir -p "$FAKE_HOME"
CACHE_DIR="$FAKE_HOME/Library/Application Support/Limitbar"; CACHE="$CACHE_DIR/latest.json"
IN='{"cwd":"/secret/path","rate_limits":{"five_hour":{"used_percentage":52,"resets_at":1794547200},"spend_limit":{"used_usd":12.5}}}'
fail() { echo "FAIL wrapper: $1"; exit 1; }
OUT_TEXT="$(printf %s "$IN" | HOME="$FAKE_HOME" $W /bin/sh -c 'cat; echo " wrapped"; exit 3')" && st=0 || st=$?
[ "$OUT_TEXT" = "$IN wrapped" ] || fail "stdin/stdout not passed through: $OUT_TEXT"
[ "$st" = 3 ] || fail "exit status not passed through ($st)"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert set(d)=={"written_at","rate_limits"}; assert d["rate_limits"]=={"five_hour":{"used_percentage":52,"resets_at":1794547200}}' "$CACHE" || fail "cache content"
command grep -q -e secret -e usd "$CACHE" && fail "copied more than percentages and reset times"
[ "$(stat -c %a "$CACHE" 2>/dev/null || stat -f %Lp "$CACHE")" = 600 ] || fail "cache file not private (0600)"
# One argument is a shell command line: pipes, ; and $(...) keep working.
OUT_TEXT="$(printf %s "$IN" | HOME="$FAKE_HOME" $W 'input=$(cat); printf %s "$input" | wc -c | tr -d " "; echo done')"
[ "$OUT_TEXT" = "${#IN}
done" ] || fail "shell syntax in a single argument: $OUT_TEXT"
# A failed copy (the folder is a file) never stops the wrapped command, and leaves nothing behind.
BAD_HOME="$WORK/bad"; mkdir -p "$BAD_HOME/Library/Application Support"; touch "$BAD_HOME/Library/Application Support/Limitbar"
OUT_TEXT="$(printf %s "$IN" | HOME="$BAD_HOME" $W /bin/echo still-runs)" || fail "failed copy changed the exit status"
[ "$OUT_TEXT" = still-runs ] || fail "failed copy stopped the wrapped command"
printf 'not json' | HOME="$FAKE_HOME" $W /bin/echo still-runs | command grep -q still-runs || fail "bad input stopped the wrapped command"
ls -A "$CACHE_DIR" | command grep -q '^\.latest-' && fail "temp file left behind"
printf %s "$IN" | HOME="$FAKE_HOME" $W /nonexistent/cmd 2>/dev/null && st=0 || st=$?
[ "$st" = 127 ] || fail "missing command should exit 127 ($st)"
echo "wrapper: ok"
