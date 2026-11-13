# Limitbar

macOS menu bar app: Claude session and weekly limit percentages, reset countdowns on hover and click. Trimmed fork of L33N0tL33/claude-usage-menubar (remote `upstream`).

- `Sources/Core.swift` is pure logic and must stay AppKit-free so `./test.sh` can compile it alone with `Tests/main.swift`. Put anything testable there.
- `Sources/main.swift` is the AppKit shell. The Keychain is read via `/usr/bin/security` (the item already trusts it, so no dialog, even after a rebuild), off the main thread.
- Never refresh or write the `Claude Code-credentials` token. Rotating it signs Claude Code out.
- The usage endpoint is undocumented. When its shape changes, capture a real reply (it holds no token, but check before committing), add it under `Tests/fixtures/`, and test against it.
- Check: `./test.sh`, then `OUT=$PWD/.build ./build.sh`. Install: `./build.sh`.
- Design and scope: `docs/superpowers/specs/2026-11-12-limitbar-design.md`. Non-goals there are deliberate: no token counting, no other providers, no settings window.
- Little Snitch on this machine silently drops new ad-hoc-signed binaries ("Offline (The request timed out.)"). Allow Limitbar to api.anthropic.com:443 before debugging the network code.
