// main.swift: dependency-free test runner for the pure-Swift parts of Pasa (code folder still named Libre).
// Run with: scripts/test-relay.sh  (needs swiftc; works on macOS and Linux)

import Foundation

runRelayTests()
runMemoryTests()
runIntentTests()
await runAssistantTests()
runRuleDeleteTests()
await runRuleDeleteAssistantTests()
runTimelineTests()
runPeopleTests()
await runNameAssistantTests()
runReviewFixTests()
await runCatchUpAssistantTests()
runRobustnessTests()
await runRobustnessAssistantTests()
runRoomTests()

print("Pasa core tests: \(TestCounter.passes) passed, \(TestCounter.failures) failed")
exit(TestCounter.failures == 0 ? 0 : 1)
