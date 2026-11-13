# Limitbar backlog

Open work only; fixed items are deleted. Everything from the 2026-11-12 review is done except what is listed here (state as of the 1.1.0 release).

## Bugs

### Medium

2. **Deny exit code unmeasured** (`keychainData` in `Core.swift`). Exit 128 (`errSecUserCanceled`) and, since 1.1.0, 51 (`errSecAuthFailed`, the plausible code for a refused access-list read) map to `.accessDenied`, which pauses polling and brings the Keychain notice back before the next Refresh. Any other code falls into the generic failure and would re-prompt every 5 min. **Waiting on one measurement:** which code `security` returns when Deny is clicked. Measured on 2026-11-12: no answer → `security` blocks until killed (now handled by the 15 s deadline, which pauses polling); item not found → 44. The Deny click itself couldn't be automated (no assistive access) and two attempts were answered with Allow. Run the throwaway-keychain probe (`security find-generic-password` on an item that trusts only `/usr/bin/true`, click Deny), then map that code to `.accessDenied` with a test if it isn't 128 or 51.

## Still to confirm

- **Little Snitch rule for each new source build.** Every `./build.sh` rebuild gets a new ad-hoc signature (release builds keep one Developer ID signature, so their rule survives updates), and Little Snitch silently drops it until Limitbar → `api.anthropic.com:443` is allowed again. Symptom: `—` and "Offline (The request timed out.)". Check with `~/Applications/Limitbar.app/Contents/MacOS/Limitbar --once`.
- **Notification delivery**, from an ad-hoc source build and from the Developer ID release (which may behave better): turn on Settings → Send notifications once and confirm macOS asks and a notice arrives. The permission request could not be clicked through in an unattended session.
- **Status-line fallback, live.** The per-window merge is unit-tested and the wrapper was seen writing real numbers, but Limitbar showing them during a failed fetch hasn't been watched end to end.
- **Sparkle's interactive update path.** The silent path is verified (a signed 1.0.0 (1) updated itself to 1.1.0 (2) from the live appcast on 2026-11-12). Not yet watched: Check for Updates… showing Sparkle's window in front, a scheduled check bringing its window forward and adding "Update Available: Limitbar X…" to the menu, the item clearing after the user deals with it, and Settings → Updates (automatic toggle, Check Now, version). Needs a 1.1.1 in the appcast, or an old build pointed at it as in `release/DISTRIBUTION.md`.
- **Keychain notice after Deny or no answer.** The first-run notice was seen and accepted on 2026-11-12. The retry notice (shown on Refresh after a refused or unanswered prompt) and Not Now (pauses, menu says "Waiting to read the Keychain — click Refresh") are reasoned and unit-tested, not watched.
- **Inactive-display dimming of the orange title.** Only indirect evidence (another app's coloured text dims there); Limitbar sits in the overflow on Nico's other displays. A light menu bar was assessed by contrast numbers, not seen.

## Deferred

- **The API's own `pace` field** (feature 1). It is null in every reply seen so far, so its shape is unknown; reading a guessed shape could show a wrong number. Limitbar computes pace itself. When a real non-null value appears, capture the reply under `Tests/fixtures/` and prefer it.
- **Status-line wrapper for downloaded installs.** Only `./build.sh` installs `~/.local/bin/limitbar-statusline`; a DMG or Homebrew user has no way to get it short of cloning the repo. Option: ship it in the app's Resources with a Settings button that installs it.
- **User-Agent says `Limitbar/1.0`** while the app is 1.1.0. Harmless; change it to the real version if Anthropic ever needs to tell versions apart (README's Privacy section quotes it).
- **Install counts.** The appcast is served straight from GitHub Pages, which keeps no logs. Chorus counts installs through a Cloudflare Worker (`Chorus/release/appcast-worker`); Limitbar could add a `/limitbar/` route there, but builds already shipped will always ask the Pages URL, so only later versions would be counted.
- **↑ in the bar when ahead of pace** (feature 1, optional). Left out: the menu shows pace, and the bar's optional parts are now the Settings toggles.
