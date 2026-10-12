# Device test: battery (issue #7)

Goal: real battery numbers for Libre, recorded with date, device and conditions. Libre now logs its own battery level, so a run is mostly waiting: each phone writes a `BAT` line every 5 minutes and whenever Libre opens or closes (iPhone: `ble-log.txt`; Android: logcat, tag `LibreMesh`).

## Before every run
- Phone charged to 80% or more, not charging, other apps closed, Low Power Mode off.
- Note the screen brightness (the log records it too) and keep it the same across runs.
- On the Mac, note the start time: `date -u +%Y-%m-%dT%H:%M`
- Android only: `adb logcat -c` to clear old lines.

## Synthetic traffic (for the "message rate" runs)
Quit Libre on the Mac, then start it with one synthetic team chat per minute:
```
open -a /Applications/Libre.app --args -LibreSyntheticChatEvery 60
```
The messages say "Synthetic test message N (battery run, no real content)". This works in debug builds only. Quit and reopen Libre normally to stop it.

## The runs (1 hour each)
| Run | Libre | Wi-Fi on the phone | Traffic |
|---|---|---|---|
| 1 | on screen | on | idle |
| 2 | on screen | off | synthetic, 1 per minute |
| 3 | in the background (locked) | on | idle |
| 4 | in the background (locked) | off | synthetic, 1 per minute |

Do them on each iPhone, and on an Android phone with "Keep relaying in the background" turned on for runs 3 and 4. Runs 1 and 3 can go on two phones at once.

## Collect and summarize
- iPhone: Connection sheet > Show debug info > Share Bluetooth log, or ask me to copy it off the phone.
- Android: `adb logcat -d -s LibreBLE LibreMesh > ~/Desktop/android.txt`
- Then:
  ```
  python3 scripts/ble_log_summary.py --since <start time> <log files>
  ```
  The battery rows show the device, start and end %, run length, drain per hour, and links held.

## What goes in the README
One row per run: device, OS, run type, brightness, links held, drain per hour, date. A single run is a first data point, not an average; say so. Anything not measured stays "not yet measured".
