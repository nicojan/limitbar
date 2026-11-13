#!/usr/bin/env -S python3 -I
"""Claude Code status-line wrapper for Limitbar.

Usage in ~/.claude/settings.json, with your existing status line command in single quotes:
    "command": "~/.local/bin/limitbar-statusline 'your existing command'"
A single argument runs through /bin/sh -c, so pipes, `;`, `$(...)` and variables work as before. Several
arguments run as a plain command. With none, it only copies.

Copies the session and weekly percentages and reset times (nothing else: no paths, no session data, no dollar
amounts) from Claude Code's status-line JSON to ~/Library/Application Support/Limitbar/latest.json, so Limitbar
can use them when its own request fails. Then it replaces itself with the wrapped command, on the same stdin,
so output, exit status and signals behave exactly as without the wrapper. A failed copy is ignored.
"""
import json
import os
import sys
import tempfile
import time

raw = sys.stdin.buffer.read()


def copy_limits(data):
    windows = {}
    for key in ("five_hour", "seven_day"):
        w = (json.loads(data).get("rate_limits") or {}).get(key)
        if isinstance(w, dict) and isinstance(w.get("used_percentage"), (int, float)):
            windows[key] = {"used_percentage": w["used_percentage"], "resets_at": w.get("resets_at")}
    if not windows:
        return
    folder = os.path.expanduser("~/Library/Application Support/Limitbar")
    os.makedirs(folder, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=folder, prefix=".latest-", suffix=".json")  # mode 0600
    try:
        with os.fdopen(fd, "w") as f:
            json.dump({"written_at": time.time(), "rate_limits": windows}, f)
        os.replace(tmp, os.path.join(folder, "latest.json"))  # atomic: Limitbar never reads a half-written file
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


try:
    copy_limits(raw)
except Exception:
    pass

args = sys.argv[1:]
if not args:
    sys.exit(0)
command = ["/bin/sh", "-c", args[0]] if len(args) == 1 else args
stdin = tempfile.TemporaryFile()  # unlinked; the wrapped command reads the same bytes Claude Code sent
stdin.write(raw)
stdin.seek(0)
os.dup2(stdin.fileno(), 0)
try:
    os.execvp(command[0], command)
except OSError as e:
    print(f"limitbar-statusline: can't run {command[0]}: {e.strerror}", file=sys.stderr)
    sys.exit(127)
