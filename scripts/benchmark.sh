#!/usr/bin/env bash
# Libre benchmark: 20 fixed questions (English, Tagalog, Cebuano) over fixed synthetic team memory,
# through the app's real answer pipeline, against LOCAL Ollama only (127.0.0.1:11434).
# Never pulls models: models that are not installed are listed as skipped.
# Output: docs/benchmarks/benchmark-<date>.md and one CSV per model.
#
# Usage: scripts/benchmark.sh [model ...]     (default: qwen3:8b and the low-memory model)
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname)" != "Darwin" ]; then
  echo "benchmark.sh runs on the AI Mac (macOS). Linux CI runs the scorer tests with a fake model: scripts/test-relay.sh" >&2
  exit 2
fi
if ! curl -s --max-time 3 http://127.0.0.1:11434/api/version >/dev/null; then
  echo "Ollama is not running on 127.0.0.1:11434. Open Ollama, then run this again." >&2
  exit 1
fi
mkdir -p build docs/benchmarks
swiftc -swift-version 5 -O \
  Libre/Sources/Core/*.swift \
  Libre/Sources/AI/*.swift \
  Tools/Benchmark/main.swift \
  -o build/pasa-benchmark
chip="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
mem_gb="$(( $(sysctl -n hw.memsize) / 1073741824 ))"
model_id="$(sysctl -n hw.model 2>/dev/null || echo Mac)"
os="$(sw_vers -productVersion 2>/dev/null || echo ?)"
machine="${model_id}, ${chip}, ${mem_gb} GB, macOS ${os}"
./build/pasa-benchmark docs/benchmarks "$machine" "$@"
