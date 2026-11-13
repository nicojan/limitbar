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

# Release metadata: the appcast parses, and its newest item agrees with the cask and isn't ahead of Info.plist.
python3 -I - docs/appcast.xml release/homebrew/limitbar.rb Info.plist <<'PY' || exit 1
import plistlib, re, sys, xml.etree.ElementTree as ET
appcast, cask, plist = sys.argv[1:]
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.parse(appcast).getroot().findall("channel/item")
info = plistlib.load(open(plist, "rb"))
cask_version = re.search(r'^\s*version "([^"]+)"', open(cask).read(), re.M).group(1)
if items:
    top = items[0]
    builds = [int(i.findtext(S + "version")) for i in items]
    assert builds == sorted(builds, reverse=True) and len(set(builds)) == len(builds), f"appcast builds not newest-first and unique: {builds}"
    assert top.findtext(S + "shortVersionString") == cask_version, f"cask {cask_version} != appcast {top.findtext(S + 'shortVersionString')}"
    assert int(info["CFBundleVersion"]) >= builds[0], f"Info.plist build {info['CFBundleVersion']} is behind the appcast's {builds[0]}"
    if info["CFBundleShortVersionString"] != top.findtext(S + "shortVersionString"):   # a new version needs a new build number
        assert int(info["CFBundleVersion"]) > builds[0], f"Info.plist is {info['CFBundleShortVersionString']} but still build {info['CFBundleVersion']}"
    assert not re.search(r'sha256 "0{64}"', open(cask).read()), "cask still has the placeholder sha256"
    enc = top.find("enclosure")
    assert enc.get("url").endswith(f"/v{cask_version}/Limitbar-{cask_version}.dmg"), enc.get("url")
    assert enc.get(S + "edSignature") and int(enc.get("length")) > 0, "enclosure needs edSignature and length"
else:
    assert cask_version == "0.0.0", "cask has a version but the appcast has no item"
print("release metadata: ok")
PY
