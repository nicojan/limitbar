# Limitbar

Your Claude session and weekly limits, always visible in the macOS menu bar.

```
52% · 34%
```

The first number is your 5-hour session limit, the second your weekly limit, in Claude orange. A number turns red at 90% or when Claude flags the limit.

**Hover** for when they reset:

```
Session resets in 1h 28m (22:20)
Weekly resets in 6d 7h (Wed 20:00)
```

A line is added below only when something is wrong, such as an expired login.

**Click** for every limit, including model-scoped ones such as Fable weekly, with its percentage and reset countdown, when the numbers were last updated, Refresh (⌘R), a link to Claude's usage page, Start at Login, and Quit.

That's all it does. Two Swift files, about 450 lines, no dependencies, no Dock icon, no settings window.

## Requirements

- macOS 13 Ventura or newer.
- [Claude Code](https://claude.com/claude-code) installed and signed in with a Claude subscription (Pro, Max, Team). Limitbar uses its login. Enterprise accounts may get no usage data back.
- Apple's command line tools for `swiftc`: `xcode-select --install` if `swiftc --version` fails.

## Install

```bash
git clone https://github.com/nicojan/limitbar.git
cd limitbar
./build.sh
```

This builds `~/Applications/Limitbar.app` and opens it. Click it and turn on **Start at Login**.

If you run a network filter such as Little Snitch or LuLu, allow **Limitbar** to connect to `api.anthropic.com` on port 443. Some filters silently drop new, self-built apps, which shows up as "Offline (The request timed out.)" in the menu.

To update: `git pull && ./build.sh`. A failed build leaves the installed copy untouched.

To check it from a terminal without the menu bar:

```bash
~/Applications/Limitbar.app/Contents/MacOS/Limitbar --once
```

## How it works

1. Reads the access token Claude Code stores in your login Keychain (`Claude Code-credentials`), through Apple's `security` tool, the same tool Claude Code saves it with, so macOS shows no Keychain dialog. Read-only: Limitbar never refreshes or rewrites it, because refreshing would sign Claude Code out.
2. Calls `GET https://api.anthropic.com/api/oauth/usage`, the same endpoint Claude Code's `/usage` uses, with that token.
3. Shows the `limits` from the reply (session, weekly, and any model-scoped weekly limit such as Fable or Opus), falling back to the older `five_hour` / `seven_day` fields.

It fetches at launch, every 5 minutes, when you open the menu or wake the Mac if the data is over a minute old, and once right after a limit resets. If Claude answers "too many requests", it backs off up to 30 minutes.

## Limits of the approach

- **The endpoint is undocumented.** Anthropic can change or remove it at any time; if the reply stops making sense the menu says so and the bar shows `—`.
- **The token expires a few hours after Claude Code last ran.** Limitbar then shows your last numbers with a `!` and "Login expired — run Claude Code to renew" (a limit whose window has reset since shows `–` rather than an old number). Running any Claude Code command renews it, and Limitbar picks it up on its next fetch.
- **It only knows what the endpoint reports**: no token counts, history or forecasts. For those, see [CodexBar](https://github.com/steipete/CodexBar) or the upstream project below.

## Privacy

The token is read into memory for each request and sent only to `api.anthropic.com`; redirects are refused so it can't be forwarded anywhere else. Nothing is logged or written to disk, and requests use an ephemeral session with no cookies or cache. Requests identify themselves as `Limitbar/1.0`. The only other thing Limitbar opens is `claude.ai/settings/usage` in your browser, when you ask it to.

## Development

```bash
./test.sh                     # parsing and formatting tests (Sources/Core.swift)
LIMITBAR_OUT=.build ./build.sh    # build without installing or launching
```

`Sources/Core.swift` is pure logic (parsing, countdowns, tooltip text, when to fetch) and is what the tests cover. `Sources/main.swift` is the AppKit shell: status item, Keychain read, network, timers, menu. The design is in [`docs/superpowers/specs/2026-11-12-limitbar-design.md`](docs/superpowers/specs/2026-11-12-limitbar-design.md); known issues and planned work are in [`docs/BACKLOG.md`](docs/BACKLOG.md).

## Credits

A trimmed fork of [L33N0tL33/claude-usage-menubar](https://github.com/L33N0tL33/claude-usage-menubar) (MIT), which also offers local token counting from Claude Code's transcripts and a richer panel. Limitbar drops those to keep only the limits and reset times.

Not affiliated with Anthropic. MIT licensed.
