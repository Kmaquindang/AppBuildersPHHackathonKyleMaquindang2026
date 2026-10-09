// main.swift: dependency-free test runner for the pure-Swift parts of Libre.
// Run with: scripts/test-relay.sh  (needs swiftc; works on macOS and Linux)

import Foundation

runRelayTests()
runMemoryTests()
runIntentTests()
await runAssistantTests()

print("Libre core tests: \(TestCounter.passes) passed, \(TestCounter.failures) failed")
exit(TestCounter.failures == 0 ? 0 : 1)
