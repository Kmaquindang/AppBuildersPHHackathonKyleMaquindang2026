# Libre Bluetooth review (Oct 12, 2026, 3:00 PM PHT)

Scope: our BLE link (c534465), Android app (b11b195), relay layer, in this repo. Compared against bitchat's design, read only. No bitchat code was copied and none should be.

## Licenses (read before anyone looks at their code again)
- `permissionlesstech/bitchat` (iOS/macOS): public domain (Unlicense, `LICENSE`).
- `permissionlesstech/bitchat-android`: **GPL v3** (`LICENSE.md`). Copying or closely porting any of it would force Libre's Android app under GPL v3. Rule: read docs and ideas only, never paste or line-by-line port Android code. Ideas and protocol concepts are not covered by copyright; code is.
- Sources read: `WHITEPAPER.md` sections 4 to 8, `docs/BLE-ARCHITECTURE-V3.md`, bitchat `Info.plist` background modes, `BLEService.swift` restore option (grep only), bitchat-android `PowerManager.kt` profile shape and `AndroidManifest.xml` service types (grep only).

## Verdict in one line
Today Libre has a foreground-only, unmeasured, point-to-point BLE pipe bolted under a Wi-Fi mesh. That is fine for a two-phone demo. It is not a Bluetooth-first mesh. Nothing in the BLE path has run on a real device with Wi-Fi off, and the one real attempt (Oct 11) failed.

## 1. Critical gaps (ranked)

1. **Zero device evidence.** README "Bluetooth mode" says "Not yet tested phone to phone with Wi-Fi off", speeds are "expected, not yet measured", and the Android app has never run on a phone. The Oct 11 Bluetooth-only attempt failed before c534465 landed. Every other point below is secondary until one two-phone Wi-Fi-off test passes and `ble-log.txt` has real numbers.
2. **No background BLE at all.** `Libre/Resources/Info-iOS.plist` has `NSBluetoothAlwaysUsageDescription` but no `UIBackgroundModes` (`bluetooth-central`, `bluetooth-peripheral`), and `BLETransport.swift` creates its managers without a restore identifier. bitchat declares both modes (`bitchat/Info.plist`) and uses `CBCentralManagerOptionRestoreIdentifierKey` (`BLEService.swift`). Result: a locked iPhone in a pocket is not a relay. For a "mesh" this is the single biggest product gap. Android has no foreground service either (`android/app/src/main/AndroidManifest.xml` declares only BT permissions); bitchat-android runs a `connectedDevice` foreground service (`AndroidManifest.xml`, `MeshForegroundService`). Note: even with background modes, iOS background scanning is slow and service-UUID-filtered, and iOS-to-iOS background advertising hides the UUID in the overflow area. So background iOS discovery of another background iOS device is weak by design. Plan for it, do not promise it.
3. **Identity on the link is a plaintext, unauthenticated display name.** The hello frame carries the sender's name as UTF-8 (`BLETransport.swift` `received`, hello case), and links, blocking and tie-break are keyed by that name (`namedLinks[name]`, `named(_:_:)`). Two people called "Kyle" collide. Anyone in radio range can claim any name, get "blocked" peers' traffic routed to them, or knock a real peer's link off in the tie-break. Room content is still sealed (ChaCha20-Poly1305), so this is routing and spoofing, not plaintext leak. bitchat keys links by a key-derived peer ID and signs announces (whitepaper 3, 4.5). Fix: hello carries the device's Curve25519 public key plus a signature over a fresh challenge; key the link table by key fingerprint.
4. **No connection budget or scheduling.** iOS connects to every Libre peripheral it discovers (`centralManager(_:didDiscover:)` then `connect`), and Android scans `SCAN_MODE_LOW_LATENCY` continuously and advertises `LOW_LATENCY`/`TX_POWER_HIGH` forever (`BleTransport.kt` ~283, ~340). Real phones hold roughly 7 to 10 simultaneous BLE links before things degrade, and continuous low-latency scan drains battery. bitchat caps at 8 connections, RSSI-gates connects and duty-cycles scans by power profile (whitepaper 4.5, bitchat-android `PowerManager.BleSchedule`). A classroom of 30 phones will thrash.
5. **Relay is a naive full flood.** `RelayEngine.swift` does dedup (1000 ids, 300 s) and TTL 7, and the caller forwards to every link. No jitter, no duplicate-cancel, no degree-based TTL clamp, no fanout subset. Over Wi-Fi that is fine. Over BLE at single-digit KB/s per link, every message costs N transmissions per hop and collides. bitchat: 10 to 220 ms jitter, cancel when the duplicate arrives first, TTL clamp at 5 when dense, about log2(degree) fanout for broadcasts (whitepaper 4.2).
6. **Store and forward is a local outbox, not mesh sync.** `OutboxItem` (200 items, 24 h) waits for *any* link, and the Mac backfill covers room history. There is no peer-to-peer reconciliation, so a phone that walks between two partitions without the Mac carries nothing. bitchat gossips a GCS filter every ~15 s and serves 6 h of public history from any peer (whitepaper 6.3). For Libre, where the Mac is the source of truth, this matters less, but it is the core of "works across a site".
7. **Media over BLE will hurt the mesh.** Packets up to 256 KB are allowed over BLE and the per-link queue holds 6000 frames (`BLETransport.swift` `maxQueuedFrames`). One photo can occupy a link for a minute and starve text and @libre answers on that hop. No priority lanes. bitchat caps media at 1 MiB, fragments at ~469 B, requires explicit accept (whitepaper 4.4, 7). Fix: text and control first, media in a lower lane, and default media off on BLE-only links.
8. **Fragmentation is per link, not end to end (minor).** Our 11-byte frames (`BLEFraming.swift`) are reassembled at each hop and re-chunked. That is fine. `BLEReassembler` already has a 60 s timeout and a per-link memory cap (`BLEFraming.swift` lines 109 to 195), comparable to bitchat's 30 s / 1 MiB cap (whitepaper 4.4). The real cost is latency: each hop must receive the whole packet before forwarding, so a 200 KB photo pays full transfer time per hop.
9. **Android GATT reality not handled.** `BleTransport.kt` closes on any non-success status (line ~371) with no retry or backoff for the classic status 133, no connect queue (Android serializes GATT operations badly when many connects run at once), and requests MTU 517 then trusts the result. iOS rotates its BLE MAC, so Android keyed by `gatt.device.address` ("c-" + address) will see the same iPhone as new devices over time. All untested.
10. **Metadata leaks.** Fixed custom service UUID (`BAA354FA-...`) advertised by every device makes "a Libre user is here" trivially detectable, and the hello broadcasts the name in clear. bitchat documents the same weakness honestly (whitepaper 8, `docs/SERVICE-UUID-DETECTABILITY.md`). Ours is undocumented in README Security.
11. **No forward secrecy, no per-peer sessions.** Room key (PBKDF2 600k or random, ChaCha20-Poly1305) protects content, and kick rotates keys, which is good. But anyone who ever had the key can decrypt captured past traffic, and there are no direct messages. bitchat uses Noise XX per live link for forward secrecy (whitepaper 5.1). For a classroom tool this is acceptable for now; say so in README.

## 2. What we do better (keep it, it is real)
- **One encryption layer for every transport.** Wi-Fi, BLE and the browser gateway carry the same room-sealed `MeshMessage`. Room governance (signed Curve25519 manifests, kick with key rotation, co-admins, member cap) is stronger than bitchat's public-mesh model for group control.
- **Cross-language test vectors.** 14 Kotlin tests check Swift-made bytes (b11b195). That catches wire drift before devices do.
- **Honest README.** Untested and estimated claims are labelled. Keep that discipline.
- **Purpose.** bitchat is a chat app. Libre's value is the local AI and grounded team memory on the Mac. BLE only has to carry short asks and answers well, which is a much easier target than general chat with media.
- **Wi-Fi first with BLE fallback** (`LinkHub.swift`). Correct for throughput. Keep it.
- **Built-in speed probe** (4 KB, `ble-log.txt`). Good, once it produces real numbers.

## 3. What to build next for Bluetooth-first (in order)
| # | Work | Why | Effort |
|---|---|---|---|
| 1 | Two-device Wi-Fi-off test (iPhone 12 + 14, then Mac), pull `ble-log.txt`, put measured speeds in README | Nothing else matters until this passes | 0.5 day (needs Kyle's unlocked phones, Mac BT on) |
| 2 | Signed hello: public key + challenge signature, link table keyed by key fingerprint, names only for display | Fixes spoofing, name collisions, MAC rotation on Android | 1 to 1.5 days, both platforms, plus vectors |
| 3 | Connection budget (max 6 to 8), RSSI gate, connect queue with backoff, Android 133 retry | Classroom-scale stability | 1.5 days |
| 4 | Priority lanes: control and text before media; media off by default on BLE-only links | Keeps @libre answers fast | 1 day |
| 5 | Relay jitter (random 10 to 200 ms), cancel on duplicate, TTL clamp when degree is high, split horizon | Cuts airtime per message several times | 1 day, pure core logic, testable on Linux |
| 6 | Android foreground service (`connectedDevice`), persistent notification, scan and advertise duty cycle by battery and screen state | Android phones keep relaying in a pocket | 1.5 days, then device test |
| 7 | iOS background modes plus state restoration; honest README note on iOS background discovery limits | Locked iPhones can at least hold existing links | 1 day plus a long soak test |
| 8 | Peer-to-peer history sync (compact "what do you have" summary, send missing, short window such as 6 h) | Carries messages across partitions without the Mac | 2 to 3 days |
| 9 | Battery measurement: 1 h foreground and background runs on each phone, recorded in README | Turns a guess into a claim | 0.5 day of device time |
| 10 | README Security: service UUID detectability, plaintext hello, no forward secrecy | Honesty, cheap | 1 hour |

Total for 1 to 7: about 7 to 8 working days, plus device time. Items 2, 4 (caps), 5 are mostly testable on the box; 1, 3, 6, 7, 9 need real phones.

## Untested claims in README today
- "Bluetooth Low Energy between iPhones usually moves about 5 to 20 KB per second" and the per-photo timings: estimates, labelled as such. Fine, but replace with measured numbers.
- "Writes are paced by CoreBluetooth flow control, so nothing is dropped when the radio is busy": true for the write path by design, but frames are dropped silently when the 6000-frame queue is full (`enqueue` guard). Reword.
- Android app section: correctly marked untested on a real phone.
