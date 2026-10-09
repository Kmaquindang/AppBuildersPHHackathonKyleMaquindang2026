# Pasa

*Walang signal? Pasa lang.* Pasa is Tagalog for "pass it on": every phone passes the message on until it reaches the team.

Pasa is an offline team chat for groups with no signal or no data budget: nearby iPhones and Macs form their own device-to-device mesh, messages hop from device to device, and a local AI assistant on the Mac answers the team with zero cost per question.

Name note: the working name was Libre ("free"). On Oct 9, 2026 at 5:18 PM PHT Kyle renamed it Pasa, because the name describes how the mesh works (each phone passes the message on) and is easy to say on camera.

> Status: milestone 2 (AI executive assistant). Milestone 1 proved the mesh: devices discover each other with no internet, messages travel through our own multi-hop relay layer, and every message shows its hop path and measured timing. Milestone 2 adds the team's executive assistant on the Mac, running a local model through Ollama: it saves rules and skills, turns plain sentences into tasks and pushes them to the assignee's phone, catches people up on what they missed, takes notes from transcripts, and answers questions grounded in the team's own rules with citations.

## Why does this product benefit from running AI locally?
The people we build for cannot rely on cloud AI: they have no signal, or they cannot afford mobile data. Cloud-only AI is impossible for them at the moment they need it and expensive at scale. With Pasa, one laptop running a local model serves everyone in mesh range, so every question costs nothing and works with no cell towers. Team notes, rules and to-dos are private by design because they never leave the group's own devices.

## Demo
- Demo video: <link>
- X / LinkedIn post: <link>

## What runs locally
- **Mesh (all devices):** discovery, encrypted device-to-device links, and our multi-hop relay (dedup, hop budget, store and forward).
- **LLM on the Mac via Ollama** (default `qwen3:8b`, fallback `qwen3:4b`, thinking turned off for speed): one JSON-mode call classifies each request and extracts fields (task title, assignee, due date, rule title), and a second call writes grounded answers, catch-up summaries and meeting notes.
- **Team memory on the Mac** (source of truth): tasks, notes, rules and skills with versions and history, saved as JSON in the app's Application Support folder. Phones keep a read-only copy received over the mesh.

## What requires internet
- Nothing at runtime. Only one-time setup needs internet: cloning the repo, installing Ollama, and downloading the model (`ollama pull qwen3:8b`).

## How to run it (for judges)
Full step-by-step guide, including a manual Xcode path and iPhone trust steps: [docs/SETUP.md](docs/SETUP.md).

1. Install Xcode 15 or newer from the Mac App Store, and Ollama from https://ollama.com/download. Then run `ollama pull qwen3:8b` once (or `qwen3:4b` on a Mac with 8 GB of memory).
2. `git clone https://github.com/Kmaquindang/AppBuildersPHHackathonKyleMaquindang2026.git && cd AppBuildersPHHackathonKyleMaquindang2026`
3. Open `Libre.xcodeproj` (or run `xcodegen generate` first if you prefer to regenerate it from `project.yml`).
4. Pick your Team (a free Apple ID works) under Signing & Capabilities for the `Libre-macOS` and `Libre-iOS` targets. (Targets, schemes, folders and bundle ids keep the working name Libre; the app shows as Pasa on the device.)
5. Run `Libre-macOS` on your Mac. Run `Libre-iOS` on one or two iPhones (iOS 17+). On each iPhone trust the developer profile in Settings > General > VPN & Device Management, and allow Local Network access.
6. In each app open Settings and give the device a unique name. Send a chat, or switch to Ask AI.
7. To test offline: put the iPhones in Airplane Mode, then turn Wi-Fi back on without joining a network. Keep the Mac's Wi-Fi on. Messages still flow.
8. To see a real 2-hop path: on one iPhone, block the Mac in Settings. Its messages now relay through the other iPhone, and the timeline shows the full path.
9. Mac only, no iPhones: run the Mac app, switch to Ask AI and try the assistant commands below; the Mac answers itself. Two Macs near each other also form a mesh.
10. Try the assistant (from any device, Ask AI mode or `@pasa ...`; the old `@libre ...` still works):
    - `save rule: No site visits after 5 PM`
    - `remind Ana to order cement Friday` (set `Ana = iPhone 12` in the Mac's Settings > Team roster so the task pops up on that phone)
    - `can I visit the site at 6 PM?` (the answer cites `[Rule: No site visits after 5 PM v1]`)
    - `what did I miss?`, `my tasks`, `team tasks`, `the cement is ordered`, `more`
    - Paste a long meeting transcript (or start with `notes:`) to get decisions and auto-created tasks.
11. Core unit tests (macOS or Linux with Swift installed, no Ollama needed): `./scripts/test-relay.sh`

## How it works
- **Link layer:** Apple MultipeerConnectivity on service type `libre-mesh`. It opens encrypted links over peer-to-peer Wi-Fi with no router or internet. We describe this as an offline device-to-device mesh, not a Bluetooth mesh.
- **Relay layer (our code, `Libre/Sources/Core`):** every message carries an id, origin, destination (everyone, one device, or a role such as the AI), hop budget (ttl 7) and the path so far. Each device drops ids it has already seen, adds itself to the path, delivers the message if it is meant for it, and forwards a copy with ttl minus 1 to linked devices not already on the path. Messages with nobody to go to wait in an outbox and leave as soon as a device links.
- **Forced relay demo:** a per-device block list refuses direct links and drops any packet that arrives straight from a blocked device, so the only way through is a real extra hop.
- **AI peer (Mac):** `ExecutiveAssistant` handles every ask. Common phrases (save rule, my tasks, what did I miss, more) skip the model entirely. Everything else gets one JSON-mode classification call, the action runs against team memory, and a second call writes the reply when needed. Replies are cut to a first packet of at most 300 characters (marked `compact`), and `@pasa more` sends the rest.
- **Team memory rules:** anyone can add a rule or skill. Only admin devices (default `iPhone 14 Pro Max` plus the Mac itself, configurable) can edit, lock or unlock an existing rule. Every edit becomes a new version and the old one stays in history. When copies meet, the newest version wins.
- **Updates over the mesh:** a new task is sent as a `task` message to the assignee's device; a saved rule is broadcast as a `rule` message so every phone caches it. When a phone links, the Mac sends it the current rules and its open tasks.

## Hardware tested on
- MacBook Air M3, 16 GB RAM (AI peer and team memory, runs Ollama). Mac app built and running Oct 9.
- iPhone 14 Pro Max (admin phone). App installed and running Oct 9.
- iPhone 12 (relay and ask device). Install pending.

## Screenshots
Screenshots are coming from real runs on the devices above.

## Measured performance
Measured live on the hardware listed below; the Mac dashboard shows latency per request and tokens per second (Ollama `eval_count / eval_duration`). Numbers will be filled in from real runs only.

| Measurement | MacBook Air M3 16 GB, qwen3:8b | MacBook Air M3 16 GB, qwen3:4b |
|---|---|---|
| Generation speed (tokens/s) | 15.6 (one warm run, direct Ollama API call, Oct 9; in-app numbers to follow) | to be measured |
| Ask to answer, assistant intent with model (ms) | to be measured | to be measured |
| Ask to answer, fast path without model (ms) | to be measured | to be measured |
| Round trip iPhone 12 -> iPhone 14 Pro Max -> Mac and back (ms) | to be measured | to be measured |

## Disclosures
### Models used
- Qwen3 8B (`qwen3:8b`, 5.2 GB download, Apache 2.0) from the Ollama library: https://ollama.com/library/qwen3
- Qwen3 4B (`qwen3:4b`, 2.5 GB, Apache 2.0) as the fallback. Note: in the Ollama library `qwen3:4b` now points to the 2507 thinking build; `qwen3:4b-instruct` (2.5 GB) is the non-thinking build and may be faster for short replies.
### Technologies and frameworks
- Swift, SwiftUI, Apple MultipeerConnectivity, Foundation.
- XcodeGen (project generation from `project.yml`).
- Ollama (local model runtime, HTTP API on 127.0.0.1:11434).
### APIs and cloud services
- None at runtime. The only API used is the local Ollama server on the same Mac.
### Existing code and assets
- No pre-existing project code and no third-party packages. All app code was written during the hackathon.
- Design inspiration only (no code used): the bitchat whitepaper (TTL flooding, dedup cache, store and forward).
### AI development tools
- Grok Bot (Remy): wrote and tested most of the code from Kyle's direction.

## Team
- Kyle Maquindang: product direction, device testing, demo. <role and contributions>

## Limitations
- iOS pauses peer links when the app is in the background; keep Pasa open on the iPhones.
- Range is whatever peer-to-peer Wi-Fi reaches between two devices (roughly a room to a building floor); the mesh extends it hop by hop. We will publish measured numbers only.
- One-way latency compares two device clocks, so it can be off by the clock difference. The round trip for Ask AI is measured on one device and is exact.
- Links are encrypted by MultipeerConnectivity, but devices are not authenticated and relayed messages are readable by relaying devices. This is a prototype, not a secure messenger.
- Device names must be unique; they are the mesh addresses in milestone 1.
- Free Apple ID builds expire after 7 days on iPhones.
- The AI only runs on the Mac in this milestone; phones ask it over the mesh. On-phone models are a stretch goal.
- Intent detection and note taking come from a small local model and can misread a message; the reply always says what it did (for example "Task added: ...") so the team can correct it.
- Assignees are matched to devices through the roster on the Mac; a person without a roster entry still gets the task on the board, but nothing is pushed to a phone.
- Any device on the mesh can claim any name, so the admin check is a prototype safeguard, not real authentication.
- MultipeerConnectivity is deprecated in the newest Xcode releases but still works; the relay layer is transport independent.
