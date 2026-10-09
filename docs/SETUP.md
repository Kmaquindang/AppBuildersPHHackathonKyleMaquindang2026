# Libre setup (milestone 1: prove the mesh)

Milestone 1 is a SwiftUI app for iPhone and Mac. Devices find each other with no internet, pass messages through our own multi-hop relay layer, and show the hop path and timing on every message. The Mac can act as the AI peer (an echo stub for now; a local model through Ollama arrives in milestone 2).

You need: a Mac with Xcode 15 or newer, a free Apple ID, and (optionally) one or two iPhones on iOS 17 or newer with a cable.

## Option A: open the committed project (fastest)

1. `git clone https://github.com/Kmaquindang/AppBuildersPHHackathonKyleMaquindang2026.git` and `cd` into it.
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
7. **Signing & Capabilities** tab: pick your Team (Personal Team is fine). Set a unique bundle id such as `com.kmaquindang.libre`.
8. Still in Signing & Capabilities, find **App Sandbox** (shown for the macOS destination). Tick **Incoming Connections (Server)** and **Outgoing Connections (Client)** under Network. Without these the Mac cannot join the mesh.
9. Run on **My Mac**, then on each iPhone. Follow steps 6 and 7 from the common steps for the iPhone trust and Local Network prompts.

## Run the milestone 1 demo

1. Open Libre on all three devices. Open **Settings** (gear icon) on each one and give it a unique name: `MacBook Air`, `iPhone 14 Pro Max`, `iPhone 12`. Tap **Save name**.
2. Wait until the peer chips at the top show **linked** (green). Keep the app open in the foreground on the iPhones; iOS pauses links when the app is in the background.
3. To prove there is no internet: on each iPhone turn on Airplane Mode, then turn **Wi-Fi back on** (do not join any network). Bluetooth can stay on. On the Mac, Wi-Fi must be on but does not need to be joined to a network.
4. Send a chat from any device. Every other device shows it with the path and time, for example `iPhone 12 -> MacBook Air, 1 hop, 35 ms`.
5. Forced relay: on **iPhone 12** open Settings and turn on **Block direct link to MacBook Air**. Now iPhone 12 and the Mac can only talk through iPhone 14 Pro Max.
6. On iPhone 12 switch the composer to **Ask AI** (or type `@libre` before the question) and send. The Mac (AI peer is on by default on the Mac) replies `AI peer received: ...`. On iPhone 12 the answer row shows:
   - `MacBook Air -> iPhone 14 Pro Max -> iPhone 12, 2 hops, ... ms`
   - `Ask path: iPhone 12 -> iPhone 14 Pro Max -> MacBook Air, 2 hops`
   - `Round trip ... ms (measured on this device)`
7. Store and forward: put iPhone 12 out of range (or close the app on the other two), send a message, and see it marked **Queued**. Bring the devices back and it is sent as soon as a peer links.

## Mac-only test (no iPhones)

1. Run **Libre-macOS**. Switch to **Ask AI** and send a question. The Mac answers itself through the local AI path (0 hops), which tests the AI seam.
2. For a real mesh with only Macs, run the app on two Macs near each other. MultipeerConnectivity works Mac to Mac.

## Run the relay unit tests

The relay logic is pure Swift with no Apple frameworks:

```
./scripts/test-relay.sh
```

It compiles `MeshMessage.swift`, `RelayEngine.swift` and the test runner with `swiftc` and prints `RelayEngine tests: N passed, 0 failed`.

## Troubleshooting

- **Peers never appear:** check Local Network permission on every device, make sure Wi-Fi is on, and that every device has a different name. On the Mac, confirm the App Sandbox network boxes are ticked.
- **"Advertising failed" or "Browsing failed" in red under the header:** the Bonjour services in Info.plist do not match `_libre-mesh._tcp` and `_libre-mesh._udp`, or Local Network permission was denied.
- **App will not install on the iPhone after 7 days:** free Personal Team profiles expire after 7 days. Run from Xcode again.
- **Deprecation warnings about MultipeerConnectivity:** expected on newer Xcode versions. Apple still ships it; a Network framework transport can replace `MeshTransport.swift` later without touching the relay layer.
