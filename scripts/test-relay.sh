#!/usr/bin/env bash
# Compiles the pure-Swift core of Libre (relay, memory, assistant logic) with the test runner and runs it.
# Works on macOS (Xcode command line tools) and Linux (swift.org toolchain). No Ollama needed: tests use a fake model.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -swift-version 5 \
  Libre/Sources/Core/*.swift \
  Libre/Sources/AI/*.swift \
  Tests/CoreTests/*.swift \
  -o build/libre-core-tests
./build/libre-core-tests
