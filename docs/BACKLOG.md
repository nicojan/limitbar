# Limitbar backlog

From a code review on 2026-11-12 (independent bug hunt plus a UX/feature pass) and Nico's follow-up requests. Nothing here is fixed yet as of `f5fb9f5`. Line numbers refer to that commit.

## Requested changes (Nico, 2026-11-12)

- **Claude orange text.** Menu bar numbers in Claude orange (`#D97757`, the colour upstream used: RGB 0.85 / 0.47 / 0.34) instead of the label colour. Hot limits (≥90% or non-normal severity) stay red. Because orange is now the normal colour, the "amber at 75%" idea below is dropped.
- **Tooltip shows reset times only.** Hover gives the time until reset for session and weekly, no percentages (they're already in the bar). Target:

  ```
  Session resets in 1h 28m (22:20)
  Weekly resets in 6d 7h (Wed 20:00)
  ```

  Model-scoped limits (e.g. Fable weekly) move to the click menu only. A status line is appended only when something is wrong (e.g. "Login expired — run Claude Code to renew").

## Bugs

### High

1. **Permanent freeze if `security` blocks** (`Sources/main.swift:37-39`, `:155-156`, `:170`). `readDataToEndOfFile()` / `waitUntilExit()` have no deadline. If the read hangs on a SecurityAgent dialog (locked keychain, or Claude Code re-creating the item so its access list no longer trusts `/usr/bin/security`), `inFlight` stays true forever: every fetch, including Refresh, no-ops; `onTick` takes the fetch branch and never re-renders, so countdowns freeze and reset sessions keep old numbers. Fix: terminate the child after ~15 s and map it to a failure; make `onTick` always render; make Refresh visibly report or supersede a stuck attempt.

### Medium

2. **Deny may not pause polling** (`main.swift:44-46`). Only exit 128 (`errSecUserCanceled`) maps to `.accessDenied`. A refused access-list read is plausibly `errSecAuthFailed` (-25293, `security` exit 51), which falls into the generic failure and re-prompts every 5 min. Fix: treat 51 as denied too; give 36 (`errSecInteractionNotAllowed`) a "Keychain is locked" message. Unverified which code Deny produces; check by testing.
3. **Wake leaves "Offline" for 5 minutes** (`main.swift:150-161`, `Core.swift:153-156`). One attempt 5 s after wake; Wi-Fi often isn't back, it fails with -1009, and the next try is 300 s later. The overdue 60 s timer can also fire inside the grace window, making `wakeDelay` useless. Fix: short retry backoff after wake or any offline error (e.g. 15 s, 30 s, 60 s, then normal), or `waitsForConnectivity` / `NWPathMonitor`; keep the timer from fetching during the post-wake grace window.
4. **A fetch that straddles a reset shows the old number as current** (`Core.swift:18-21`, `main.swift:178`). `fetchedAt` is taken when the reply arrives, but `isStale` needs `resetsAt > fetchedAt`. Request at 05:19:59, reset at 05:20:00, reply at 05:20:01: the old 93% shows as live with "resetting now", indefinitely if the next fetch fails. Fix: treat any `resetsAt <= now` as stale regardless of fetch time (simplest), or stamp `fetchedAt` with the request start.
5. **Scoped limit can appear twice** (`Core.swift:77`, `:88`). Legacy dedupe matches labels exactly; legacy labels come from key names (`seven_day_sonnet` → "Sonnet weekly"), new ones from `display_name` ("Sonnet 4.5"). Fix: if `limits` has any `weekly_scoped` entry, drop all legacy scoped entries; fill from legacy per kind, not per label. Add a test with mismatched names.

### Low

6. **`Retry-After` over 30 min is clipped** (`Core.swift:166`). Spec says "cap 30 min, at least Retry-After". Fix: cap only the doubling.
7. **Open menu may miss a fast result** (`main.swift:185`, `:214-219`). `menuOpen` is set in `menuWillOpen` but the fetch starts in `menuNeedsUpdate`. Fix: set the flag in `menuNeedsUpdate`, or always rebuild the menu after a fetch.
8. **Time zone changes ignored until relaunch** (`Core.swift:99-104`, `main.swift:240`). Fix: `.autoupdatingCurrent` calendar/locale, or observe `NSSystemTimeZoneDidChange`.
9. **Absurd numeric `resets_at` crashes** (`Core.swift:46`, `:100`): `Int(…)` traps on huge or infinite intervals. Fix: reject reset dates more than ~1 year out in `parseReset`.
10. **"Updated 19:58" has no day** (`main.swift:240-241`). Yesterday's data reads as today. Fix: relative ("Updated 2 h ago") or add weekday when not today.
11. **`build.sh` pitfalls** (`build.sh:7`, `:17-21`). `pkill` then immediate `open` can race LaunchServices; `pkill -x Limitbar` also kills a `--once` run or a `.build` dev copy; the generic `OUT` env var can silently redirect the build if set elsewhere; a relative `OUT` resolves against the repo. Fix: wait for the process to exit before `open`, kill only the installed path, rename to `LIMITBAR_OUT`, resolve it before `cd`.
12. **Menu columns and bar dimming** (`main.swift:224`, `:198`). Fixed tab stops (130/145 pt) break with long labels; measure the widest label instead. Setting an explicit bar colour may stop the title dimming on an inactive display's menu bar; with the orange change, check that it still dims, or dim it explicitly.

## UX

- **Stale data: dim instead of `!`.** Dim the bar text (orange at reduced alpha) when the data is over ~10 min old or the last fetch failed; drop the cryptic ` !`. The menu says why.
- **Expired login is normal, not an error.** Overnight expiry is routine; show it calmly (dimmed bar, neutral menu line), not as a warning.
- **Firewall hint.** After 3 consecutive timeouts, the menu says "Can't reach api.anthropic.com — check Little Snitch or your firewall allows Limitbar". (Little Snitch silently drops new ad-hoc builds on Nico's Mac.)
- **Relative "Updated" time** (see bug 10).

## Features, by value for the effort

1. **Pace indicator.** Used % against elapsed % of the window, shown in the menu (and optionally a small ↑ in the bar when ahead of pace): "52% used, 30% of window elapsed — ahead of pace, runs out ~21:40". Window lengths: session 5 h, weekly 7 d; elapsed = window − time to reset. Pure logic in `Core.swift`, fully testable. The API's `pace` field is null today; prefer it when present.
2. **Notifications.** At 80% and 95% per limit (once per window), and "Session reset" when a session you'd pushed past 80% resets. `UNUserNotificationCenter`; ask permission on first use; menu toggle.
3. **Status-line fallback when the token is expired.** Claude Code passes `rate_limits` (five_hour / seven_day with epoch `resets_at`) to custom status-line commands on stdin. A tiny status-line wrapper can write that JSON to `~/Library/Application Support/Limitbar/latest.json`; Limitbar reads it when the API path fails, with no network or token. Needs care to chain with an existing status line, not replace it.
4. **Optional session countdown in the bar** (`52% · 34% · 1h28m`) or remaining-instead-of-used. Each adds a setting; only if wanted.

## Still to confirm

- Little Snitch rule for `~/Applications/Limitbar.app` → `api.anthropic.com:443`. Until it exists the installed app shows `—` and "Offline (The request timed out.)". Check with `~/Applications/Limitbar.app/Contents/MacOS/Limitbar --once`.
