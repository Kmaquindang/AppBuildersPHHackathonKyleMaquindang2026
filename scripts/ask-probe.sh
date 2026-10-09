#!/usr/bin/env bash
# Libre latency probe: a few fixed asks through the app's real answer pipeline against LOCAL
# Ollama only (127.0.0.1:11434). Prints every model call with token counts and timings.
# Usage: scripts/ask-probe.sh [runs] [question ...]
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname)" != "Darwin" ]; then echo "ask-probe.sh runs on the AI Mac (macOS)." >&2; exit 2; fi
curl -s --max-time 3 http://127.0.0.1:11434/api/version >/dev/null || { echo "Ollama is not running on 127.0.0.1:11434." >&2; exit 1; }
mkdir -p build
swiftc -swift-version 5 -O Libre/Sources/Core/*.swift Libre/Sources/AI/*.swift Tools/AskProbe/main.swift -o build/pasa-ask-probe
./build/pasa-ask-probe "$@"
