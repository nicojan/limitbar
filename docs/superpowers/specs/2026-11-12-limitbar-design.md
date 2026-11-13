# Limitbar — design

Date: 2026-11-12 · Status: approved (autonomous build authorized by Nico)

## Intent

A macOS menu bar tool that shows, at a glance, how much of the Claude session (5-hour) and weekly limits are used, and on hover or click, how long until each resets. It should be the lightest thing that does exactly that: a few hundred lines that can be read in minutes, no dependencies, nothing extra.

## Goals

- Menu bar shows the two numbers that matter, always visible: `52% · 34%` (session · weekly).
- Hover shows when the session and weekly limits reset (countdown and local time).
- Click opens a native menu with every limit (percent and reset) plus Refresh, Start at Login, Quit.
- Uses the login Claude Code already keeps; no separate sign-in, no stored secrets of its own.

## Non-goals

- Token counting from local transcripts, per-model charts, cost estimates, forecasts beyond the straight-line pace projection.
- Other providers (Codex, Cursor, …).
- Settings window, Dock icon. (Notifications were a non-goal until Nico asked for them on 2026-11-12; they are a single menu toggle, off by default.)
- Signed/notarized release binaries. Build from source with one script.

## Anti-goals

- Anything that could sign Claude Code out: the app must never refresh or write the Claude Code token.
- Hammering the undocumented endpoint (it rate-limits); polling stays slow.

## Constraints

- Data comes from `GET https://api.anthropic.com/api/oauth/usage` (undocumented, may change) with `Authorization: Bearer <token>` and `anthropic-beta: oauth-2025-04-20`.
- The token is read (read-only) from the login Keychain item `Claude Code-credentials`, JSON `claudeAiOauth.accessToken` / `expiresAt` (ms epoch) / `subscriptionType`. It is read through `/usr/bin/security find-generic-password -w`: Claude Code writes the item with that tool, so its access list already trusts it, and there is no Keychain dialog, even after a rebuild changes Limitbar's ad-hoc signature.
- The access token lives a few hours; if Claude Code hasn't run lately it is expired and the app says so instead of refreshing it.
- macOS 13+, Swift 5 language mode, `swiftc` only (Command Line Tools, no Xcode project).

Observed response (2026-11-12, Team plan): top-level `five_hour` / `seven_day` objects with `utilization` (0–100) and `resets_at` (ISO 8601 with fractional seconds and `+00:00`), many null `seven_day_*` keys, and a newer `limits` array: `{kind: session|weekly_all|weekly_scoped, percent, severity, resets_at, scope: {model: {display_name}}}`. The `limits` array carries a model-scoped weekly limit ("Fable") the legacy keys don't.

## Approaches

1. **Fork L33N0tL33/claude-usage-menubar and cut it down (picked).** It already reads the Keychain read-only and calls the endpoint correctly; strip transcript scanning, model charts, local estimate mode and the SwiftUI panel; put numbers in the bar, countdowns in the tooltip, a plain `NSMenu` on click. Smallest code that meets the goals, fully owned.
2. **Use upstream as-is.** Zero work, but the bar is icon-only, the tooltip has no reset times, exact limits are opt-in, and it rescans every transcript each minute.
3. **CodexBar via Homebrew.** Maintained and polished, but ~20 providers and a settings window: far more app than needed.

Picked 1: Nico chose the recommendation.

## Design

**Files**

- `Sources/Core.swift` — pure, testable: `Limit` model, `parseUsage(Data) -> [Limit]` (prefers `limits`; fills any limit it lacks from `five_hour` / `seven_day` / non-null `seven_day_*`; skips unknown kinds), `countdown`, `barParts`, `barSegments` / `BarStyle`, `tooltip`, `updatedText`, `pace` / `paceText`, `alertsDue`, `status` / `barDimmed`, `parseStatusLineCache`, the Keychain child-process runner with its deadline (`runTool`, `keychainData`), and the poll scheduler (`PollState`, `shouldFetch`, `shouldFetchOnOpen`, `nextState`).
- `Sources/main.swift` — AppKit: status item, Keychain read, async fetch, timers, menu, login item.
- `Tests/main.swift` — plain assertion runner compiled with `Core.swift`; `./test.sh` runs it.
- `build.sh` — compiles, bundles `Limitbar.app`, ad-hoc signs, installs to `~/Applications`, relaunches, and installs the status-line wrapper to `~/.local/bin/limitbar-statusline`.
- `scripts/statusline-tee.py` — the Claude Code status-line wrapper (see Status-line fallback).

**Menu bar title**: `S% · W%` in monospaced digits (session · weekly-all), in Claude orange (`#D97757`). A number at ≥90% or with non-`normal` severity is red. On a light menu bar the orange deepens to `#B4532F` for contrast (4.2:1 instead of 2.6:1). The whole title dims to half opacity when the numbers may be out of date: never loaded, over 10 minutes old, or the last fetch failed. On an inactive display's menu bar the system dims custom-coloured items itself (seen with another app's coloured text); with the menu open the highlight keeps the title readable (checked in dark mode). No data yet: `…`; no data at all because of an error: `—`.

**Tooltip** (reset times only, local time; the percentages are already in the bar):

```
Session resets in 1h 28m (22:20)
Weekly resets in 6d 7h (Wed 20:00)
```

Model-scoped limits appear only in the click menu. A status line is appended only when something is wrong.

**Click menu** (rebuilt each time it opens and after every fetch, so countdowns are current):

```
Session        52%   resets in 1h 28m (22:20)
Weekly         34%   resets in 6d 7h (Wed 20:00)
Fable weekly    0%   resets in 6d 7h (Wed 20:00)
──────────
──────────
Session: 52% used, 30% of window elapsed — ahead of pace, runs out ~21:40
Weekly: 34% used, 15% of window elapsed — ahead of pace, runs out ~Mon 10:05
──────────
Updated 5 min ago · Team        (or the error, e.g. "Login expired — run Claude Code to renew")
Refresh                     ⌘R
Open Usage Page…
Settings                     ▸  Show Session Reset in Bar · Mid-dot Separator ✓ · Show % Sign ✓ · Claude Orange ✓
                                ── Notify at 80% and 95% · Start at Login ✓
Quit Limitbar               ⌘Q
```

**Refresh cadence**: fetch at launch, then every 5 minutes; also on menu open or wake from sleep if the last attempt is over 60 s old; also once right after a reset time passes (compared with the last attempt, so a failing fetch never retries every tick). Title and tooltip re-render every 60 s from cached data. HTTP 429 doubles the interval (the doubling caps at 30 min; a longer `Retry-After` is honoured up to 6 h) and the backoff holds until a success; while backing off, menu-open and reset refetches are suppressed. A fetch that fails for want of a network (offline, DNS, timeout) retries after 15 s, 30 s and 60 s before returning to the 5-minute cadence; after wake the timer holds off for the 5 s grace period so the overdue tick can't fire into a dead network. Staleness is decided by the clock alone (`resets_at <= now`), so a reply that straddles a reset never shows the old number as current. The Keychain read runs `security` with a 15 s deadline: a dialog nobody answers is killed and polling pauses until Refresh, or until the screen is unlocked or the Mac wakes (one retry), so a blocked read can't freeze fetching. A last attempt in the future (the clock moved back) counts as due. Refresh supersedes any fetch still outstanding, and the title re-renders every tick regardless. Requests use an ephemeral `URLSession` (no cookies, no cache), a 10 s request and resource timeout, and refuse redirects so the bearer token can't follow one.

**Errors**: no Keychain item → "No Claude Code login found"; Keychain access denied → polling pauses until a manual Refresh (no repeated dialogs); no answer within 15 s → paused likewise, but also lifted once on screen unlock or wake; keychain locked (exit 36) → "Keychain is locked — unlock it, then click Refresh"; expired token or 401 → "Login expired — run Claude Code to renew"; 403 → "This login can't read usage (403)"; other → "Usage service unavailable (code)". Reset times more than a year out are rejected as garbage. The menu's "Updated" line is relative ("just now", "5 min ago", "2 h ago") and shows a weekday once the data is a day old. Times follow the system time zone live. Menu columns are sized to the widest label. Last good values stay in the bar, dimmed, with the reason in the menu, except a limit whose reset time has passed: it shows `–` and "reset, waiting for new numbers", never an old number. An expired login is routine (it lapses overnight), so its menu line is neutral, not a ⚠︎ warning. After 3 consecutive timeouts the menu says "Can't reach api.anthropic.com — check Little Snitch or your firewall allows Limitbar".

**Pace** (menu only, session and weekly): used % against elapsed % of the window (session 5 h, weekly 7 d; elapsed = window − time to reset). When used is ahead of elapsed, the straight-line projection hits 100% before the reset, and the menu says when: "52% used, 30% of window elapsed — ahead of pace, runs out ~21:40" (weekday added when not today). Before 5% of the window has elapsed there is no projection. At or over 100% it says "limit reached" in the normal colour, never "within pace".

**Notifications** (menu toggle "Notify at 80% and 95%", off by default, `UNUserNotificationCenter`, permission asked when first turned on): each limit, scoped ones included, notifies once per window at 80% and at 95% (jumping past both sends only 95%); "Session reset" when a session that reached 80% resets, but only within an hour of the reset, so a relaunch doesn't announce an old one. Sent keys (`label|threshold|window`, the reset time rounded to 10 minutes because `resets_at` jitters by under a second between replies) persist in `UserDefaults` and are pruned after 8 days.

**Settings submenu** (no settings window; toggles persist in `UserDefaults`): Show Session Reset in Bar (`52% · 34% · 1h28m`, off by default), Mid-dot Separator (off: `52% 34%`), Show % Sign (off: `52 · 34`), Claude Orange (off: the menu bar's own text colour; hot limits stay red either way), Notify at 80% and 95%, Start at Login.

**Status-line fallback**: Claude Code passes `rate_limits` (`five_hour` / `seven_day`, each `{used_percentage, resets_at}` in epoch seconds, either may be absent; documented at code.claude.com/docs/en/statusline) to custom status-line commands. `~/.local/bin/limitbar-statusline <existing command>` copies only that object plus `written_at` to `~/Library/Application Support/Limitbar/latest.json` (atomic rename), then runs the wrapped command with the same stdin and passes its output and exit status through; a failed copy never stops the wrapped command. When an API fetch fails, Limitbar takes session and weekly from that file if it was written after the last successful fetch (scoped limits keep their last API values), shows them dimmed, and the menu says "Updated 3 min ago · from Claude Code's status line". No token and no network are involved. The wrapper lives on the home volume so the status line works with this repo's drive unmounted.

**Start at Login**: `SMAppService.mainApp`; when macOS answers `.requiresApproval`, the item shows mixed state and opens Login Items settings.

**Build**: `LIMITBAR_OUT=<dir>` builds elsewhere without installing or launching (resolved to an absolute path first). Installing kills only the installed menu bar copy (exact command line, so a `--once` run survives) and waits for it to exit before relaunching. `swiftc -swift-version 5 -target <arch>-apple-macos13.0`, assembled in a temp folder and swapped into `~/Applications` only after compile and `codesign` succeed.

## Left to the builder

Exact countdown wording below one minute ("resets in <1m"), label for model-scoped weekly limits (`<display_name> weekly`), and README structure.

## Revisions after review (2026-11-12)

An independent review found no security issues and ten should-fix items, all applied: reset refetch keyed to the last attempt, pause on Keychain denial, safe build swap, explicit macOS 13 target, stale numbers hidden after a reset, 403 separated, login-item approval state, unknown limit kinds skipped, per-kind legacy fallback, redirects refused. Keychain access then moved from `SecItemCopyMatching` (one dialog per build) to `/usr/bin/security` (none).

Found while verifying: Little Snitch silently drops connections from a newly built, ad-hoc-signed binary (a compiled control probe timed out the same way while the same code under `swift` got a reply). The user has to allow Limitbar to reach `api.anthropic.com` once; the README says so.
