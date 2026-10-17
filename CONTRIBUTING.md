# Contributing to Libre

Thanks for helping. Libre is an offline team chat with a local AI on a Mac. Read the [README](README.md) and [docs/HANDOFF.md](docs/HANDOFF.md) first.

## Ways to help
- Run a device test and file a report (use the "Device test report" issue template). Real measurements are the most useful thing right now.
- Pick an issue labeled `good first issue` or `help wanted`.
- Report bugs with steps to reproduce.

## Build and test
- **Swift core on Linux or macOS:** `swift build --product PasaCoreTests && ./.build/debug/PasaCoreTests`. Views and Mesh need Apple frameworks and only build in Xcode.
- **Mac and iPhone apps:** `xcodebuild -project Libre.xcodeproj -scheme Libre-macOS CODE_SIGNING_ALLOWED=NO` and `-scheme Libre-iOS`. XcodeGen is not used: add new Swift files to `Libre.xcodeproj/project.pbxproj` for both targets.
- **Android:** JDK 17 and the Android SDK, then `cd android && ./gradlew testDebugUnitTest`.
- Run the Swift and Kotlin suites before opening a pull request and paste the counts in the PR.

## Rules
- **Wire format changes update both sides.** Any change to framing, the Bluetooth hello, sealing or message JSON must update Swift and Kotlin together, plus both test vector files (`android/app/src/test/resources/swift_vectors.json` and `kotlin_vectors.json`). The cross-language tests must pass.
- **Write your own code.** Do not copy or closely port code from bitchat or any GPL project (bitchat-android is GPL v3). Reading public docs for ideas is fine. Only contribute code you have the right to license under MIT.
- **Synthetic data only.** Tests, fixtures, screenshots, logs and issues use made-up names and content (for example Ana, PATIENT_A). Never include real people's messages, device ids, Apple team ids or machine names.
- **Apple Human Interface Guidelines.** Semantic colors and text styles, 44 pt targets, VoiceOver labels, Dynamic Type. Text is never truncated or clipped: it wraps.
- **Honest claims.** Do not add a speed, range or battery number to the README unless it was measured on a real device, with the date and device. Label untested features.
- **No em dashes in docs prose.** Use periods, commas or parentheses.

## Pull requests
- One issue per pull request, on its own branch, with tests.
- `main` is protected. Every pull request needs the owner's approval before it can merge. Nothing merges without it.
- Use the pull request template. By contributing you agree your work is licensed under the MIT License.

## Conduct
This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
