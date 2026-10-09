#!/usr/bin/env bash
# Compiles the pure-Swift relay core with the test runner and runs it.
# Works on macOS (Xcode command line tools) and Linux (swift.org toolchain).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O \
  Libre/Sources/Core/MeshMessage.swift \
  Libre/Sources/Core/RelayEngine.swift \
  Tests/RelayEngineTests/main.swift \
  -o build/relay-tests
./build/relay-tests
