# Limitbar — design

Date: 2026-11-12 · Status: approved (autonomous build authorized by Nico)

## Intent

A macOS menu bar tool that shows, at a glance, how much of the Claude session (5-hour) and weekly limits are used, and on hover or click, how long until each resets. It should be the lightest thing that does exactly that: a few hundred lines that can be read in minutes, no dependencies, nothing extra.

## Goals

- Menu bar shows the two numbers that matter, always visible: `52% · 34%` (session · weekly).
- Hover shows every limit with its reset countdown and local reset time.
- Click opens a native menu with the same rows plus Refresh, Start at Login, Quit.
- Uses the login Claude Code already keeps; no separate sign-in, no stored secrets of its own.

## Non-goals

- Token counting from local transcripts, per-model charts, cost estimates, forecasts.
- Other providers (Codex, Cursor, …).
- Notifications, settings window, Dock icon.
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

- `Sources/Core.swift` — pure, testable: `Limit` model, `parseUsage(Data) -> [Limit]` (prefers `limits`; fills any limit it lacks from `five_hour` / `seven_day` / non-null `seven_day_*`; skips unknown kinds), `countdown`, `barParts`, `tooltip`, and the poll scheduler (`PollState`, `shouldFetch`, `shouldFetchOnOpen`, `nextState`).
- `Sources/main.swift` — AppKit: status item, Keychain read, async fetch, timers, menu, login item.
- `Tests/main.swift` — plain assertion runner compiled with `Core.swift`; `./test.sh` runs it.
- `build.sh` — compiles, bundles `Limitbar.app`, ad-hoc signs, installs to `~/Applications`, relaunches.

**Menu bar title**: `S% · W%` in monospaced digits (session · weekly-all). A number at ≥90% or with non-`normal` severity is tinted red. No data yet: `…`; no data at all because of an error: `—`.

**Tooltip** (one line per limit, local time):

```
Session 52% · resets in 1h 28m (22:20)
Weekly 34% · resets in 6d 7h (Wed 20:00)
Fable weekly 0% · resets in 6d 7h (Wed 20:00)
```

**Click menu** (rebuilt each time it opens, so countdowns are current):

```
Session        52%   resets in 1h 28m (22:20)
Weekly         34%   resets in 6d 7h (Wed 20:00)
Fable weekly    0%   resets in 6d 7h (Wed 20:00)
──────────
Updated 19:58 · Team            (or the error, e.g. "Login expired — run Claude Code to renew")
Refresh                     ⌘R
Open Usage Page…
Start at Login              ✓
Quit Limitbar               ⌘Q
```

**Refresh cadence**: fetch at launch, then every 5 minutes; also on menu open or wake from sleep if the last attempt is over 60 s old; also once right after a reset time passes (compared with the last attempt, so a failing fetch never retries every tick). Title and tooltip re-render every 60 s from cached data. HTTP 429 doubles the interval (cap 30 min, at least `Retry-After`) and the backoff holds until a success; while backing off, menu-open and reset refetches are suppressed. Requests use an ephemeral `URLSession` (no cookies, no cache), a 10 s request and resource timeout, and refuse redirects so the bearer token can't follow one.

**Errors**: no Keychain item → "No Claude Code login found"; Keychain access denied → polling pauses until a manual Refresh (no repeated dialogs); expired token or 401 → "Login expired — run Claude Code to renew"; 403 → "This login can't read usage (403)"; other → "Usage service unavailable (code)". Last good values stay in the bar with a trailing `!`, except a limit whose reset time has passed since the fetch: it shows `–` and "reset, waiting for new numbers", never an old number.

**Start at Login**: `SMAppService.mainApp`; when macOS answers `.requiresApproval`, the item shows mixed state and opens Login Items settings.

**Build**: `swiftc -swift-version 5 -target <arch>-apple-macos13.0`, assembled in a temp folder and swapped into `~/Applications` only after compile and `codesign` succeed.

## Left to the builder

Exact countdown wording below one minute ("resets in <1m"), label for model-scoped weekly limits (`<display_name> weekly`), and README structure.

## Revisions after review (2026-11-12)

An independent review found no security issues and ten should-fix items, all applied: reset refetch keyed to the last attempt, pause on Keychain denial, safe build swap, explicit macOS 13 target, stale numbers hidden after a reset, 403 separated, login-item approval state, unknown limit kinds skipped, per-kind legacy fallback, redirects refused. Keychain access then moved from `SecItemCopyMatching` (one dialog per build) to `/usr/bin/security` (none).

Found while verifying: Little Snitch silently drops connections from a newly built, ad-hoc-signed binary (a compiled control probe timed out the same way while the same code under `swift` got a reply). The user has to allow Limitbar to reach `api.anthropic.com` once; the README says so.
