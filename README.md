# Limitbar

Your Claude session and weekly limits, always visible in the macOS menu bar.

```
52% · 34%
```

The first number is your 5-hour session limit, the second your weekly limit, in Claude orange. A number turns red at 90% or when Claude flags the limit. The numbers dim when they may be out of date (over 10 minutes old, or the last update failed); the menu says why.

**Hover** for when they reset:

```
Session resets in 1h 28m (22:20)
Weekly resets in 6d 7h (Wed 20:00)
```

A line is added below only when something is wrong, such as an expired login.

**Click** for every limit, including model-scoped ones such as Fable weekly, with its percentage and reset countdown; your pace for session and weekly ("52% used, 30% of window elapsed — ahead of pace, runs out ~21:40"); when the numbers were last updated, Refresh (⌘R), a link to Claude's usage page, **Settings…** (⌘,), and Quit.

**Settings** is one small window where every change applies at once:

- **Menu bar**: show when the session resets (`52% · 34% · 1h28m`), the mid-dot between numbers, the % sign, and Claude orange (off: the menu bar's own colour; hot limits stay red), with a live preview.
- **Notifications**: off until you turn them on (macOS asks permission the first time). Then each limit, Fable weekly included, has its own switch and its own percentages, `80, 95` by default; each notifies once per window. A separate switch sends "Session reset" when a session that passed its first percentage resets.
- **General**: Start at login.

That's all it does. Three Swift files, no dependencies, no Dock icon.

## Requirements

- macOS 13 Ventura or newer.
- [Claude Code](https://claude.com/claude-code) installed and signed in with a Claude subscription (Pro, Max, Team). Limitbar uses its login. Enterprise accounts may get no usage data back.
- Python 3 (for the optional status-line wrapper; macOS ships it with the command line tools).
- Apple's command line tools for `swiftc`: `xcode-select --install` if `swiftc --version` fails.

## Install

```bash
git clone https://github.com/nicojan/limitbar.git
cd limitbar
./build.sh
```

This builds `~/Applications/Limitbar.app` and opens it. Click it, open **Settings…** and turn on **Start at login**.

If you run a network filter such as Little Snitch or LuLu, allow **Limitbar** to connect to `api.anthropic.com` on port 443. Some filters silently drop new, self-built apps, which shows up as "Offline (The request timed out.)" in the menu, and after three timeouts in a row as "Can't reach api.anthropic.com — check Little Snitch or your firewall allows Limitbar".

To update: `git pull && ./build.sh`. A failed build leaves the installed copy untouched.

To check it from a terminal without the menu bar:

```bash
~/Applications/Limitbar.app/Contents/MacOS/Limitbar --once
```

## How it works

1. Reads the access token Claude Code stores in your login Keychain (`Claude Code-credentials`), through Apple's `security` tool, the same tool Claude Code saves it with, so macOS shows no Keychain dialog. Read-only: Limitbar never refreshes or rewrites it, because refreshing would sign Claude Code out.
2. Calls `GET https://api.anthropic.com/api/oauth/usage`, the same endpoint Claude Code's `/usage` uses, with that token.
3. Shows the `limits` from the reply (session, weekly, and any model-scoped weekly limit such as Fable or Opus), falling back to the older `five_hour` / `seven_day` fields.

It fetches at launch, every 5 minutes, when you open the menu or wake the Mac if the data is over a minute old, and once right after a limit resets. If Claude answers "too many requests", it backs off: doubling up to 30 minutes, longer if Claude's `Retry-After` asks (up to 6 hours). Without a network it retries after 15 s, 30 s and 60 s.

## Limits of the approach

- **The endpoint is undocumented.** Anthropic can change or remove it at any time; if the reply stops making sense the menu says so and the bar shows `—`.
- **The token expires a few hours after Claude Code last ran.** Limitbar then shows your last numbers dimmed, with a calm "Login expired — run Claude Code to renew" in the menu (a limit whose window has reset since shows `–` rather than an old number). Running any Claude Code command renews it, and Limitbar picks it up on its next fetch. The optional status-line wrapper below can fill in while Limitbar's own request fails, with whatever your Claude Code sessions last reported.
- **It only knows what the endpoint reports**: no token counts or history. The pace projection is a straight line from the window so far. For those, see [CodexBar](https://github.com/steipete/CodexBar) or the upstream project below.

## Optional: numbers from Claude Code's status line

Claude Code passes your limits to custom status-line commands. `./build.sh` installs a small wrapper (Python 3), `~/.local/bin/limitbar-statusline`, which copies just the session and weekly percentages and reset times to `~/Library/Application Support/Limitbar/latest.json`, then hands over to your existing status line, which runs exactly as before. When Limitbar's own request fails (an expired token, a rate-limit backoff), it uses those numbers, with no token or network. It merges them per window, so an idle session re-sending old numbers never replaces newer ones. To turn it on, wrap your status line command in `~/.claude/settings.json`, in single quotes:

```json
"statusLine": { "type": "command", "command": "~/.local/bin/limitbar-statusline 'your existing command'" }
```

Pipes, `;`, `$(…)` and variables inside the quotes work as before. With no existing status line, use `~/.local/bin/limitbar-statusline` alone (it prints nothing).

## Privacy

The token is read into memory for each request and sent only to `api.anthropic.com`; redirects are refused so it can't be forwarded anywhere else. Nothing is logged or written to disk (the optional status-line wrapper writes only the limit percentages and reset times), and requests use an ephemeral session with no cookies or cache. Requests identify themselves as `Limitbar/1.0`. The only other thing Limitbar opens is `claude.ai/settings/usage` in your browser, when you ask it to.

## Development

```bash
./test.sh                     # parsing and formatting tests (Sources/Core.swift)
LIMITBAR_OUT=.build ./build.sh    # build without installing or launching
```

`Sources/Core.swift` is pure logic (parsing, countdowns, tooltip text, when to fetch) and is what the tests cover. `Sources/main.swift` is the AppKit shell and `Sources/Settings.swift` the settings window: status item, Keychain read, network, timers, menu. The design is in [`docs/superpowers/specs/2026-11-12-limitbar-design.md`](docs/superpowers/specs/2026-11-12-limitbar-design.md); known issues and planned work are in [`docs/BACKLOG.md`](docs/BACKLOG.md).

## Credits

A trimmed fork of [L33N0tL33/claude-usage-menubar](https://github.com/L33N0tL33/claude-usage-menubar) (MIT), which also offers local token counting from Claude Code's transcripts and a richer panel. Limitbar drops those to keep only the limits and reset times.

Not affiliated with Anthropic. MIT licensed.
