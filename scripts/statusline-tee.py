#!/usr/bin/env -S python3 -I
"""Claude Code status-line wrapper for Limitbar.

Usage in ~/.claude/settings.json:  "statusLine": {"type": "command", "command": "~/.local/bin/limitbar-statusline <your existing status line command>"}

Copies only the `rate_limits` object from Claude Code's status-line JSON (no paths, no session data) to
~/Library/Application Support/Limitbar/latest.json, so Limitbar can show limits when its own token has expired.
Then runs the wrapped command with the same stdin and passes its output through. Any failure in the copy is
ignored: the wrapped status line always runs.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

raw = sys.stdin.buffer.read()

try:
    limits = json.loads(raw).get("rate_limits")
    if isinstance(limits, dict) and limits:
        folder = os.path.expanduser("~/Library/Application Support/Limitbar")
        os.makedirs(folder, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=folder, prefix=".latest-", suffix=".json")
        with os.fdopen(fd, "w") as f:
            json.dump({"written_at": time.time(), "rate_limits": limits}, f)
        os.replace(tmp, os.path.join(folder, "latest.json"))  # atomic: Limitbar never reads a half-written file
except Exception:
    pass

if len(sys.argv) > 1:
    sys.exit(subprocess.run(sys.argv[1:], input=raw).returncode)
