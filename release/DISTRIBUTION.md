# Distribution

Limitbar ships three ways: build from source (`./build.sh`, ad-hoc signed, no updater), a Developer ID-signed and notarized `.dmg` with Sparkle for in-app updates, and `brew install --cask nicojan/tap/limitbar`, which installs that same DMG. It follows Chorus (`/Volumes/n1TB/Personal/Projects/dev/Chorus/release/DISTRIBUTION.md`), adapted to a `swiftc`-only build: no Xcode project, no SwiftPM.

Not sandboxed: it runs `/usr/bin/security` to read Claude Code's Keychain item, which a sandbox forbids. The Hardened Runtime is on, as notarization requires; no entitlements are needed.

## Configured values

| What | Where | Value |
|---|---|---|
| Signing identity | `release/release.sh` | `Developer ID Application: Nico Jan (3CY4DX3K45)` |
| Notary profile | `release/release.sh` | `chorus-notary` (same Apple account as Chorus; made with `xcrun notarytool store-credentials`) |
| `SUPublicEDKey` | `Info.plist` | `6/h2Pfjbo39vHie8JIt/kY7h0wQvmQxj9Ea0W3gnH0w=`, the key Chorus and WatchMeType use; the private half is in the login Keychain. Lose it and existing installs can never update again. |
| `SUFeedURL` | `Info.plist` | `https://nicojan.github.io/limitbar/appcast.xml`: `docs/appcast.xml`, served by GitHub Pages (`main`, `/docs`). Never take it down: every installed copy asks it. |
| Sparkle | `release/release.sh` | 2.10.1, the official archive checked against a pinned SHA-256, cached in `.build/` |
| DMGs | GitHub Releases | one release per version, tag `vX.Y.Z`, asset `Limitbar-X.Y.Z.dmg` |
| Cask | `release/homebrew/limitbar.rb` → `nicojan/homebrew-tap` `Casks/limitbar.rb` | |

`SUEnableAutomaticChecks` is on in `Info.plist`, so Sparkle checks once a day without first asking; Settings → Updates turns it off. The check fetches the appcast from GitHub Pages and, when there is an update, the DMG from GitHub. No system profile is sent.

Only `release/release.sh` links Sparkle. `Sources/Updater.swift` is compiled either way and is a no-op without it (`canImport(Sparkle)`), so `./build.sh` and `./test.sh` need nothing downloaded. CI runs an ad-hoc release build too, so the Sparkle side keeps compiling.

## Cutting a release

From the repo root, on a clean, pushed `main`.

1. **Bump the version** in `Info.plist`: `CFBundleShortVersionString` to `X.Y.Z` and `CFBundleVersion` to the next integer (Sparkle compares that one). Commit and push.

2. **Build**: `release/release.sh`. It compiles a universal binary with Sparkle, signs Sparkle's helpers, the framework and the app from the inside out, notarizes and staples the app, wraps it in a DMG (`hdiutil`, with an Applications link), signs, notarizes and staples the DMG, and prints the DMG's sha256 and Sparkle's `sparkle:edSignature` and `length`. The output is `build/release-X.Y.Z-N/` and the script refuses to overwrite a DMG there. If `notarytool` answers 403 "A required agreement is missing or has expired", the Account Holder must accept Apple's new agreement at developer.apple.com/account; nothing needs rebuilding.

   Check it: open the DMG, drag the app out, launch it. `spctl -a -vv` on the app should say `Notarized Developer ID`.

3. **Publish the DMG**, only after `main` is pushed (`gh release create` tags the remote's HEAD, so an unpushed bump tags the wrong commit):
   ```sh
   gh release create vX.Y.Z build/release-X.Y.Z-N/Limitbar-X.Y.Z.dmg --repo nicojan/limitbar --title "Limitbar X.Y.Z" --notes "…"
   ```

4. **Add an appcast item** at the top of `docs/appcast.xml`, by hand (`generate_appcast` can drop old items): `sparkle:version` the build number, `sparkle:shortVersionString` `X.Y.Z`, `sparkle:minimumSystemVersion` `13.0`, the enclosure URL `https://github.com/nicojan/limitbar/releases/download/vX.Y.Z/Limitbar-X.Y.Z.dmg`, and the `length` and `sparkle:edSignature` from step 2. Release notes go in a CDATA `<description>`.

5. **Update the cask**: in `release/homebrew/limitbar.rb`, set `version` and `sha256` (perl, not `sed -i ''`: `sed` here is GNU):
   ```sh
   perl -pi -e 's/version "[^"]+"/version "X.Y.Z"/; s/sha256 "[^"]+"/sha256 "NEW_SHA"/' release/homebrew/limitbar.rb
   ```
   `./test.sh` now checks the appcast against the cask and `Info.plist`. Commit both, push, and confirm Pages deployed: `curl -s https://nicojan.github.io/limitbar/appcast.xml | grep -m1 shortVersionString`.

6. **Check the published asset**: download it back from the release and compare its sha256 with the cask and its size with the appcast `length`.

7. **Update the tap**:
   ```sh
   TAP="$(brew --repo nicojan/tap)"
   cp release/homebrew/limitbar.rb "$TAP/Casks/limitbar.rb"
   git -C "$TAP" add Casks/limitbar.rb && git -C "$TAP" commit -m "limitbar X.Y.Z" && git -C "$TAP" push
   brew livecheck --cask nicojan/tap/limitbar    # must print X.Y.Z (Homebrew may first want `brew trust --cask nicojan/tap/limitbar`)
   brew style nicojan/tap
   ```
   If every `brew` command times out in `bundle install`, Little Snitch is dropping Homebrew's portable Ruby (see Chorus's notes); `ruby -c` the cask and check the hash by hand meanwhile.

## Testing an update

Build an older copy, signed but not notarized, and let it update from the published appcast:

```sh
OLD=$(mktemp -d)
cp Info.plist "$OLD/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 1' -c 'Set :CFBundleShortVersionString 1.0.0' "$OLD/Info.plist"
NOTARY_PROFILE= INFO_PLIST="$OLD/Info.plist" OUT="$OLD/build" release/release.sh
```

Then either click Check for Updates… in its menu, or, unattended: `defaults write com.nicojan.limitbar SUAutomaticallyUpdate -bool YES` and `defaults write com.nicojan.limitbar SULastCheckTime -date 2000-01-01`, launch it, wait for the download, quit it, and `Limitbar --version` shows the new version. Delete both keys afterwards (`defaults delete com.nicojan.limitbar SUAutomaticallyUpdate`, likewise `SULastCheckTime`), since the preference domain is shared with every other copy.

## Little Snitch

A Developer ID signature stays the same across releases, so one rule (Limitbar → `api.anthropic.com:443`) survives updates; ad-hoc builds from `./build.sh` still need it re-allowed after each rebuild. The update check also needs Limitbar → `nicojan.github.io:443`, and installing an update needs `github.com` and `release-assets.githubusercontent.com` (or `objects.githubusercontent.com`).

## Why not homebrew/cask

The central tap requires notability (225 stars for a self-submission), so it lives in `nicojan/homebrew-tap` with Chorus. The install command is the only difference to users.
