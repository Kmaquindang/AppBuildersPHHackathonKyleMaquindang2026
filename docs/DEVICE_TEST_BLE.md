# Device test: Bluetooth only, Wi-Fi off (issue #1)

Goal: prove that two iPhones and the AI Mac work over Bluetooth alone, and replace the estimated speeds in README "Bluetooth mode" with measured ones. About 45 minutes.

## What you need
- The AI Mac (Libre-macOS, Ollama running, a model loaded) with Bluetooth on.
- Two iPhones with a build of Libre that includes the "Share Bluetooth log" button (Connection sheet, debug section). Install from Xcode as usual.
- All three devices in the same room (within a few meters for the first run).

Write down before you start: date, time, iPhone models and iOS versions, Mac model and macOS version, Libre commit (`git rev-parse --short HEAD`).

## 0. Note the start time
Each device keeps its own `ble-log.txt` (it trims itself to the last 32 KB), and every line starts with a UTC timestamp. Nothing needs deleting. Run this on the Mac right before step 1 and keep the output:
```
date -u +%Y-%m-%dT%H:%M
```

## 1. Two phones, Wi-Fi off
1. On both iPhones: Settings > Wi-Fi > off (Control Center only disconnects, it keeps the radio). Bluetooth stays on. Quit Libre on the Mac for this step (or switch the Mac's Bluetooth off) so the phones can only reach each other.
2. Open Libre on both phones, keep them on screen.
3. Tap the room title to open the Connection sheet. Wait until the other phone shows "linked over Bluetooth". Write down how long it took.
4. Turn on "Show debug info". The Bluetooth line shows the probe speed per device. Screenshot it on each phone.
5. Send 5 short texts from phone A, then 5 from phone B. Long-press one received message > Details: it should say "Arrived via Bluetooth".

Pass: texts arrive both ways, Details says Bluetooth.

## 2. Ask the Mac over Bluetooth
1. Open Libre on the Mac (Bluetooth on, Wi-Fi off on the Mac too if you want a strict test; your call, the app does not change it).
2. On a phone, wait for the Mac to show "linked over Bluetooth" and the AI line to show the Mac.
3. Ask 5 questions, for example `@libre what are the room rules?` and `@libre summarize today`. Wait for each answer before the next.
4. Long-press each answer > Details: note "Round trip ... ms (measured on this device)" and "via Bluetooth".

Pass: every ask answered; the round trip is recorded on the phone.

## 3. Two hops over Bluetooth
1. On phone A: Connection sheet > "Demo: forced relay" > turn on the switch for the Mac. Phone A now has no direct link to the Mac.
2. Check that phone B is linked to both phone A and the Mac (over Bluetooth).
3. On phone A, ask 5 questions. In Details for each answer, the path should list phone B in the middle.
4. Send 3 texts from the Mac's chat; on phone A they should show 2 hops in Details.
5. Turn the forced relay switch off again.

Pass: answers arrive on phone A through phone B; Details shows the path.

## 4. Collect the logs
1. Turn Wi-Fi back on on the phones (AirDrop needs it).
2. On each phone: Connection sheet > Show debug info > "Share Bluetooth log" > AirDrop to the Mac (or Save to Files). Rename them, for example `iphone12.txt`, `iphone14.txt`.
3. Mac log: `cp ~/Library/Containers/com.kmaquindang.libre.mac/Data/Library/Application\ Support/Libre/ble-log.txt ~/Desktop/mac.txt`
4. Summarize, using the start time from step 0:
   ```
   python3 scripts/ble_log_summary.py --since 2026-10-13T01:00 ~/Desktop/iphone12.txt ~/Desktop/iphone14.txt ~/Desktop/mac.txt
   ```
5. Send me the summary output, the screenshots, and anything that failed (what you did, what you saw). The logs hold device names and numbers only, no message text; still, do not commit the raw logs, only the numbers.

## What I do with the results
- Put the measured probe KB/s, link-up time, and @libre round trips (1 hop and 2 hops over Bluetooth) into README "Bluetooth mode" and "Measured performance", with the date and devices.
- Keep anything not measured (photo and voice over Bluetooth, range, battery) labeled as an estimate or "not yet measured".
- File each failure as its own issue with the relevant log lines.
