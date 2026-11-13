# Limitbar backlog

Open work only; fixed items are deleted. Everything from the 2026-11-12 review is done except what is listed here (state as of `973feb9`).

## Next

- **Distribution.** Today it is build-from-source only (ad-hoc signed, `./build.sh`). Wanted: a `.dmg`, built-in updates, and `brew install`, following what Chorus does (`/Volumes/n1TB/Personal/Projects/dev/Chorus/release/DISTRIBUTION.md`, `release/homebrew/`, `release/appcast-worker/`, `docs/appcast.xml`). This changes the spec's "Signed/notarized release binaries" non-goal and the "no dependencies" claim if Sparkle comes in; decide and update both.

## Bugs

### Medium

2. **Deny may not pause polling** (`keychainData` in `Core.swift`). Only exit 128 (`errSecUserCanceled`) maps to `.accessDenied`; a refused access-list read is plausibly `errSecAuthFailed` (-25293, exit 51), which would fall into the generic failure and re-prompt every 5 min. **Waiting on one measurement:** which code `security` returns when Deny is clicked. Measured on 2026-11-12: no answer → `security` blocks until killed (now handled by the 15 s deadline, which pauses polling); item not found → 44. The Deny click itself couldn't be automated (no assistive access) and two attempts were answered with Allow. Run the throwaway-keychain probe (`security find-generic-password` on an item that trusts only `/usr/bin/true`, click Deny), then map that code to `.accessDenied` with a test.

## Still to confirm

- **Little Snitch rule for each new build.** Every rebuild gets a new ad-hoc signature, and Little Snitch silently drops it until Limitbar → `api.anthropic.com:443` is allowed again. Symptom: `—` and "Offline (The request timed out.)". Check with `~/Applications/Limitbar.app/Contents/MacOS/Limitbar --once`.
- **Notification delivery** from the ad-hoc-signed app: turn on Settings → Send notifications once and confirm macOS asks and a notice arrives. The permission request could not be clicked through in an unattended session.
- **Status-line fallback, live.** The per-window merge is unit-tested and the wrapper was seen writing real numbers, but Limitbar showing them during a failed fetch hasn't been watched end to end.
- **Inactive-display dimming of the orange title.** Only indirect evidence (another app's coloured text dims there); Limitbar sits in the overflow on Nico's other displays. A light menu bar was assessed by contrast numbers, not seen.

## Deferred

- **The API's own `pace` field** (feature 1). It is null in every reply seen so far, so its shape is unknown; reading a guessed shape could show a wrong number. Limitbar computes pace itself. When a real non-null value appears, capture the reply under `Tests/fixtures/` and prefer it.
- **↑ in the bar when ahead of pace** (feature 1, optional). Left out: the menu shows pace, and the bar's optional parts are now the Settings toggles.
