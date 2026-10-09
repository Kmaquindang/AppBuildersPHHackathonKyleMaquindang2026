#!/usr/bin/env bash
# Pasa QA harness (macOS, feature-freeze self-test): real ExecutiveAssistant, compaction, daily
# summary, vision and voice code against LOCAL Ollama only. Synthetic data. Never pulls models.
# Usage: scripts/qa-harness.sh [case ...]        (a..k, m, all)
#        scripts/qa-harness.sh voice <audio file>
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(uname)" = "Darwin" ] || { echo "qa-harness.sh runs on the AI Mac (macOS)." >&2; exit 2; }
mkdir -p build
if [ "${1:-}" = "voice" ]; then
  swiftc -swift-version 5 -O Libre/Sources/Core/*.swift Libre/Sources/AI/VoiceAsk.swift Libre/Sources/Mesh/VoiceTranscriber.swift Tools/QAVoice/main.swift -o build/pasa-qa-voice
  shift; ./build/pasa-qa-voice "$@"; exit $?
fi
curl -s --max-time 3 http://127.0.0.1:11434/api/version >/dev/null || { echo "Ollama is not running on 127.0.0.1:11434." >&2; exit 1; }
swiftc -swift-version 5 -O Libre/Sources/Core/*.swift Libre/Sources/AI/*.swift Libre/Sources/Mesh/VisionImage.swift Tools/QAHarness/main.swift -o build/pasa-qa-harness
./build/pasa-qa-harness "$@"
