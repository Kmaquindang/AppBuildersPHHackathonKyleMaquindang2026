# Build log (times PHT, Oct 9 to 10, 2026)

All code in this repo was written during the AppBuildersPH Hackathon 2026, after the 1:00 PM Oct 9 kickoff. No pre-existing project code is used.

## Tools in use (running list for disclosures)
- AI development tool: Grok Bot (agent "Remy"), writing and testing code from Kyle's direction.
- Local model runtime: Ollama (model TBD after testing).
- Apple frameworks: SwiftUI, MultipeerConnectivity (to be confirmed).
- Design inspiration (no code used): bitchat whitepaper.

## Log
- Oct 9, 4:27 PM: Repo created under Kyle's personal account. Scope: offline device-to-device mesh team chat with a local AI executive assistant (notes, to-dos, team knowledge base). Mac (M3, 16 GB) is the AI peer and source of truth; iPhone 14 Pro Max and iPhone 12 are mesh clients.
- Oct 9, 4:33 PM: Milestone 1 started (prove the mesh). Plan: SwiftUI multiplatform app (iOS 17+, macOS 14+), MultipeerConnectivity as the link layer, our own relay layer on top.
- Oct 9, 4:33 PM: Wrote `MeshMessage` (Codable: id, origin, destination, kind, body, ttl 7, hop path, createdAt, replyTo, replyPath) and `RelayEngine` (dedup cache with 5 min expiry and 1000 entry cap, ttl forwarding, path exclusion, store-and-forward outbox with 15 min expiry). Pure Swift so it runs on Linux.
- Oct 9, 4:33 PM: Wrote a dependency-free test runner that simulates line, triangle and chain topologies, including the forced-relay ask and answer round trip (A -> B -> Mac and back). Result on Linux with Swift 6.0.3: 40 passed, 0 failed.
- Oct 9, 4:33 PM: Wrote `MeshTransport` (MultipeerConnectivity advertiser, browser, encrypted session, auto invite with a name tie-break, auto accept, block list enforced at invite, accept and receive) and `MeshService` (main-actor glue, relaying, outbox flush on link, round-trip timing, Mac AI peer with an echo stub behind the `AIResponder` protocol).
- Oct 9, 4:33 PM: Wrote the SwiftUI screens: peer chips with link state, timeline with hop path and timing, Chat or Ask AI composer, settings for device name, AI peer toggle (Mac) and block list.
- Oct 9, 4:33 PM: Added `project.yml` (XcodeGen), Info.plists with Local Network and Bonjour keys, macOS sandbox network entitlements, and generated `Libre.xcodeproj`. Apple frameworks cannot compile on Linux, so the non-UI Swift files were typechecked against small local stand-ins for MultipeerConnectivity in Swift 5 and Swift 6 modes (clean). SwiftUI views were reviewed by hand; first real compile happens on Kyle's Mac.
- Oct 9, 4:33 PM: Wrote `docs/SETUP.md` (XcodeGen path, manual Xcode path, iPhone trust steps, demo script) and filled the README for milestone 1.
- Oct 9, 4:41 PM: Milestone 2 started (Mac AI peer as the team's executive assistant, all local through Ollama).
- Oct 9, 4:41 PM: Wrote `OrgMemory` (tasks, notes, rules and skills, chat log; admin-only edit, lock and unlock; versioned history; newest-version-wins merge for phone caches; JSON file in Application Support), `NameMatcher` and `Roster` (person to device), `Compactor` (300 character first packet, rest on "@libre more") and `MeshPayload` (task and rule JSON inside mesh messages).
- Oct 9, 4:41 PM: Wrote `OllamaClient` (non-streaming /api/chat on 127.0.0.1:11434, think:false plus /no_think for Qwen3, JSON mode, fallback model, clear "Start Ollama on the Mac" error, /api/tags health check) and `ExecutiveAssistant` (fast paths, one JSON classification call, grounded answers with citations, catch-up, notes to tasks).
- Oct 9, 4:41 PM: Tests now cover relay, memory permissions and versioning, intent decoding, Ollama request shaping and the assistant end to end with a scripted fake model: 157 passed, 0 failed on Linux (Swift 6.0.3). Non-UI code typechecked with local MultipeerConnectivity stand-ins, including the macOS-only branches, in Swift 5 and Swift 6 modes.
- Oct 9, 4:41 PM: Mesh service now sends tasks to the assignee's device, broadcasts rules, and syncs rules and tasks when a device links. New tabs: Tasks, Rules, and a Mac Assistant dashboard with model, latency and tokens per second. Quick actions on phones. Regenerated `Libre.xcodeproj`.
- Oct 9, 4:41 PM: No model speed numbers yet. They will be measured on the MacBook Air M3 and added to the README from real runs only.
- Oct 9, 5:18 PM: Renamed the product from Libre (working name) to Pasa, Tagalog for "pass it on", Kyle's pick because each phone passes the message on. Display name Pasa on iPhone and Mac (CFBundleDisplayName and CFBundleName), `@pasa` is the assistant mention with `@libre` kept as an alias, prompts and on-screen text say Pasa. Bundle ids, Bonjour service `libre-mesh`, Xcode targets and schemes (`Libre-iOS`, `Libre-macOS`), saved settings keys and the Application Support folder keep the Libre name so signing and saved data keep working. project.pbxproj unchanged. Core tests: 165 passed, 0 failed on Linux (Swift 6.0.3).
- Oct 9, 5:40 PM: Commit e31edd9: reconnect watchdog, peer pruning, one chat with @pasa, display names and name-based task routing, persistent timeline and outbox with Mac backfill, admin rule delete with tombstones, messenger bubbles with Markdown, Ollama warm-up. 222 core tests pass on Linux; both targets compile on the Mac with xcodebuild.
