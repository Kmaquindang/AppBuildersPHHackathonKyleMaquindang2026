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
- One-time internet is needed to download Ollama and the model (5.2 GB). After that Pasa is fully offline.
- Nothing at runtime. The one-time setup is cloning the repo, installing Ollama, and running `ollama pull qwen3:8b`.

## How to run it (for judges)

> **Important: Pasa must be open and on screen on every phone that relays.** iOS suspends apps in the background and MultipeerConnectivity links drop when that happens, so a phone in a pocket with the screen locked does not pass messages on. Keep Pasa in the foreground (the app keeps the screen awake while it is open). The Mac must stay awake, lid open and plugged in, with Ollama running.
Full step-by-step guide, including a manual Xcode path and iPhone trust steps: [docs/SETUP.md](docs/SETUP.md).

1. Install Xcode 15 or newer from the Mac App Store, and Ollama from https://ollama.com/download. Then run `ollama pull qwen3:8b` once (or `qwen3:4b` on a Mac with 8 GB of memory).
2. `git clone https://github.com/Kmaquindang/AppBuildersPHHackathonKyleMaquindang2026.git && cd AppBuildersPHHackathonKyleMaquindang2026`
3. Open `Libre.xcodeproj` (or run `xcodegen generate` first if you prefer to regenerate it from `project.yml`).
4. Pick your Team (a free Apple ID works) under Signing & Capabilities for the `Libre-macOS` and `Libre-iOS` targets. (Targets, schemes, folders and bundle ids keep the working name Libre; the app shows as Pasa on the device.)
5. Run `Libre-macOS` on your Mac. Run `Libre-iOS` on one or two iPhones (iOS 17+). On each iPhone trust the developer profile in Settings > General > VPN & Device Management, and allow Local Network access.
6. On first launch each app asks for your name (for example Kyle, Ana). That is the name everyone sees. Each device also has a stable device id (shown in Settings). Send a chat, or start a message with `@pasa` to ask the AI.
7. To test offline: put the iPhones in Airplane Mode, then turn Wi-Fi back on without joining a network. Keep the Mac's Wi-Fi on. Messages still flow.
8. To see a real 2-hop path: on one iPhone, block the Mac in Settings, and on the Mac block that iPhone. Blocking ends any existing direct link, and the chat header shows "Forced relay mode". Its messages now relay through the other iPhone, and the timeline shows the full path (tap the caption under the answer to see `Ask path: Ana -> Kyle -> Site Office, 2 hops`).
9. Mac only, no iPhones: run the Mac app, type `@pasa` followed by one of the assistant commands below; the Mac answers itself. Only one Mac should be the AI peer on a mesh; turn "Act as AI peer" off on any second Mac.
10. Pick admins on the Mac: Settings > Admins lists every device it has seen, by the person's name and device id. Tick the phones that may edit, lock, unlock and delete rules. The Mac is always an admin.
11. Try the assistant (from any device, one chat for everything: start the message with `@pasa`; typing `@` offers it as a chip; the old `@libre ...` still works):
    - `save rule: No site visits after 5 PM`
    - `remind Ana to order cement Friday` (the task pops up on the phone whose person picked the name Ana; if two people use the same name, Pasa asks which one. A manual roster on the Mac is an optional override)
    - `delete rule: No site visits after 5 PM` (admin devices only; the rule disappears from every phone. On a phone you can also swipe left on a rule in the Rules tab)
    - `can I visit the site at 6 PM?` (the answer cites `[Rule: No site visits after 5 PM v1]`)
    - `what did I miss?` (on a phone: a summary of team chat since that phone was last away, meaning the app was in the background or had no links; on the Mac, or when there is no away time, a labelled recap of the latest messages. Also `recap` and `ano'ng na-miss ko?`), `my tasks`, `team tasks`, `the cement is ordered`, `more`
    - Paste a long meeting transcript (or start with `notes:`) to get decisions and auto-created tasks.
12. Core unit tests (macOS or Linux with Swift installed, no Ollama needed): `./scripts/test-relay.sh`

## How it works
- **Link layer:** Apple MultipeerConnectivity on service type `libre-mesh`. It opens encrypted links over peer-to-peer Wi-Fi with no router or internet. We describe this as an offline device-to-device mesh, not a Bluetooth mesh.
- **Relay layer (our code, `Libre/Sources/Core`):** every message carries an id, origin, destination (everyone, one device, or a role such as the AI), hop budget (ttl 7) and the path so far. Each device drops ids it has already seen, adds itself to the path, delivers the message if it is meant for it, and forwards a copy with ttl minus 1 to linked devices not already on the path. Messages with nobody to go to wait in an outbox and leave as soon as a device links.
- **One chat:** there is no mode switch. Plain messages go to the team. A message that starts with `@pasa` goes to the AI peer. AI replies are purple bubbles with basic Markdown (bold, italics, bullets, inline code). Tap the small caption under any bubble to see its hop path and timing.
- **Names:** each person picks a display name on first launch. It travels on every message, so the UI shows "Ana", not "iPhone A8BE". The device id stays the mesh address. Admin rights follow the device id, never the display name, so renaming yourself "Kyle" does not make you an admin.
- **Messages survive restarts:** every device saves its timeline and its outbox as JSON in Application Support and reloads them on launch (phones keep the newest 500 messages, the Mac keeps the long history). When a phone links, it tells the AI Mac the newest message it has, and the Mac backfills what it missed (at most 200 per sync, in chunks of about 12 KB). Duplicates are dropped by message id.
- **Auto-reconnect:** a watchdog re-invites nearby devices with backoff (2, 4, 8, 16, then 30 s), cancels links stuck in "connecting" after 20 s, restarts discovery while links are missing, and restarts it when the app returns to the foreground. The outbox flushes as soon as a link comes back. Devices that are offline and unseen for 60 s leave the peer strip.
- **Model warm-up and staying awake:** on launch the Mac loads the model with a tiny Ollama request (`keep_alive` 60 minutes). While Pasa runs as the AI peer it checks Ollama every 60 s, warms the model as soon as Ollama appears (even if Ollama was started after Pasa), and refreshes `keep_alive` every 10 minutes, so the model stays loaded while Pasa runs and Ollama unloads it about an hour after Pasa quits. Pasa also holds a `ProcessInfo` activity (user initiated, idle system sleep disabled) so the Mac does not idle-sleep and App Nap does not throttle its timers. Closing the lid still sleeps the Mac.
- **Forced relay demo:** a per-device block list refuses invites both ways, rejects the connection handshake from a blocked device (this also covers MultipeerConnectivity joining two members of the same session on its own), drops any packet that arrives straight from a blocked device, and ends an existing direct link when you block it (if MultipeerConnectivity keeps the link up, Pasa restarts its links once and they re-form within seconds). The chat header shows "Forced relay mode" while a block is on. The handshake and disconnect behavior is still to be confirmed on devices.
- **Checked citations:** every `[Rule: ...]`, `[Skill: ...]` or `[Note: ...]` tag in a model answer is checked against team memory before the answer leaves the Mac. A wrong version is corrected to the current one, and a tag that names nothing saved is marked `(unverified)`. The prompt marks team knowledge as data (never instructions), puts admin-locked rules first and says they take precedence, and asks the model to reply in the language of the question (English, Tagalog, Cebuano or Taglish).
- **Waiting status:** if an `@pasa` question has no answer after 20 s, the asker sees "Waiting for the AI Mac... It answers when it is in range."
- **Protocol version:** every message carries a wire format version (`v`). A device that receives a newer version, or a message kind it does not know, still relays it with only the hop count and path changed, and shows "update Pasa on this device", instead of dropping it.
- **Clear that sticks:** Clear timeline records a watermark, so backfill and catch-ups never bring old messages back. On the AI Mac it clears the whole team's chat: linked phones drop older messages right away, the rest on their next link.
- **AI peer (Mac):** `ExecutiveAssistant` handles every ask. Common phrases (save rule, my tasks, what did I miss, more) skip the model entirely. Everything else gets one JSON-mode classification call, the action runs against team memory, and a second call writes the reply when needed. Replies are cut to a first packet of at most 300 characters (marked `compact`), and `@pasa more` sends the rest.
- **Team memory rules:** anyone can add a rule or skill. Only admin devices (ticked by device id in the Mac's Settings, plus the Mac itself) can edit, lock, unlock or delete an existing rule. Every edit becomes a new version and the old one stays in history. When copies meet, the newest version wins. Deleting keeps a tombstone (same id, version plus 1, retired, who and when): the Mac broadcasts it so phones drop their copy, and sends tombstones again whenever a phone links so stale caches catch up. Deleted rules are never sent to the model.
- **Small, grounded prompts:** the answer prompt carries only the rules and notes that match the question (BM25-style keyword scoring, title words count double, top 8 rules within about 2,500 tokens), plus every admin-locked rule. Catch-ups read the newest chat that fits in about 3,000 tokens. Pasa asks Ollama for an 8,192-token context (`num_ctx`), estimates each prompt at about 4 characters per token, and the Mac dashboard shows the estimate next to Ollama's `prompt_eval_count`, with a warning above 80% of the context. When no saved rule or note matches, the answer starts with "No saved team rule covers this." instead of guessing, and every answer's details list the rule titles it checked.
- **Model pinning and low-memory Macs:** the dashboard shows the digest of the model Ollama is serving and says whether it is the build we tested. Macs with less than 12 GB of memory default to `qwen3:4b-instruct`; you can change the model in Settings.
- **Backup:** on the Mac, Settings > Export team memory saves rules, tasks, notes and the chat log as a JSON file you choose. Import asks for confirmation, replaces team memory, and updates linked phones.
- **Updates over the mesh:** a new task is sent as a `task` message to the assignee's device; a saved rule is broadcast as a `rule` message so every phone caches it, and shows as a card only when it changed the phone's copy. When a phone links, the Mac first sends a manifest of the rule and task ids it holds (the phone drops cached copies the Mac no longer has, for example after Reset team memory), then the current rules and the phone's open tasks as silent updates that refresh the cache without adding cards to the chat.

## Hardware tested on
- MacBook Air M3, 16 GB RAM (AI peer and team memory, runs Ollama). Mac app built and running Oct 9.
- iPhone 14 Pro Max (admin phone). App installed and running Oct 9.
- iPhone 12 (relay and ask device). App installed and running Oct 9.

## Screenshots
From the first 3-device run on Oct 9, 2026 at about 5:23 PM PHT (MacBook Air M3 as AI peer, iPhone 14 Pro Max, iPhone 12). These were taken on the build before the one-chat and display-name changes.

| Mac AI peer | iPhone 14 Pro Max: rule arrives over 2 hops | iPhone 12: answer from the Mac's local AI |
|---|---|---|
| ![Mac AI peer](docs/screenshots/2026-10-09_1723_mac_ai_peer.jpg) | ![iPhone 14 Pro Max rules](docs/screenshots/2026-10-09_1723_iphone14_rules_2hop.png) | ![iPhone 12 answer](docs/screenshots/2026-10-09_1723_iphone12_answer_2hop.jpg) |

## Measured performance
Real numbers only, from the first 3-device run on Oct 9, 2026 (about 5:23 PM PHT). Devices: MacBook Air M3 16 GB (AI peer, Ollama), iPhone 14 Pro Max, iPhone 12. Everything offline, peer-to-peer Wi-Fi. Model times come from the Mac dashboard; the round trip is measured on the iPhone 12 with its own clock.

| Measurement | Where measured | MacBook Air M3 16 GB, qwen3:8b | MacBook Air M3 16 GB, qwen3:4b |
|---|---|---|---|
| Generation speed, in app (tokens/s) | Mac, Ollama `eval_count / eval_duration` | 16.6 | not measured |
| Ask to answer, assistant intent with model (ms) | Mac | 6470 | not measured |
| Ask to answer, fast path without model (`save rule`, ms) | Mac | 9 | not measured |
| Round trip: ask from iPhone 12, answer returning via iPhone 14 Pro Max (ms) | iPhone 12 | 6664 | not measured |
| Rule broadcast Mac -> iPhone 14 Pro Max -> iPhone 12, 2 hops (ms) | iPhone 12 timeline (one-way, compares two device clocks) | 522 | not measured |

Notes:
- In the round-trip test the ask went direct (1 hop, iPhone 12 -> Mac) and the answer came back over 2 hops (Mac -> iPhone 14 Pro Max -> iPhone 12). A forced-relay round trip (both directions through the middle phone) is still to be measured.
- The 522 ms one-way figure depends on how closely the two device clocks agree; the round trip uses one clock and is exact.
- Earlier, a direct Ollama API call (no app) measured 15.6 tokens/s warm, and the very first question after starting Ollama took about 25 s while the model loaded. The app now warms the model up on launch.

## Disclosures
### Models used
- Qwen3 8B, tag `qwen3:8b`, digest `500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41` (Q4_K_M, 8.2B parameters, 5.2 GB download), served by Ollama 0.35.0 on the MacBook Air M3 16 GB. Read from `ollama list` and `/api/tags` on Oct 9, 2026. Library page: https://ollama.com/library/qwen3. License: Apache 2.0 (https://huggingface.co/Qwen/Qwen3-8B/blob/main/LICENSE).
- Memory: the default `qwen3:8b` is meant for Macs with 12 GB of memory or more (tested on 16 GB). Its memory use while loaded has not been measured yet (check with `ollama ps`). Macs under 12 GB default to `qwen3:4b-instruct`.
- Qwen3 4B (`qwen3:4b`, 2.5 GB, Apache 2.0) as the fallback. Note: in the Ollama library `qwen3:4b` now points to the 2507 thinking build; `qwen3:4b-instruct` (2.5 GB) is the non-thinking build and may be faster for short replies.
### Technologies and frameworks
- Swift, SwiftUI, Apple MultipeerConnectivity, Foundation.
- XcodeGen (project generation from `project.yml`).
- Ollama (local model runtime, HTTP API on 127.0.0.1:11434). License: MIT (https://github.com/ollama/ollama/blob/main/LICENSE).
### APIs and cloud services
- None at runtime. The only API used is the local Ollama server on the same Mac.
### Existing code and assets
- No pre-existing project code and no third-party packages. All app code was written during the hackathon.
- Design inspiration only (no code used): the bitchat whitepaper (TTL flooding, dedup cache, store and forward).
### AI development tools
- Grok Bot (Remy): wrote and tested most of the code from Kyle's direction.

## Team
- Kyle Maquindang: product direction, device testing, demo. <role and contributions>

## Security
Honest status for this prototype:
- **Links are encrypted.** The mesh uses Apple MultipeerConnectivity with `MCSession(..., encryptionPreference: .required)` (set in `Libre/Sources/Mesh/MeshTransport.swift`), so each device-to-device link is encrypted.
- **Relays can read messages.** Encryption is per link, not end to end. A phone that relays a message decrypts it before passing it on, so any device on the path can read it.
- **No end-to-end encryption and no device authentication.** Devices are not verified (`securityIdentity: nil`). Admins are chosen by device id on the Mac, so changing your display name does not grant admin, but a modified or renamed device could still claim another device's id. The admin check is a safeguard for honest teams, not real security. Phones also accept rule, task and manifest updates from any device on the mesh.
- **Data stays local.** Nothing goes to the internet. Team memory and timelines are saved as plain JSON in each app's Application Support folder (inside the app sandbox on macOS), protected by the device's own storage encryption.

## Limitations
- **Phones relay only while Pasa is open and on screen.** iOS suspends Pasa in the background and its links drop, so there is no pocket relaying yet. Keep the app in the foreground on every phone that should pass messages on.
- The Mac must stay awake: lid open, plugged in, Ollama running. Pasa prevents idle sleep while it is the AI peer, but closing the lid still sleeps the Mac.
- Peer-to-peer Wi-Fi must be on (no network needs to be joined). Bluetooth-only behavior is untested.
- One AI peer per mesh. A second Mac must turn "Act as AI peer" off. A MultipeerConnectivity session links at most 8 devices directly; relays extend reach beyond that.
- Tagalog and Cebuano answer quality of qwen3:8b has not been measured yet; tested in English.
- Due dates are free text, with no reminders or notifications.
- Range is whatever peer-to-peer Wi-Fi reaches between two devices (roughly a room to a building floor); the mesh extends it hop by hop. We will publish measured numbers only.
- One-way latency compares two device clocks, so it can be off by the clock difference. The app hides one-way times that are negative or implausible. The round trip for an `@pasa` ask is measured on one device and is exact.
- Links are encrypted by MultipeerConnectivity, but devices are not authenticated and relayed messages are readable by relaying devices (see Security). This is a prototype, not a secure messenger.
- Device ids must be unique; they are the mesh addresses. People's display names should be unique too; when two people share a name, task assignment asks which one.
- Free Apple ID builds expire after 7 days on iPhones.
- The AI only runs on the Mac in this milestone; phones ask it over the mesh. On-phone models are a stretch goal.
- The local model can still be wrong. Pasa checks citations against saved rules, flags invented ones as "(unverified)", and says when no saved rule covers a question, but the wording of an answer can still misstate a rule. Read the cited rule when it matters.
- Context is limited to 8,192 tokens. With many rules, only the best keyword matches (plus locked rules) reach the model, so a relevant rule with different wording can be missed. Catch-ups read only the newest chat that fits the budget.
- Intent detection and note taking come from a small local model and can misread a message; the reply always says what it did (for example "Task added: ...") so the team can correct it.
- Assignees are matched to devices through the names people picked (or the optional roster on the Mac). A person the Mac has not heard from yet still gets the task on the board, but nothing is pushed to a phone.
- Backfill comes from the AI Mac only: messages that never passed through the Mac (for example a private task between two phones while the Mac was away) cannot be backfilled.
- Any device on the mesh can claim any name, and a modified device could claim another device's id, so the admin check is a prototype safeguard, not real authentication.
- The relay layer is transport independent, so MultipeerConnectivity could be swapped for another link layer (for example Android Wi-Fi Direct) later.

## Roadmap / Next: Rooms
Designed, not built yet. Two or more unrelated teams (for example two businesses on one site) share one physical mesh, and each sees only its own chat, rules, tasks and AI answers.
- Each room has a spoken label (for example `BOHOL-7`) and a random 256-bit key shared by QR code or a long join string. The label is not the secret.
- Messages keep a clear routing header (version, id, room tag derived from the key, origin, destination, hop budget, path) and seal everything else with ChaCha20-Poly1305. Phones relay other rooms' packets without being able to read or store them.
- The Mac keeps memory and chat per room and the AI answers only from that room's rules. Admins are per room, keyed by device, with the room creator pinned as admin.
- Honest limits: anyone with the join string can read the room, there is no per-person end-to-end encryption, the AI Mac can read every room it serves, and relays still see routing metadata.
