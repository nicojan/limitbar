#!/bin/zsh
# Compiles the pure logic with the test runner and runs it. No Xcode needed.
set -e; cd "$(dirname "$0")"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 5 Sources/Core.swift Tests/main.swift -o "$WORK/limitbar-tests"
"$WORK/limitbar-tests"
