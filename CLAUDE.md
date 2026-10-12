# CLAUDE.md

Start with [docs/HANDOFF.md](docs/HANDOFF.md): what Libre is, architecture, how to build and test (Linux Swift tests, Mac xcodebuild, Kotlin tests, cross-language vectors), what is tested vs untested, and the rules.

The short version of the rules:
- Never copy bitchat code (bitchat-android is GPL v3). Our own code only.
- Synthetic data only. No device ids, team ids or personal info in code, docs or issues.
- XcodeGen is not installed: add new Swift files to `Libre.xcodeproj/project.pbxproj` by hand.
- Wire changes update Swift and Kotlin and both vector files.
- Apple HIG, no truncated text. No em dashes in prose.
- README stays honest: never claim a speed or result that was not measured on a device.

Open work: GitHub issues in this repo.
