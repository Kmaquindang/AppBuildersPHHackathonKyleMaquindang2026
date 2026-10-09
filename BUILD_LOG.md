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
