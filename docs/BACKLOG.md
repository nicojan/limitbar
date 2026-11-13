# Limitbar backlog

From a code review on 2026-11-12 (independent bug hunt plus a UX/feature pass) and Nico's follow-up requests. Line numbers refer to `f5fb9f5` and drift as items are fixed. Fixed items are deleted.

## Bugs

### Medium

2. **Deny may not pause polling** (`keychainData` in `Core.swift`). Only exit 128 (`errSecUserCanceled`) maps to `.accessDenied`; a refused access-list read is plausibly `errSecAuthFailed` (-25293, exit 51), which would fall into the generic failure and re-prompt every 5 min. **Waiting on one measurement:** which code `security` returns when Deny is clicked. Measured on 2026-11-12: no answer → `security` blocks until killed (now handled by the 15 s deadline, which pauses polling); item not found → 44. The Deny click itself couldn't be automated (no assistive access) and two attempts were answered with Allow. Run the throwaway-keychain probe (`security find-generic-password` on an item that trusts only `/usr/bin/true`, click Deny), then map that code to `.accessDenied` with a test.

## UX

- **Stale data: dim instead of `!`.** Dim the bar text (orange at reduced alpha) when the data is over ~10 min old or the last fetch failed; drop the cryptic ` !`. The menu says why.
- **Expired login is normal, not an error.** Overnight expiry is routine; show it calmly (dimmed bar, neutral menu line), not as a warning.
- **Firewall hint.** After 3 consecutive timeouts, the menu says "Can't reach api.anthropic.com — check Little Snitch or your firewall allows Limitbar". (Little Snitch silently drops new ad-hoc builds on Nico's Mac.)
- **Bar colour on an inactive display and with the menu open** (was bug 12). The explicit orange may stop the title dimming on an inactive display's menu bar; check it still dims, or dim it explicitly, and that it stays readable when the menu is open, in light and dark mode.

## Features, by value for the effort

1. **Pace indicator.** Used % against elapsed % of the window, shown in the menu (and optionally a small ↑ in the bar when ahead of pace): "52% used, 30% of window elapsed — ahead of pace, runs out ~21:40". Window lengths: session 5 h, weekly 7 d; elapsed = window − time to reset. Pure logic in `Core.swift`, fully testable. The API's `pace` field is null today; prefer it when present.
2. **Notifications.** At 80% and 95% per limit (once per window), and "Session reset" when a session you'd pushed past 80% resets. `UNUserNotificationCenter`; ask permission on first use; menu toggle.
3. **Status-line fallback when the token is expired.** Claude Code passes `rate_limits` (five_hour / seven_day with epoch `resets_at`) to custom status-line commands on stdin. A tiny status-line wrapper can write that JSON to `~/Library/Application Support/Limitbar/latest.json`; Limitbar reads it when the API path fails, with no network or token. Needs care to chain with an existing status line, not replace it.
4. **Optional session countdown in the bar** (`52% · 34% · 1h28m`) or remaining-instead-of-used. Each adds a setting; only if wanted.

## Still to confirm

- Little Snitch rule for `~/Applications/Limitbar.app` → `api.anthropic.com:443`. Until it exists the installed app shows `—` and "Offline (The request timed out.)". Check with `~/Applications/Limitbar.app/Contents/MacOS/Limitbar --once`.
