# Device test: Android first run (issue #3)

Goal: run the Android app on a real phone for the first time and record each of the 9 checklist steps as PASS, FAIL (with what you saw) or BLOCKED. About 1 hour. Do the iPhone Bluetooth test (docs/DEVICE_TEST_BLE.md) first if you can: it tells us whether a failure is Android or Bluetooth in general.

## What you need
- An Android phone, Android 8 (API 26) or newer, with Developer options and USB debugging on (Settings > About phone > tap Build number 7 times, then Settings > System > Developer options > USB debugging).
- A USB cable to the Mac.
- An iPhone with Libre, and the AI Mac with Libre and Ollama running, Bluetooth on.
- The Android SDK tools on the Mac. `adb` is at `~/Library/Android/sdk/platform-tools/adb`. Add it to your shell for this session:
  ```
  export PATH="$HOME/Library/Android/sdk/platform-tools:$PATH"
  ```

## Build and install
From the repo root:
```
cd android && JAVA_HOME=/opt/homebrew/opt/openjdk@17 ./gradlew assembleDebug
```
```
adb devices
```
Accept the "Allow USB debugging" prompt on the phone, then:
```
adb install -r app/build/outputs/apk/debug/app-debug.apk
```
Record the phone:
```
adb shell getprop ro.product.model
```
```
adb shell getprop ro.build.version.release
```
Clear old logs so only this run is captured:
```
adb logcat -c
```

## The 9 steps
Write PASS, FAIL or BLOCKED for each, plus one line of what you saw.

| # | Step | How to check |
|---|---|---|
| 1 | Install and onboarding | Open Libre, enter a name (a made-up one is fine), allow Nearby devices (Android 12+) or Location (Android 11 and older). |
| 2 | Links to an iPhone over Bluetooth | Open Libre on the iPhone. The Android header shows 1 linked. The iPhone's Connection sheet shows the Android phone "linked over Bluetooth". |
| 3 | Town Square text both ways | Send a text from each side; both show it. |
| 4 | Code room join through the Mac | On the Mac, create a code room. On Android, join with the code; the Mac admin approves. Send a text each way; both read it. |
| 5 | `@libre` answered by the Mac | Ask `@libre what are the room rules?` on Android. Answer arrives with rule chips; its details show the path and "Bluetooth". |
| 6 | Relay through Android | iPhone Connection sheet > Demo: forced relay > on for the Mac. Android sits between them. Ask on the iPhone; the answer's path lists the Android phone. Turn forced relay off after. |
| 7 | Bluetooth off and on, background and foreground | Turn Bluetooth off on Android for 10 s, then on. Then press Home for 30 s and reopen Libre. Links come back without restarting the app. Note how long each took. |
| 8 | One link per peer | With the iPhone linked, toggle the iPhone's Bluetooth off and on (its Bluetooth address changes). Android still shows one entry for the iPhone, not two. With two Android phones, check each shows the other once. |
| 9 | Waiting count and text wrapping | Move away from everyone (or turn Bluetooth off on the others), send a text: "waiting to send" shows 1. Come back: it clears. Set a very long name and send a long word; nothing is cut off. |

## Collect the logs
```
adb logcat -d -s LibreBLE LibreMesh > ~/Desktop/android.txt
```
```
python3 scripts/ble_log_summary.py ~/Desktop/android.txt
```
The log holds device names and numbers only, never message text. Send me the filled-in table, the summary output, and for any FAIL the matching lines from `android.txt` (or the whole file). Screenshots help for steps 2, 5 and 9.

## What I do with the results
- Update README "Android app" from the results, still saying what was not tested.
- File each FAIL as its own issue with the logcat lines (names replaced with placeholders).
