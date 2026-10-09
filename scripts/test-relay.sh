#!/usr/bin/env bash
# Compiles the pure-Swift core of Pasa (code folder Libre/, relay, rooms, memory, assistant logic) with the test runner and runs it.
# macOS (Xcode command line tools): swiftc with CryptoKit, no downloads.
# Linux (swift.org toolchain): SwiftPM with Apple's swift-crypto (fetched once by Package.swift).
# No Ollama needed: tests use a fake model.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname)" = "Darwin" ]; then
  mkdir -p build
  swiftc -swift-version 5 \
    Libre/Sources/Core/*.swift \
    Libre/Sources/AI/*.swift \
    Tests/CoreTests/*.swift \
    -o build/libre-core-tests
  ./build/libre-core-tests
else
  swift build -q --product PasaCoreTests
  ./.build/debug/PasaCoreTests
fi
