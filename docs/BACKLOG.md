# Limitbar backlog

From a code review on 2026-11-12 (independent bug hunt plus a UX/feature pass) and Nico's follow-up requests. Line numbers refer to `f5fb9f5` and drift as items are fixed. Fixed items are deleted.

## Bugs

### Medium

2. **Deny may not pause polling** (`keychainData` in `Core.swift`). Only exit 128 (`errSecUserCanceled`) maps to `.accessDenied`; a refused access-list read is plausibly `errSecAuthFailed` (-25293, exit 51), which would fall into the generic failure and re-prompt every 5 min. **Waiting on one measurement:** which code `security` returns when Deny is clicked. Measured on 2026-11-12: no answer → `security` blocks until killed (now handled by the 15 s deadline, which pauses polling); item not found → 44. The Deny click itself couldn't be automated (no assistive access) and two attempts were answered with Allow. Run the throwaway-keychain probe (`security find-generic-password` on an item that trusts only `/usr/bin/true`, click Deny), then map that code to `.accessDenied` with a test.

## Features

3. **Status-line fallback when the token is expired.** Claude Code passes `rate_limits` (five_hour / seven_day with epoch `resets_at`) to custom status-line commands on stdin. A tiny status-line wrapper can write that JSON to `~/Library/Application Support/Limitbar/latest.json`; Limitbar reads it when the API path fails, with no network or token. Needs care to chain with an existing status line, not replace it.
4. **Optional session countdown in the bar** (`52% · 34% · 1h28m`) or remaining-instead-of-used. Each adds a setting; only if wanted.

## Still to confirm

- Little Snitch rule for `~/Applications/Limitbar.app` → `api.anthropic.com:443`. Until it exists the installed app shows `—` and "Offline (The request timed out.)". Check with `~/Applications/Limitbar.app/Contents/MacOS/Limitbar --once`.

## Deferred

- **The API's own `pace` field** (feature 1). It is null in every reply seen so far, so its shape is unknown; reading a guessed shape could show a wrong number. Limitbar computes pace itself. When a real non-null value appears, capture the reply under `Tests/fixtures/` and prefer it.
- **↑ in the bar when ahead of pace** (feature 1, optional). Left out to keep the bar two numbers; the menu shows pace.
