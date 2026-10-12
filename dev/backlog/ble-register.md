# Claim the Bluetooth session before building the app

Spec only — no implementation. Splits "register with `bluetoothd`" from
"ready to process device events", and moves the first half to the top of
`AppComposition.init`.

## Motivation

On 2026-08-15 at 22:43 the app was launched in the background, spent its
entire 30-second wall-clock allowance decoding `closed_loop_results.json`
on the main thread, and was killed by the process-launch watchdog
(`BioKernel-2026-08-15-224405.ips`). It did not run again for several
hours.

The crash landed in `LoopRunner.init` — **Tier 6** of the composition.
The CGM and pump managers are constructed in `LocalDeviceDataManager`,
**Tier 7**, the last thing `AppComposition.init` does. So the app was
woken for a Bluetooth event and killed before it ever created a
`CBCentralManager`.

Exactly one crash report exists for that night. If the system had kept
waking us every ~5 minutes for G7 advertisements, we would have a stack
of them. We don't, which is consistent with: nothing asked for us again.

## Hypothesis under test

> When iOS relaunches an app for a CoreBluetooth event and the app is
> killed before re-instantiating its `CBCentralManager` with the matching
> restore identifier, the system drops the restoration state and stops
> generating those wakes.

This is empirically plausible but not documented by Apple, and this spec
does not prove it. It is written so that shipping the change *is* the
experiment — see Verification.

## The two things currently conflated

**Claim** — telling `bluetoothd` we exist and want our restored session
back. This is a pure side effect of *constructing* the LoopKit device
managers:

    CGMManagerFromRawValue(raw)
      -> G7CGMManager(rawState:)                      G7CGMManager.swift:211
      -> G7Sensor(sensorID:)                          G7Sensor.swift:94  (stored property)
      -> G7BluetoothManager()
      -> CBCentralManager(..., CBCentralManagerOptionRestoreIdentifierKey:
                               "com.loudnate.CGMBLEKit")   G7BluetoothManager.swift:131

    pumpManagerFromRawValue(raw)
      -> OmniPumpManager(rawState:)                   OmniPumpManager.swift:100
      -> BlePodComms.init                             BlePodComms.swift:33
      -> BluetoothManager(podType:)
      -> CBCentralManager(..., CBCentralManagerOptionRestoreIdentifierKey:
                               "com.OmnipodKit")          BluetoothManager.swift:148
      -> bluetoothManager.connectToDevice(uuidString: podState.bleIdentifier)

Both are `managerQueue.sync` calls onto a private serial queue. **The
only input either needs is a `@PersistedProperty` plist read** —
`"CGMManagerState"` and `"PumpManagerState"`, each a `Data(contentsOf:)`
plus `PropertyListSerialization` against a file in Documents
(`PersistedProperty.swift:31-42`). Neither touches any service in the
composition graph. That is what makes this movable.

**Adopt** — becoming able to act on what those peripherals report. This
is everything the `didSet` observers and `setup*` methods do, and it is
genuinely late-tier:

* `cgmManager.didSet` (`DeviceDataManager.swift:209`) — main-queue
  precondition, `setupCGM()`, writes `rawCGMManager` back to disk, then
  an async block reading `glucoseStorage.lastReading()` and publishing to
  `observableState`.
* `setupCGM()` (`:271`) — assigns `cgmManagerDelegate` and
  `delegateQueue`, calls `updatePumpManagerBLEHeartbeatPreference()`.
* `pumpManager.didSet` (`:238`) / `setupPump()` (`:280`) — same shape,
  plus `insulinStorage.setPumpRecordsBasalProfileStartEvents(...)`.
* `MosPumpManagerDelegate` needs `insulinStorage`, `alertStorage`,
  `observableState`, `settingsStorage`; `MosCgmManagerDelegate` needs a
  back-reference to the `DeviceDataManager`.

Claim needs a plist. Adopt needs most of the app. Today they happen in
the same statement.

## Proposed design

### Phase A — claim, at the top of `AppComposition.init`

Construct the CGM and pump managers from their persisted raw state and
hold them. Do not assign them to any `DeviceDataManager` property, do
not wire delegates, do not publish to `observableState`.

Constraints on Phase A:

* **Must not touch the graph.** Only `PersistedProperty` reads and the
  two `*FromRawValue` factories. If it ever needs a service, the split
  has failed.
* **Must retain what it builds.** If ARC releases a manager before
  adoption, the `CBCentralManager` goes with it and the claim is undone.
* **Must be the sole constructor.** Two `CBCentralManager`s sharing one
  restore identifier is undefined territory; Phase B has to take
  ownership of these instances, never build its own.
* **Nil is normal.** No configured CGM or pump means no plist, means no
  manager, means no claim. Not an error.

### Phase B — adopt, where Tier 7 is today

`LocalDeviceDataManager` gains a constructor seam — pre-built managers
passed in — and `setupCgmManager()` / `setupPumpManager()` prefer an
injected instance over constructing one. Everything else about Tier 7
stays exactly where it is.

Deliberately *not* proposed: moving `LocalDeviceDataManager` itself
earlier. That would put device callbacks in a window where
`alertsBox`, `watchCommsBox`, `backgroundBox`, and `closedLoopBox` are
still unset, and `LateBound.resolve()` calls `fatalError`
(`AppComposition.swift:317-324`). Splitting claim from adopt avoids that
hazard by construction rather than by managing it, which is the main
argument for this shape over the simpler reordering.

### Why this survives a doomed launch

`willRestoreState` and every other `CBCentralManagerDelegate` callback
are delivered on the managers' private `managerQueue`s, not the main
thread. A main thread wedged in `JSONDecoder` does not block them. So a
launch that will be killed at t=30s still completes its claim and its
restoration handshake at t≈50ms, on another queue, before dying.

## Hazards

**1. Events in the claim→adopt gap.** `G7Sensor.delegate` is set inside
`G7CGMManager.init`, so the manager receives readings and updates its own
state during the gap — but `cgmManagerDelegate` is nil, so LoopKit-level
delivery goes nowhere. A reading arriving in that window is dropped.
Options, in order of preference:

  1. *Accept it and measure.* On a healthy launch the gap is
     milliseconds. On a starved launch we are being killed anyway, and a
     dropped reading is strictly better than a lost wake. G7 backfill
     likely re-delivers on the next connection — **verify this rather
     than assume it.**
  2. *Reconcile at adopt.* After Phase B, pull the manager's cached
     latest reading and feed it forward if newer than what glucose
     storage has.
  3. *Buffering shim delegate.* Install a trivial delegate at Phase A
     that queues events, drain it at Phase B. Correct, and more moving
     parts than the problem currently justifies. Note `cgmManagerDelegate`
     is weak — a shim has to be retained.

  The pump side is lower risk: the pod's own event log is the source of
  truth and is re-read on the next sync, which is the same property
  `stateful-issue.md` leans on.

**2. File protection ordering.** Phase A reads two plists from
Documents. `migrateExistingFilesToNoFileProtection()` currently runs
first in `AppComposition.init` precisely because a pre-first-unlock wake
can otherwise fail to read. Files written by recent builds are already
`.noFileProtection`, so Phase A ahead of the migration is *probably*
safe — but not for a device carrying legacy files. Decide explicitly:
either keep the migration first and accept its directory enumeration on
the critical path, or narrow it to the two plists Phase A needs. Do not
leave this implicit.

**3. Cost of Phase A itself.** Two plist reads plus two
`managerQueue.sync` hops. Should be single-digit milliseconds, but it is
now the first thing that can block a background launch, so it needs a
number rather than a guess.

**4. Test path.** `BioKernelApp.init` skips `AppComposition()` entirely
under `isRunningTests`, so there is no direct test exposure — but the
Phase B seam should be constructor-injected (defaulting to nil) so it
stays testable.

## Open questions

* Which gap-handling option above, and does G7 backfill actually cover a
  reading dropped during launch?
* Migration before or after Phase A?
* Should Phase A also cover the Mock managers, or only the two real ones?
* Does a `CBCentralManager` created and then held with no delegate
  activity for several seconds behave identically to one created at the
  normal time? Assumed yes, unverified.

## Verification

**Instrumentation.** `DiagnosticLog` timestamps (subsystem
`com.getgrowthmetrics.BioKernel`, which reaches the unified log — note
`print()` does not) at three points: entry to `AppComposition.init`,
completion of Phase A, completion of `init`. Target: Phase A under
~50 ms of wall clock on a healthy launch. This also gives us the
launch-cost baseline we currently lack.

**The field experiment.** If the hypothesis holds, the next starvation
event produces a *cluster* of watchdog `.ips` files roughly five minutes
apart instead of a single report followed by silence. Same kill, much
shorter outage — and either outcome settles the question. Add
`MXAppExitMetric.backgroundExitData.cumulativeAppWatchdogExitCount` so we
learn this from telemetry instead of from a bad night.

**Manual.** Kill the app from Xcode with a G7 session active and confirm
it is relaunched on the next broadcast; confirm pod reconnect is
unchanged; confirm no duplicate `CBCentralManager` is created.

## Non-goals

* **Does not prevent the watchdog kill.** It shortens recovery from hours
  to minutes-after-the-storm. Preventing the kill means not needing the
  CPU during launch, which is the `closed_loop_results.json` deferral —
  tracked separately, and the thing that actually closes this out.
* Does not change the BGTask re-arm ordering in `BioKernelApp.init`
  (same principle — claim your wake-up sources before doing work — but a
  separate change).
* No notification or push work.

## Rollback

Self-contained: Phase A is additive and Phase B is a preference for an
injected instance over a constructed one. Reverting means dropping the
seam and letting `setup*Manager()` construct as it does today. No
persisted format changes, no migration.

## Risk worth naming

If the hypothesis is right, we convert one silent multi-hour outage into
a launch attempt every five minutes for the duration of the storm. That
is better — we recover as soon as the storm passes — but repeated launch
failures are also the condition most likely to trigger any system-level
backoff, which is the mechanism the single `.ips` file argued we had not
been hitting. Watch for it in the crash-report cluster.
