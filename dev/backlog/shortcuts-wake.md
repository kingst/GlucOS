# Shortcuts wake — a periodic background launch that re-arms Bluetooth

Scope for a BioKernel App Intent that a Shortcuts "Time of Day" automation
can run in the background on a locked phone. Ground truth for the code
references below is `main` at 454c446, with `ios/G7SensorKit` at f455451.
Companion docs: @dev/backlog/g7_sensor_kit_fix.md (the Oct 22 incident and
the log tooling) and the 2026-10-29 archive at `phone-2026-10-30.logarchive`.

## 1. Why

On 2026-10-29 at 22:01:43 mmaintenanced forced a userspace reboot (user
reclaimable memory 64% against a 65% floor; Oct 22 was 63%). The new
bluetoothd restored BioKernel's two sessions and, at 22:02:20, resurrected
the app with a 15 second timer. The device was at 67% CPU relaunching
everything; BioKernel got 0.58 s of CPU in 30 s, reached its first central
(`BluetoothStateManager`, no restore id) at +7 s, and never reached the G7
and Omnipod centrals, which on an idle launch follow 20 ms later. At +11.5 s
bluetoothd logged `App Restored but TCCDone missing` and
`Reaping Disconnected Session` for both `com.loudnate.CGMBLEKit` and
`com.OmnipodKit`; at +30 s SpringBoard killed the process
(`0x8BADF00D process-launch watchdog`). From then on nothing on the phone
had a reason to launch BioKernel:

- bluetoothd had no session left to restore.
- `BGAppRefreshTask` was vetoed every minute by dasd's SmartPowerNap policy
  (`smartPowerNap == YES AND LaunchReason == BackgroundRefresh`), as on
  Oct 22.
- The pod heartbeat is off because the G7 manager reports
  `providesBLEHeartbeat` (`DeviceDataManager.swift:342`).
- The two dasd launches at 22:04:15 and 22:06:35 were `DYLD3 Closure
  Generation` prewarms: the process existed all night and never ran `main`.
- The Dexcom app lost the same race three times, was reaped at 22:06:04,
  and only came back at 23:09:27 because its watch app sent a
  WatchConnectivity request that made wcd open it. BioKernel's watch app has
  no equivalent.

The loop stopped at 22:00:24 and resumed at 00:15:28 when Sam opened the
app. The pod ran a 0 U/h temp basal until 22:30:32 and then its fallback
schedule. No alert fired because BioKernel has no stale-data alert.

The kit fix from Oct 22 (#100) was in this build and is not at fault. What
is missing is a launch vehicle that does not depend on bluetoothd still
holding a session and that dasd does not veto overnight. Any launch of
BioKernel is enough: `BioKernelApp.init` builds `AppComposition`, which
creates the three centrals with their restore identifiers, and bluetoothd
registers new restorable sessions on the spot (observed at 00:14:42: three
`XPC check-in`s and `Registering central session … persistence: on` within
60 ms of launch, `Retrieved peripheral` from the kit, first reading 46 s
later).

## 2. What changes, in one sentence

BioKernel gains one `AppIntent` that runs in-process without opening the
app and re-arms the CGM connection, so that a stack of Time of Day
automations can launch BioKernel every 30 minutes overnight. It does
nothing else: no notification, no result the shortcut acts on.

## 3. The intent

```swift
// BioKernel/Intents/CheckCgmConnectionIntent.swift  (app target ONLY)
import AppIntents
import UIKit

struct CheckCgmConnectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Check CGM Connection"
    static let description = IntentDescription(
        "Wakes GlucOS in the background and re-arms its sensor and pump connections."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let composition = (UIApplication.shared.delegate as? MyAppDelegate)?.composition else {
            throw CheckCgmConnectionError.notReady
        }
        await composition.deviceDataManager.checkCgmData()
        composition.backgroundService.scheduleAppRefresh()
        return .result()
    }
}
```

Decisions behind it:

- **Reaching the composition through `MyAppDelegate.composition`**
  (`BioKernelApp.swift`, set in `BioKernelApp.init`). The system instantiates
  intents, so constructor injection is not available; the delegate is the
  seam that already exists for the push handler, and it avoids adding a
  global registry. `composition` is nil under `isRunningTests`; the intent
  throws rather than crashing, and must not force unwrap.
- **`checkCgmData()`, not `refreshCgmAndPumpDataFromUI()`**
  (`DeviceDataManager.swift:375` vs `:361`). For the G7 manager,
  `fetchNewDataIfNeeded` only calls `resumeScanning()` and returns `.noData`
  (`G7CGMManager.swift:222`), which is exactly the re-arm we want and
  returns immediately. The UI variant also runs `ensureCurrentPumpData`, a
  pod round trip we do not want inside an intent's time budget.
- **Re-submitting the app refresh** (`BackgroundService.swift:62`) is free
  and keeps the daytime watchdog chain alive after a relaunch.
- **No result, no alert** (decision). Sam would rather sleep: when the
  loop is down the pod falls back to its scheduled basal rate, which is an
  acceptable failure mode for a few hours. The intent returns nothing the
  shortcut could branch on, and the shortcut has no notification step.
- **`authenticationPolicy = .alwaysAllowed`** so the intent runs while the
  phone is locked. BioKernel's files are already `NSFileProtectionNone`
  (`AppComposition.migrateExistingFilesToNoFileProtection`), so a launch
  before first unlock can read them.
- **Log through `DiagnosticLog`**, not `print`. Two lines at default level,
  category `CheckCgmConnectionIntent`: one on entry, one on exit with the
  age of the last reading in minutes, from `glucoseStorage.lastReading()` as
  `DeviceDataManager.swift:220` already does, so the archive shows whether
  the wake found a live or a stale store. Diagnostics only; nothing acts on
  it. `print` is lost in a TestFlight build; os_log is what we read back
  with `log collect`.
- **App target only.** Do not put the intent in a framework or in a file
  shared with `LauncherWidget` or the watch app: App Intents run in whichever
  process compiled them, and the widget extension has no composition.
- **No `AppShortcutsProvider` in v1.** Any discoverable `AppIntent` shows up
  as an action under the app's name in the Shortcuts editor, which is all
  the automation needs. Siri phrases can come later.
- **iOS 26 SDK note.** The deployment target is 18.6, so `openAppWhenRun`
  is the right spelling. If the pinned SDK deprecates it in favour of
  `supportedModes = .background`, use whichever compiles without a warning;
  the behaviour is the same.

Optional, if cheap: persist `lastShortcutWakeAt` and show it as a row in
Settings, so the phone itself can say when the watchdog last ran.

## 4. The shortcut and the automations (user setup, not code)

One shortcut, named **GlucOS watchdog**, with a single action:
`Check CGM Connection` (GlucOS). Nothing after it.

Then one personal automation per slot, each **Time of Day**, **Daily**,
**Run Immediately**, **Notify When Run off**, action **Run Shortcut →
GlucOS watchdog**. Start with the night window, 22:00 to 05:30 every 30
minutes (16 automations). Running the named shortcut rather than embedding
the action in each automation keeps one place to edit if the shortcut ever
grows a second step.

Shortcuts has no interval trigger; this stack is the only way to get a
cadence. Automations live on the phone, not in the app, so they do not
survive a new phone and are not part of the build.

## 5. Verification

The archive from Oct 29 is the control: between 22:03 and 00:14 bluetoothd
said nothing about BioKernel and the only launches were dasd prewarms.

**Phase A, foreground.** Run the shortcut from the Shortcuts app with
BioKernel suspended. Expect the two intent log lines and
`CGMManager: did update with no data` from `DeviceDataManager`.

**Phase B, locked and asleep.** Create one automation three minutes out,
lock the phone, wait ten minutes, then on USB:

```
/usr/bin/log collect --device-udid 00008120-001A399E0CE9A01E --start "<slot minus 2 min>" --output test.logarchive
/usr/bin/log show --archive test.logarchive --info --predicate 'process == "runningboardd" AND eventMessage CONTAINS "BioKernel" AND (eventMessage CONTAINS "launching job" OR eventMessage CONTAINS "Acquiring assertion")' --style compact
/usr/bin/log show --archive test.logarchive --info --predicate 'process == "bluetoothd" AND eventMessage CONTAINS "com.getgrowthmetrics.BioKernel" AND (eventMessage CONTAINS "check-in" OR eventMessage CONTAINS "Registering central" OR eventMessage CONTAINS "Connect Requested")' --style compact
/usr/bin/log show --archive test.logarchive --info --predicate 'process == "BioKernel" AND (subsystem == "org.loopkit.G7SensorKit" OR subsystem == "com.getgrowthmetrics.BioKernel")' --style compact
```

Pass means: a launch at the slot time whose originator is the Shortcuts
runner, not dasd; three `XPC check-in`s and `Registering central session …
persistence: on` for the two restore ids; `Retrieved peripheral 78F72DC7…`
and `Making peripheral active` from the kit; the intent's exit line with a
plausible minutes value; and the screen stayed off. Also confirm there is no
`dasd` decision for this launch at all, which is the point.

**Phase C, dead app.** On a development build, stop the app from Xcode
(SIGKILL, relaunch-eligible, the closest proxy to the Oct 29 state) and let
the next automation fire. Expect the same signatures plus a fresh pid.
Separately, try once after a swipe-kill from the app switcher: iOS treats
user force-quits as ineligible for background launches, and whether an
in-app intent overrides that is worth knowing but is a stricter case than
the real failure.

**Phase D, in the field.** Run the night stack for a week. Each morning
grep for `Reaping Disconnected Session com.getgrowthmetrics.BioKernel`; if
it appears, the next slot's launch should follow within 30 minutes and
readings should resume on the following sensor cycle.

## 6. Not in scope

- Any change under `ios/G7SensorKit`, `ios/OmnipodKit` or `ios/LoopKit`.
- Reordering `AppComposition` so the centrals are created first. Worth doing
  separately: it would have let BioKernel win the 15 s resurrection race,
  but the Dexcom app lost the same race three times with a far smaller
  launch, so it is not a substitute for a second launch vehicle.
- Any stale-data alert, in the app or in the shortcut. Decided against:
  the pod's scheduled-basal fallback is acceptable overnight and sleep is
  worth more than a 30-minute-earlier recovery.
- HealthKit background delivery between g7lite and BioKernel, server or
  CloudKit pushes, the pod heartbeat. Each is its own doc if pursued.
- Wiring the empty device-log sink in `DeviceDataManager+CGM.swift:34`.
  Still a FIXME; still the reason the kit's own session-end lines are not in
  the log.

## 7. Open questions

1. Does a Time of Day automation fire during SmartPowerNap? Expected yes,
   since the launch is a FrontBoard open request like wcd's rather than a
   dasd activity, but the phone currently has zero automations registered,
   so Phase B is the first evidence.
2. What is the intent's execution budget when launched in the background
   from an automation? Keep `perform()` to the three calls above until
   measured.
3. Does Shortcuts relaunch a force-quit app for an in-app intent (Phase C,
   second half)?
