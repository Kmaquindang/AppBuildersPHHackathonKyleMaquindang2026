# Libre (working name)

Libre is an offline team chat for groups with no signal or no data budget: nearby iPhones and Macs form their own device-to-device mesh, messages hop from device to device, and a local AI assistant on the Mac answers the team with zero cost per question.

> Status: milestone 1 (mesh proof). Devices discover each other with no internet, messages travel through our own multi-hop relay layer, and every message shows its hop path and measured timing. The Mac AI peer currently answers with an echo stub; the local model arrives in milestone 2.

## Why does this product benefit from running AI locally?
The people we build for cannot rely on cloud AI: they have no signal, or they cannot afford mobile data. Cloud-only AI is impossible for them at the moment they need it and expensive at scale. With Libre, one laptop running a local model serves everyone in mesh range, so every question costs nothing and works with no cell towers. Team notes, rules and to-dos are private by design because they never leave the group's own devices.

## Demo
- Demo video: <link>
- X / LinkedIn post: <link>

## What runs locally
- Milestone 1: device discovery, encrypted device-to-device links, and our multi-hop relay (dedup, hop budget, store and forward), all on the devices.
- Milestone 2 (planned): an LLM answering team questions on the Mac through Ollama (model to be chosen after testing).

## What requires internet
- Nothing at runtime. Cloning the repo and (from milestone 2) a one-time model download need internet.

## How to run it (for judges)
Full step-by-step guide, including a manual Xcode path and iPhone trust steps: [docs/SETUP.md](docs/SETUP.md).

1. Install Xcode 15 or newer from the Mac App Store.
2. `git clone https://github.com/Kmaquindang/AppBuildersPHHackathonKyleMaquindang2026.git && cd AppBuildersPHHackathonKyleMaquindang2026`
3. Open `Libre.xcodeproj` (or run `xcodegen generate` first if you prefer to regenerate it from `project.yml`).
4. Pick your Team (a free Apple ID works) under Signing & Capabilities for the `Libre-macOS` and `Libre-iOS` targets.
5. Run `Libre-macOS` on your Mac. Run `Libre-iOS` on one or two iPhones (iOS 17+). On each iPhone trust the developer profile in Settings > General > VPN & Device Management, and allow Local Network access.
6. In each app open Settings and give the device a unique name. Send a chat, or switch to Ask AI.
7. To test offline: put the iPhones in Airplane Mode, then turn Wi-Fi back on without joining a network. Keep the Mac's Wi-Fi on. Messages still flow.
8. To see a real 2-hop path: on one iPhone, block the Mac in Settings. Its messages now relay through the other iPhone, and the timeline shows the full path.
9. Mac only, no iPhones: run the Mac app, switch to Ask AI and send a question; the Mac answers itself. Two Macs near each other also form a mesh.
10. Relay unit tests (macOS or Linux with Swift installed): `./scripts/test-relay.sh`

## How it works
- **Link layer:** Apple MultipeerConnectivity on service type `libre-mesh`. It opens encrypted links over peer-to-peer Wi-Fi with no router or internet. We describe this as an offline device-to-device mesh, not a Bluetooth mesh.
- **Relay layer (our code, `Libre/Sources/Core`):** every message carries an id, origin, destination (everyone, one device, or a role such as the AI), hop budget (ttl 7) and the path so far. Each device drops ids it has already seen, adds itself to the path, delivers the message if it is meant for it, and forwards a copy with ttl minus 1 to linked devices not already on the path. Messages with nobody to go to wait in an outbox and leave as soon as a device links.
- **Forced relay demo:** a per-device block list refuses direct links and drops any packet that arrives straight from a blocked device, so the only way through is a real extra hop.
- **AI seam:** `AIResponder` protocol. Milestone 1 uses an echo stub; milestone 2 plugs in a local model via Ollama on the Mac.

## Disclosures
### Models used
- None yet (milestone 1). Milestone 2 will list the Ollama model name, size, license and source.
### Technologies and frameworks
- Swift, SwiftUI, Apple MultipeerConnectivity, Foundation.
- XcodeGen (project generation from `project.yml`).
- Planned: Ollama for the local model.
### APIs and cloud services
- None at runtime.
### Existing code and assets
- No pre-existing project code and no third-party packages. All app code was written during the hackathon.
- Design inspiration only (no code used): the bitchat whitepaper (TTL flooding, dedup cache, store and forward).
### AI development tools
- Grok Bot (Remy): wrote and tested most of the code from Kyle's direction.

## Team
- Kyle Maquindang: product direction, device testing, demo. <role and contributions>

## Limitations
- iOS pauses peer links when the app is in the background; keep Libre open on the iPhones.
- Range is whatever peer-to-peer Wi-Fi reaches between two devices (roughly a room to a building floor); the mesh extends it hop by hop. We will publish measured numbers only.
- One-way latency compares two device clocks, so it can be off by the clock difference. The round trip for Ask AI is measured on one device and is exact.
- Links are encrypted by MultipeerConnectivity, but devices are not authenticated and relayed messages are readable by relaying devices. This is a prototype, not a secure messenger.
- Device names must be unique; they are the mesh addresses in milestone 1.
- Free Apple ID builds expire after 7 days on iPhones.
- MultipeerConnectivity is deprecated in the newest Xcode releases but still works; the relay layer is transport independent.
