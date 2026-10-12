# Libre setup (milestones 1 and 2)

Libre (called Pasa for part of Oct 9, 2026, renamed back at 11:01 PM PHT) is a SwiftUI app for iPhone and Mac. Devices find each other with no internet, pass messages through our own multi-hop relay layer, and show the hop path and timing on every message (milestone 1). The Mac is the AI peer: a team executive assistant running a local model through Ollama (milestone 2).

You need: a Mac with Xcode 15 or newer, a free Apple ID, and (optionally) one or two iPhones on iOS 17 or newer with a cable.

Names in the project: Xcode targets, schemes, the `Libre/` folder, bundle ids (`com.kmaquindang.libre`, `com.kmaquindang.libre.mac`) and the Bonjour service `libre-mesh` all use Libre. A few internal ids from the Libre period (the `PASA1` join string prefix, key derivation labels, saved settings keys) stay as they are so existing rooms and installs keep working.

## Option A: open the committed project (fastest)

1. `git clone https://github.com/Kmaquindang/libre.git` and `cd` into it.
2. Open `Libre.xcodeproj` in Xcode. It is committed in the repo (generated from `project.yml` with XcodeGen). If it fails to open, use Option B or Option C.
3. Go to Option A/B common steps below.

## Option B: generate the project with XcodeGen

1. Install XcodeGen once: `brew install xcodegen`.
2. In the repo folder run `xcodegen generate`. This writes `Libre.xcodeproj` from `project.yml`.
3. Open `Libre.xcodeproj`.

### Option A/B common steps

1. Click the blue **Libre** project in the left sidebar.
2. Select target **Libre-macOS**, open **Signing & Capabilities**, and pick your **Team** (your Apple ID shows up as "Your Name (Personal Team)"). If Xcode says the bundle id is taken, change `com.kmaquindang.libre.mac` to something unique.
3. Select target **Libre-iOS** and do the same (bundle id `com.kmaquindang.libre`).
4. Choose the **Libre-macOS** scheme with destination **My Mac** and press Run. Allow the Local Network prompt if it appears.
5. Plug in an iPhone, choose the **Libre-iOS** scheme and pick the iPhone as the destination, press Run.
6. First run on an iPhone: the app will not open until you trust yourself as a developer. On the iPhone go to **Settings > General > VPN & Device Management**, tap your Apple ID under Developer App, and tap **Trust**. Also turn on **Settings > Privacy & Security > Developer Mode** if iOS asks, then restart the phone. Run again from Xcode.
7. When the app asks to find devices on your local network, tap **Allow**. If you tapped Don't Allow, fix it in **Settings > Privacy & Security > Local Network > Libre**.

## Option C: create the project by hand in Xcode

Use this if XcodeGen is not available.

1. In Xcode choose **File > New > Project**, pick the **Multiplatform** tab, then **App**. Name it `Libre`, Interface SwiftUI, Language Swift, Storage None, no tests. Save it anywhere outside the repo, or inside the repo root.
2. Delete the generated `LibreApp.swift` and `ContentView.swift` (Move to Trash). Our code has its own `@main` app.
3. Drag the repo's `Libre/Sources` folder into the project navigator. Choose **Create groups** (or "Create folders" on newer Xcode), and make sure the **Libre** target is ticked.
4. Click the project, select the **Libre** target, **General** tab: set minimum deployments to **iOS 17.0** and **macOS 14.0**.
5. **Build Settings** tab, search for these and set them:
   - **Swift Language Version**: Swift 5.
   - **Default Actor Isolation** (Xcode 26 and newer): **nonisolated**. New Xcode projects default to MainActor, which this code does not expect.
   - **Strict Concurrency Checking**: Minimal.
6. **Info** tab, under Custom iOS Target Properties (click + to add a row):
   - `Privacy - Local Network Usage Description` (raw key `NSLocalNetworkUsageDescription`), value: `Libre connects directly to nearby phones and Macs to pass team messages and AI answers with no internet.`
   - `Bonjour services` (raw key `NSBonjourServices`), type Array, with two String items: `_libre-mesh._tcp` and `_libre-mesh._udp`.
   - `Privacy - Microphone Usage Description` (`NSMicrophoneUsageDescription`) and `Privacy - Photo Library Usage Description` (`NSPhotoLibraryUsageDescription`), for voice notes and photos. On the Mac also `Privacy - Speech Recognition Usage Description` (`NSSpeechRecognitionUsageDescription`) for on-device voice note transcripts. The texts used are in `Libre/Resources/Info-iOS.plist` and `Info-macOS.plist`.
7. **Signing & Capabilities** tab: pick your Team (Personal Team is fine). Set a unique bundle id such as `com.kmaquindang.libre`.
8. Still in Signing & Capabilities, find **App Sandbox** (shown for the macOS destination). Tick **Incoming Connections (Server)** and **Outgoing Connections (Client)** under Network, and **Audio Input** under Hardware (voice notes). Without the network boxes the Mac cannot join the mesh.
9. Run on **My Mac**, then on each iPhone. Follow steps 6 and 7 from the common steps for the iPhone trust and Local Network prompts.

## Run the milestone 1 demo

1. Open Libre on all three devices. On first launch each one asks for your name (for example `Kyle`, `Ana`). Device ids are created automatically and can be changed under **Settings** (gear icon) > **This device**, for example `MacBook Air`, `iPhone 14 Pro Max`, `iPhone 12`.
2. Wait until the peer chips at the top show **linked** (green). Keep the app open in the foreground on the iPhones; iOS pauses links when the app is in the background.
3. To prove there is no internet: on each iPhone turn on Airplane Mode, then turn **Wi-Fi back on** (do not join any network). Bluetooth can stay on. On the Mac, Wi-Fi must be on but does not need to be joined to a network.
4. Send a chat from any device. Every other device shows it with the path and time, for example `iPhone 12 -> MacBook Air, 1 hop, 35 ms`.
5. Forced relay: on **iPhone 12** open Settings and turn on **Block direct link to MacBook Air**. Now iPhone 12 and the Mac can only talk through iPhone 14 Pro Max.
6. On iPhone 12 type `@libre` before the question (typing `@` shows an `@libre` chip; `@libre` still works) and send. The Mac (AI peer is on by default on the Mac) replies `AI peer received: ...`. On iPhone 12 the answer row shows:
   - `MacBook Air -> iPhone 14 Pro Max -> iPhone 12, 2 hops, ... ms`
   - `Ask path: iPhone 12 -> iPhone 14 Pro Max -> MacBook Air, 2 hops`
   - `Round trip ... ms (measured on this device)`
7. Store and forward: put iPhone 12 out of range (or close the app on the other two), send a message, and see it marked **Queued**. Bring the devices back and it is sent as soon as a peer links.

## Milestone 2: the AI executive assistant (Mac)

### One-time setup (needs internet once)
1. Install Ollama from https://ollama.com/download and open it (a llama icon appears in the menu bar).
2. In Terminal run `ollama pull qwen3:8b` (5.2 GB). Optional fallback: `ollama pull qwen3:4b` (2.5 GB). If the 4B model feels slow because it keeps "thinking", use `qwen3:4b-instruct` instead and enter that name in Settings.
3. Check it works: `ollama run qwen3:8b "say hi"` then type `/bye`.

### In the app
1. Run Libre on the Mac. Open Settings > AI peer: Engine = Executive assistant, model `qwen3:8b`, fallback `qwen3:4b`. Admin devices default to `iPhone 14 Pro Max` (this Mac is always an admin).
2. Optional: the roster is only an override now, because tasks follow the names people picked. If you need it, add one line per person, for example `Ana = iPhone 12`. Tap **Save AI settings**. The status line should say `Ollama running. Using qwen3:8b.`, then `Warming up the model...` and finally `Ready. qwen3:8b loaded in ... s`.
3. Open the **Assistant** tab on the Mac to watch every ask, the reply, the model, the latency in ms and the tokens per second.
4. From iPhone 12 (type `@libre` first):
   - `save rule: No site visits after 5 PM` gives `Saved [Rule: No site visits after 5 PM v1]`, and the rule appears in every device's Rules tab.
   - `update rule No site visits after 5 PM: No site visits after 6 PM` from iPhone 12 is refused (not an admin). The same message from iPhone 14 Pro Max creates v2 and keeps v1 in history.
   - `remind Ana to order cement Friday` creates the task, and it pops up on iPhone 12 (Ana's device) as a green Task row and in its Tasks tab.
   - `can I visit the site at 6 PM?` answers with a citation such as `[Rule: No site visits after 5 PM v2]`.
   - Send a few normal chats, then tap **What did I miss?** on another phone for a 3-line catch-up.
   - `my tasks`, `team tasks`, `the cement is ordered` (marks it done), `more` (rest of a long answer).
   - Paste a long meeting transcript, or start a message with `notes:`. You get decisions, action items, and tasks created and sent to the right phones.
5. If Ollama is not running, the reply says `Start Ollama on the Mac ...`. Open the Ollama app and ask again.

### Where the data lives
- Mac (source of truth): `~/Library/Containers/com.kmaquindang.libre.mac/Data/Library/Application Support/Libre/org-memory.json`
- Phones: a read-only cache in the app's Application Support folder (`org-cache.json`).
- Settings > AI peer > Reset team memory erases the Mac copy.

## Mac-only test (no iPhones)

1. Run **Libre-macOS**. Type `@libre` and a question, then send. The Mac answers itself through the local AI path (0 hops), which tests the AI seam.
2. For a real mesh with only Macs, run the app on two Macs near each other. MultipeerConnectivity works Mac to Mac.

## Run the core unit tests

The relay, team memory and assistant logic are pure Swift with no Apple frameworks. The assistant tests use a scripted fake model, so Ollama is not needed:

```
./scripts/test-relay.sh
```

It compiles `Libre/Sources/Core`, `Libre/Sources/AI` and the test runner with `swiftc` and prints `Libre core tests: N passed, 0 failed`.

## Troubleshooting

- **Peers never appear:** check Local Network permission on every device, make sure Wi-Fi is on, and that every device has a different name. On the Mac, confirm the App Sandbox network boxes are ticked.
- **"Advertising failed" or "Browsing failed" in red under the header:** the Bonjour services in Info.plist do not match `_libre-mesh._tcp` and `_libre-mesh._udp`, or Local Network permission was denied.
- **App will not install on the iPhone after 7 days:** free Personal Team profiles expire after 7 days. Run from Xcode again.
- **"Start Ollama on the Mac":** open the Ollama app, or run `ollama serve` in Terminal.
- **"Model qwen3:8b is not installed":** run `ollama pull qwen3:8b`, or set the model to one you have (`ollama list`).
- **First answer is slow:** the model loads into memory on the first request (it then stays loaded for 30 minutes).
- **Deprecation warnings about MultipeerConnectivity:** expected on newer Xcode versions. Apple still ships it; a Network framework transport can replace `MeshTransport.swift` later without touching the relay layer.
