# Meal soon — a timed target override

Scope for the "meal soon" feature. Ground truth for the code references
below is `main` at 9882ce6.

The requirement, as first written:

> This feature is a new setting that allows the user to manually specify
> that they are going to eat a meal soon. When this feature is enabled
> it will:
>
> - Lower the target glucose by 15 mg/dl with a minimum target of 75
>   mg/dl
> - The setting stays in place for 60m before turning it off, or the
>   user issues a manual bolus (which ever happens first).
>
> From a UI perspective, we should have a small view visible below the
> summary view and any alert views that display. It should say something
> like "Meal happening soon, lower target to X"

## 1. What changes, in one sentence

`TargetGlucoseService` stops being a pass-through and starts answering
"what target, and why" from a stored override plus the clock, the loop
record store gains a `target_override` table that is both the live state
and the log, every `loop_result` row records the target it dosed toward,
the glucose chart draws it, and a new "Settings automation" screen
holds the switch. Settings do not change.

## 2. Where the target flows today

### 2.1 One read, three consumers

The pipeline reads the target exactly once per tick
(@ios/BioKernel/BioKernel/DataTypes/ClosedLoopDataTypes.swift:317) and
threads that one number into:

- the PID error, `filteredGlucose - target`
  (@ios/BioKernel/BioKernel/Services/PhysiologicalModels.swift:205);
- the ML dynamic-ISF scaling, which grows with `glucose - target`
  (@ios/BioKernel/BioKernel/Services/MachineLearning.swift:92-93);
- the micro-bolus gate, which opens at `target + 20`
  (@ios/BioKernel/BioKernel/DataTypes/ClosedLoopDataTypes.swift:183).

The service it reads from clamps the settings value to [70, 140] and
returns it (@ios/BioKernel/BioKernel/Services/TargetGlucoseService.swift:17-25).
Its header comment says it exists as the future hook for lowering the
target before a meal. This feature is that hook, so nothing new has to
be threaded through the pipeline: change what the hook returns and all
three consumers follow.

### 2.2 What the record store keeps

Nothing about the target. `PipelineOutputs.targetGlucoseInMgDl`
(@ios/BioKernel/BioKernel/DataTypes/ClosedLoopDataTypes.swift:254) is
dropped by the `LoopRecordSnapshot` projection
(@ios/BioKernel/BioKernel/DataTypes/LoopRecord.swift:127-135) and the
`loop_result` table has no column for it
(@ios/BioKernel/BioKernel/Services/GRDBLoopRecordStore.swift:433). §9 of
@dev/backlog/loop-record-store-grdb.md lists it among the audit-only
fields and says promoting one is a v2 migration and a NULL on old rows.
§6 below does that.

## 3. Why not settings

The obvious shortcut is to write `targetGlucoseInMgDl - 15` into
`CodableSettings` and write it back later. It is the wrong layer:

- **Expiry needs a writer.** Something has to restore the target at 60
  minutes or on a bolus. If the app is killed or suspended first, the
  lowered target is stuck, and the therapy settings form shows 75 as
  though the user chose it. That failure is silent.
- **It needs somewhere to remember the original.** So the override state
  exists anyway, and settings have been corrupted for nothing.
- **The settings write path does more than write.** `persistUpdatedSettings`
  is FaceID-gated and syncs the basal schedule and delivery limits to the
  pod (@ios/BioKernel/BioKernel/ViewModels/SettingsViewModel.swift:112-156).
  A direct `writeToDisk` sidesteps that, and then two writers share one
  file.
- **Records would lie.** `ClosedLoopResult.settings` would carry a target
  the user never set.

The same reasoning rules out building a modified `CodableSettings` ahead
of `pipeline.run`: it dodges the hook that exists for this and makes
the in-memory result misreport the user's configuration.

On the algorithm-input path the override is a pure function of a stored
start time and the clock, evaluated on every tick. If the app dies at
minute 30, the first tick after minute 60 computes "expired" from the
row. Nothing can get stuck, because there is no state to restore.

## 4. Design

### 4.1 The rule, as a pure function

```swift
enum MealSoonPolicy {
    static let dropMgDl = 15.0
    static let floorMgDl = 75.0
    static let duration: TimeInterval = 60.minutesToSeconds()

    /// The override's target for a given settings target.
    static func target(settingsTargetMgDl: Double) -> Double {
        max(settingsTargetMgDl - dropMgDl, floorMgDl)
    }

    /// What `override` is at `at`, given the doses the pump reported
    /// that overlap `[startedAt, min(at, expiresAt))`.
    static func status(
        of override: TargetOverride,
        at: Date,
        doses: [DoseEntry]
    ) -> TargetOverrideStatus
}

enum TargetOverrideStatus: Equatable {
    case active
    case ended(at: Date, reason: TargetOverrideEndReason, bolusSyncIdentifier: String?)
}
```

`status` checks, in this order:

1. A row with `endedAt` set is ended, with its stored reason. Cancelling
   from the UI closes the row directly (§5.3), so this is how the rule
   sees a cancel.
2. The **earliest** dose with `type == .bolus`, `automatic != true`, and
   `startDate` in `[startedAt, min(at, expiresAt))` ends it at that
   dose's `startDate`, reason `.manualBolus`, carrying the dose's
   `syncIdentifier`. Earliest, so the logged end is when the override
   actually stopped applying, not when we noticed.
3. `at >= expiresAt` ends it at `expiresAt`, reason `.expired`.
4. Otherwise it is active.

The existing [70, 140] clamp applies *after* the drop and stays the last
word. With the settings picker's 80..140 range
(@ios/BioKernel/BioKernel/ViewModels/SettingsViewModel.swift:52) the
override lands in 75..125.

The target is computed from the **current** settings target on every
tick, not frozen at start. If the user changes their target mid-override
the override follows it. The row's `settings_target_mg_dl` is a record of
what the target was when the override began, not the value in use.

### 4.2 Ending on a manual bolus: derived from pump records

The two bolus entry points are `BolusView`
(@ios/BioKernel/BioKernel/Views/BolusView.swift:60) and the meal
announcement flow
(@ios/BioKernel/BioKernel/ViewModels/MealsViewModel.swift:618-627). The
tempting design is to call "end the override" from both after
`enactBolus` succeeds. This doc derives the end from the pump's own
report instead, for the same reason `lastMicroBolus` is a store query
and the scheduled basal rate is read off resumes: a fact derived from
the record cannot drift from it, and it covers every path including
ones that do not exist yet.

The chain is verified end to end:

- LoopKit's `BolusActivationType.isAutomatic` is true only for
  `.automatic` (@ios/LoopKit/LoopKit/DeviceManager/BolusActivationType.swift:16).
  Both app entry points use manual activation types; the loop's
  micro-bolus uses `.automatic`
  (@ios/BioKernel/BioKernel/Services/ClosedLoopService.swift:332).
- The pod driver passes `activationType.isAutomatic` into the bolus
  command (@ios/OmnipodKit/OmnipodKit/PumpManager/OmniPumpManager.swift:2754),
  and encodes it in the pod's program reminder interval, so it survives
  being read back from the pod.
- `PumpEventRecord.automatic` carries it into the store
  (@ios/BioKernel/BioKernel/DataTypes/PumpEventRecord.swift:182), and
  `InsulinStorage.pumpEvents(from:to:)` reads a bounded window back out
  (@ios/BioKernel/BioKernel/Services/InsulinStorage.swift:195). That
  query filters only on `deleted_at`
  (@ios/BioKernel/BioKernel/Services/GRDBInsulinRecordStore.swift:1174),
  so an in-progress, still-mutable bolus is visible the moment the pod
  acknowledges it.

Two details the rule has to own because the query does not:

- The window query tests **overlap**, so a bolus that started before
  `startedAt` and is still delivering comes back. The `startDate >=
  startedAt` test in §4.1 is what excludes it.
- A bolus whose `automatic` is **nil** counts as manual. Ending early
  means a higher target and less insulin, which is the safe side of an
  unknown. It is not expected from the pod driver.

What this costs: one bounded, indexed pump-event read per tick while an
override is open, over at most 60 minutes of rows. The loop already
reads far more than that from the same store for IOB and the data frame.

### 4.3 The service

```swift
public enum TargetGlucoseSource: String, Codable, Sendable {
    case settings
    case mealSoon
}

public struct TargetGlucose: Codable, Equatable, Sendable {
    let mgDl: Double
    let source: TargetGlucoseSource
}

public protocol TargetGlucoseService {
    /// The target the pipeline doses toward at `at`, and where it came from.
    func targetGlucose(at: Date, settings: CodableSettings) async -> TargetGlucose
    /// Open a meal-soon override at `at`. Supersedes an open one (§5.3).
    func startMealSoon(at: Date, settings: CodableSettings) async throws
    /// Close the open override, if any, as `.cancelled`.
    func cancelMealSoon(at: Date) async
    /// The live override at `at`, or nil. Reads the store, applies §4.1,
    /// writes the end if it observed one, and publishes the answer to
    /// `AppObservableState.mealSoon`.
    func activeMealSoon(at: Date) async -> TargetOverride?
}
```

`LocalTargetGlucoseService` becomes an actor holding `recordStore:
LoopRecordStore?`, `insulinStorage: InsulinStorage` and `observableState:
AppObservableState`, and keeps its two clamp constants.

`targetGlucose(at:settings:)` is `activeMealSoon(at:)` followed by one
branch: nil → the clamped settings target with source `.settings`;
otherwise `MealSoonPolicy.target` of the settings target, clamped, with
source `.mealSoon`.

`activeMealSoon(at:)`:

1. No store, or `openTargetOverride()` throws → publish nil, return nil.
   Both land on the settings target, which is the higher one. Log the
   throw.
2. No open row → publish nil, return nil.
3. `insulinStorage.pumpEvents(from: open.startedAt, to: min(at,
   open.expiresAt))`, keep the `dose`s, run `MealSoonPolicy.status`.
4. `.active` → publish the row, return it.
5. `.ended` → `endTargetOverride(id:at:reason:bolusSyncIdentifier:)`,
   then publish nil, return nil. **That write is log-only.** If it
   fails, the rule still evaluates to ended on the next call from
   `started_at` and the pump events, so the failure is logged and
   nothing else depends on it.

`pumpEvents(from:to:)` returns `[]` on a read failure, which would hide a
manual bolus and let the override run to expiry. Acceptable: the same
failure makes `lastPumpSync` nil, and the loop skips rather than doses.

The service does **no I/O in `init`**, for the same watchdog reason
`LoopRunner.init` does none. `observableState.mealSoon` is hydrated
lazily by the first `activeMealSoon` call, which the views make on
appear (§7.3) and the loop makes on its first tick.

### 4.4 Composition

`LocalTargetGlucoseService` is built at Tier 0 today
(@ios/BioKernel/BioKernel/DependencyInjection/AppComposition.swift:91).
It moves to after `insulinStorage` (line 152), taking `loopRecordStore`
(line 102), `insulinStorage` and `observableState`. Its only consumer is
`LoopRunner` at Tier 6 (line 198), so there is no cycle and no
`LateBound` box. `DosingPipeline` changes only at the one read
(@ios/BioKernel/BioKernel/DataTypes/ClosedLoopDataTypes.swift:317), to
take the struct and pass both fields on.

## 5. The store

### 5.1 Schema v2

A second migration on `GRDBLoopRecordStore`, after `"v1"`
(@ios/BioKernel/BioKernel/Services/GRDBLoopRecordStore.swift:423):

```sql
-- §6: what each tick dosed toward. NULL on rows written before v2.
ALTER TABLE loop_result ADD COLUMN target_mg_dl   DOUBLE;
ALTER TABLE loop_result ADD COLUMN target_source  TEXT;    -- 'settings' | 'mealSoon'

-- The override: live state and log in one table.
CREATE TABLE target_override (
  id                    INTEGER PRIMARY KEY AUTOINCREMENT,
  kind                  TEXT NOT NULL,     -- 'mealSoon'
  started_at            DOUBLE NOT NULL,   -- epoch seconds
  expires_at            DOUBLE NOT NULL,   -- started_at + 60 min; stored so the
                                           -- duration is a fact of the row, not of
                                           -- whichever build reads it
  settings_target_mg_dl DOUBLE NOT NULL,   -- the user's target when it started (§4.1)
  ended_at              DOUBLE,            -- NULL while open
  end_reason            TEXT,              -- 'expired' | 'manualBolus' | 'cancelled';
                                           -- non-NULL iff ended_at is
  end_bolus_sync_id     TEXT               -- non-NULL iff end_reason = 'manualBolus'
);

CREATE INDEX idx_target_override_open
  ON target_override(started_at) WHERE ended_at IS NULL;
```

The open override is "the newest row with a NULL `ended_at`", one hit on
the partial index. There is no separate state file: a row that is open
*is* the state, and a row that is closed is the log entry. `cancelled`
covers both the switch being turned off and supersession by a new start.

### 5.2 Types

```swift
public enum TargetOverrideKind: String, Codable, Sendable { case mealSoon }

public enum TargetOverrideEndReason: String, Codable, Sendable {
    case expired, manualBolus, cancelled
}

/// One `target_override` row, as a domain value.
public struct TargetOverride: Equatable, Sendable {
    let id: Int64
    let kind: TargetOverrideKind
    let startedAt: Date
    let expiresAt: Date
    let settingsTargetMgDl: Double
    let endedAt: Date?
    let endReason: TargetOverrideEndReason?
    let endBolusSyncIdentifier: String?
}
```

Same seam as every other store: the GRDB row type stays private to
`GRDBLoopRecordStore`, and only these cross the protocol.

### 5.3 Reads and writes

Added to `LoopRecordStore`
(@ios/BioKernel/BioKernel/Services/LoopRecordStore.swift):

```swift
/// Insert an open override, first closing any open one as `.cancelled`
/// at the same instant. One transaction, so there is never more than one
/// open row.
func startTargetOverride(kind: TargetOverrideKind, at: Date, expiresAt: Date,
                         settingsTargetMgDl: Double) async throws -> TargetOverride

/// The newest row with a NULL `ended_at`, or nil.
func openTargetOverride() async throws -> TargetOverride?

/// Close a row. A no-op when it is already closed — first writer wins —
/// so the per-tick observer and the switch can race without either
/// overwriting the other's reason.
func endTargetOverride(id: Int64, at: Date, reason: TargetOverrideEndReason,
                       bolusSyncIdentifier: String?) async throws

/// Rows started at or after `since`, oldest first. Diagnostics and tests.
func targetOverrides(since: Date) async throws -> [TargetOverride]
```

### 5.4 Retention and export

`target_override` is pruned by `started_at` in the same sweep that
prunes `loop_result`
(@ios/BioKernel/BioKernel/Services/GRDBLoopRecordStore.swift:547), to
`LoopRecordStorePolicy.retention`. An open row older than 90 days cannot
exist, since expiry is by clock, so the sweep needs no exemption.

`DataExportView` already snapshots this database whole
(@ios/BioKernel/BioKernel/Views/DataExportView.swift:155-156), so the
new table and columns are exported with no change there.

## 6. Per-tick record

`PipelineOutputs` gains `targetSource: TargetGlucoseSource` beside
`targetGlucoseInMgDl`
(@ios/BioKernel/BioKernel/DataTypes/ClosedLoopDataTypes.swift:254).
`ClosedLoopResult` stays `Codable`; decode `targetSource` with
`decodeIfPresent ?? .settings` so any fixture in
`BioKernelTests/Resources` that predates the field still loads.

`LoopRecordSnapshot` gains `targetGlucoseInMgDl: Double?` and
`targetSource: TargetGlucoseSource?`. Optional, because a row written
before v2 has NULL in both, and `toDomain()`
(@ios/BioKernel/BioKernel/Services/GRDBLoopRecordStore.swift:142) must
keep returning those rows or the chart goes blank for a day after the
upgrade. The projection at
@ios/BioKernel/BioKernel/DataTypes/LoopRecord.swift:127 maps both;
`LoopResultRow` (line 39, 79) gains the two columns.

This is the ground truth the override table is checked against. "The
override was active at 12:10" is a claim; "the 12:10 tick dosed toward
75 with source `mealSoon`" is what happened. It also records the plain
settings target on every ordinary tick, which the store has never done.

One reader, the glucose chart (§7.4). It takes `target_mg_dl` through
the same narrow query that already feeds the filtered-glucose line, so
the chart shows the step down and back up without a second series or a
second read.

## 7. UI

### 7.1 Settings automation

A new category in `SettingsHomeView`, in its own `Section` below the
existing one (@ios/BioKernel/BioKernel/Views/SettingsHomeView.swift:16),
so it is visibly separate from therapy settings and the rest:

```swift
Section {
    NavigationLink {
        SettingsAutomationView()
    } label: {
        HStack {
            Label("Settings automation", systemImage: "wand.and.stars")
            Spacer()
            Text(appState.mealSoon != nil ? "Meal soon" : "Off")
                .foregroundStyle(.secondary)
        }
    }
}
```

The trailing value follows the glucose alerts row's pattern (line 42):
the state is readable without opening the screen.

`SettingsAutomationView` is a `Form` with one section, "Meal soon":

- A `Toggle("Meal soon")`. On calls
  `targetGlucoseService.startMealSoon(at: Date(), settings:
  settingsStorage.snapshot())`; off calls `cancelMealSoon(at:)`.
- A footer: "Lowers your target glucose to X mg/dl for 60 minutes, or
  until your next bolus, whichever comes first. Takes effect on the next
  loop, within 5 minutes." X is `MealSoonPolicy.target` of the current
  settings target.
- While active, a row "Ends at HH:mm" from `expiresAt`.

No Save button and no FaceID. The change is bounded: 15 mg/dl, floored
at 75, for at most an hour, under a shutoff that does not move (§8).
The screen is not part of `SettingsViewModel` and touches no
`CodableSettings` field.

The toggle's binding derives from `appState.mealSoon != nil`; its setter
launches the `Task`. A local `@State` mirrored by `onChange` avoids the
switch snapping back for the instant between the tap and the publish.

The screen says "within 5 minutes" because it is true: the loop is
throttled to one run per 4.2 minutes
(@ios/BioKernel/BioKernel/LoopKitSupport/DeviceDataManager.swift:403)
and nothing here forces one. The next CGM reading picks the override up.

### 7.2 The banner

`MainViewMealSoonView`, rendered inside `MainViewAlertView`'s `VStack`
after the existing bolus-progress / alert branch
(@ios/BioKernel/BioKernel/Views/MainViewAlertView.swift:15-22). That
keeps the banner area in one view and puts it exactly where the
requirement says: below the summary, and below any alert that is
showing, never instead of one.

Content: "Meal happening soon, lower target to 75", with "until HH:mm"
beneath. Visually distinct from the yellow glucose alert, which means
something is wrong; this means something is on.

Tapping it opens `SettingsAutomationView`, where the switch is. The
banner is the label of a `NavigationLink`; `MainViewAlertView` already
sits inside `MainView`'s `NavigationStack`
(@ios/BioKernel/BioKernel/Views/MainView.swift:40), so no new
`navigationDestination` or `@State` flag in `MainView` is needed. There
is no cancel on the banner itself: one place to turn it off, and that
place also says what it does.

It shows when `appState.mealSoon` is non-nil **and** `Date() <
expiresAt`. The second test is the view's own, so expiry clears it
without a tick: `MainViewSummaryView`'s 30-second timer already sends
`objectWillChange` (@ios/BioKernel/BioKernel/Views/MainViewSummaryView.swift:95),
which re-renders the tree.

It re-evaluates by calling `activeMealSoon(at: Date())` on appear and on
`onChange(of: doseProgress.isComplete)`. So a bolus from either entry
point drops the banner as soon as the pump reports the dose, rather
than up to five minutes later at the next tick. The loop reads the same
rule from the same rows, so the banner and the dose can't disagree.

### 7.3 Observable state

`AppObservableState` gains `@Published public var mealSoon:
TargetOverride? = nil`
(@ios/BioKernel/BioKernel/Services/AppObservableState.swift:24). Written
only by the service: on start, on cancel, and on every
`activeMealSoon` evaluation. Never read at construction, per §4.3.

### 7.4 The target on the glucose chart

The main glucose chart already draws one series out of the loop record
store: the PID's filtered glucose, in purple
(@ios/BioKernel/BioKernel/Views/GlucoseChartView.swift:56), fed by
`LoopRunner.updateFilteredGlucoseChartData` on every tick
(@ios/BioKernel/BioKernel/Services/ClosedLoopService.swift:132) from
`filteredGlucose(since:)`, a two-column query
(@ios/BioKernel/BioKernel/Services/GRDBLoopRecordStore.swift:671). It is
the only chart in the app with a glucose axis — the Diagnostics sheet's
PID charts are in U/hr and error units — so the target goes here.

The target is drawn **always**, not only during an override. Every tick
that reaches the pipeline records its target and source (§6), so the
series is continuous: a flat line at the settings target on an ordinary
day, with a 60-minute step down in a second color when meal soon is on.
The color is the visual cue that the number came from the override and
not from settings.

Three small changes, no new plumbing:

- `FilteredGlucose` (@ios/BioKernel/BioKernel/Services/ClosedLoopService.swift:15)
  gains `targetMgDl: Double?` and `targetSource: TargetGlucoseSource?`,
  both nil for rows written before v2.
- `filteredGlucose(since:)` selects `target_mg_dl` and `target_source`
  as two more columns. Same predicate, same order, still a narrow read
  on every loop.
- `GlucoseChartView` draws two `LineMark` series from the same array,
  both `.interpolationMethod(.stepEnd)` so a change reads as a step and
  not a ramp, both under the glucose points, nil points skipped:
  1. **Target**, a muted color, over every point with a target. This is
     the continuous line.
  2. **Meal soon**, the override color, over only the points whose
     source is `.mealSoon`, drawn on top of the first. Each contiguous
     run of override ticks gets its own `series(by:)` id, so two
     overrides an hour apart are two segments and not one line joined
     across the gap.

  During an override both lines sit on the same values and the override
  color wins; outside one only the base line shows. The legend carries
  both names. `maxY` is unaffected: the target is at most 140 and the
  smallest scale is 200.

The series updates when the chart does today, one tick after the
override starts, which is also when it first affected a dose.

## 8. Safety interactions

Stated so they are not discovered later.

- **The shutoff does not move.** `Guardrails.shouldShutOff`
  (@ios/BioKernel/BioKernel/DataTypes/ClosedLoopDataTypes.swift:143)
  still zeros the basal when glucose or predicted glucose is at or
  below `shutOffGlucoseInMgDl`. With the default shutoff of 85 and an
  override to 75, delivery stops at 85 regardless of what the PID wants.
  The override's reach is bounded by the shutoff, and that is correct.
- **The micro-bolus gate drops with the target.** It opens at `target +
  20`, so on default settings it moves from 110 to 95. This is the most
  aggressive single effect of the feature. The amount is unchanged: the
  temp basal times the dose factor, clamped as before.
- **PID.** The error steps up by 15 at start and back down at the end.
  The integrator accumulates the larger error for up to an hour; the
  filter and derivative are untouched. No `PIDState` reset, same as a
  temp target in Trio.
- **ML.** The dynamic-ISF scaling grows with `glucose - target`, so a
  given glucose scales a little harder. Still clamped by `Guardrails`
  and still inside the safety budget.
- **The safety budget is unaffected.** Physiological and ML see the same
  target; the budget is about their difference.
- **Alerts.** The low alert level is unchanged (default 70). The PID
  aims at 75, above it.
- **Fail directions.** No store, a store read that throws, or no open row
  → settings target, which is the higher one. An insulin-store read
  failure hides a manual bolus, but also stops the loop (§4.3). A row
  the end-write never reached is still ended by the clock.
- **Supersession.** A second start while one is open closes the first as
  `cancelled` and opens a fresh 60 minutes. The switch cannot produce
  this from the UI, but the store makes it impossible to have two open.

## 9. Things that do not change

- `CodableSettings`, `settings.json`, `SettingsViewModel`, `SettingsView`.
- The pod. No sync, no schedule, no delivery limits.
- `LoopRunner` beyond the one-line mapping into `PipelineOutputs`.
- The safety ledger (`safety_state`).
- The AI interface export, which does not carry the target today.
- The watch app. By decision (§12), not omission: no banner, no switch.
- `MockStoredObject`, since no JSON file is added.

## 10. Tests

**`MealSoonPolicyTests`, pure:**

- `target`: 90 → 75, 80 → 75, 120 → 105, 140 → 125.
- `status`: active at 59:59; ended `.expired` at exactly 60:00; a manual
  bolus at +20m ends it at +20m with that bolus's `syncIdentifier`; an
  automatic bolus does not; a bolus that started before `startedAt` but
  overlaps the window does not; a bolus after `expiresAt` reads as
  `.expired`, not `.manualBolus`; nil `automatic` counts as manual; a
  row with `endedAt` set returns its stored reason; the earliest of two
  manual boluses wins.

**`LoopRecordStoreTests`, in-memory, plus one on-disk migration:**

- Open a v1 database, migrate, read the old rows back: both target
  fields nil, nothing dropped.
- A new row round-trips `target_mg_dl` and `target_source`.
- `startTargetOverride` on a store with an open row closes it as
  `.cancelled` at the same instant, in one transaction.
- `openTargetOverride` returns the newest open row and ignores closed.
- `endTargetOverride` is first-writer-wins.
- Retention prunes by `started_at`.
- The export snapshot contains `target_override`.
- `filteredGlucose(since:)` returns `targetMgDl` and `targetSource` for
  new rows and nil for both on v1 rows.

**`TargetGlucoseServiceTests`, new, with a mock store and mock insulin
storage:**

- Source flips to `.mealSoon` on an open row and back on expiry.
- A failing end-write still returns the settings target.
- No store → settings target, `observableState.mealSoon` nil.

**`ClosedLoopTests`, through `ClosedLoopTestSupport`
(@ios/BioKernel/BioKernelTests/Utils/ClosedLoopTestSupport.swift:15):**

- A stub returning `.mealSoon` → `PipelineOutputs.targetSource ==
  .mealSoon`, PID error shifted by 15, the recorded row carries both
  columns.

**Existing, must stay green:** `LoopFunctionTests`,
`ClosedLoopSafetyTests`, `SafetyServiceTests`,
`LoopOutcomeCodableTests` (see the `decodeIfPresent` note in §6).
`MockTargetGlucose` (@ios/BioKernel/BioKernelTests/Utils/MockClasses.swift:229)
moves to the new protocol and returns `.settings`.

## 11. Suggested order

Each step builds and tests green on its own.

1. Types (§4.3, §5.2) and `MealSoonPolicy` with its tests. No callers.
2. Store: v2 migration, the four methods, `LoopRecordStoreTests`.
3. Plumbing: `PipelineOutputs.targetSource`, `LoopRecordSnapshot`,
   `LoopResultRow`, the `decodeIfPresent`. Pipeline still uses a
   pass-through service; every tick now records `.settings`.
4. The service actor, the composition move, the mock update,
   `TargetGlucoseServiceTests`, the `ClosedLoopTests` case.
5. UI: `AppObservableState.mealSoon`, the settings home row,
   `SettingsAutomationView`, `MainViewMealSoonView`.
6. Chart: the two extra columns in `filteredGlucose(since:)`,
   `FilteredGlucose.targetMgDl` and `targetSource`, the two step lines
   in `GlucoseChartView`. Independent of step 5; could land with step 3.

## 12. Decisions

Confirmed 2026-10-20:

1. **Entry point:** a "Settings automation" category in the settings
   home, its own section, separate from therapy settings. Not a row in
   the therapy form, which is the FaceID-gated Save flow.
2. **No FaceID.** The change is bounded (§8).
3. **State and log** live in a `target_override` table in the loop
   record store, not a JSON file. One source of truth; history kept.

Defaults taken in this doc, to change if wrong:

4. A bolus with nil `automatic` counts as manual (§4.2).
5. The override's target tracks the current settings target per tick;
   `settings_target_mg_dl` is a record, not the value in use (§4.1).
6. Starting does not force a loop; the next tick picks it up (§7.1).
7. Starting while one is open supersedes it (§5.3).
8. A store read failure yields the settings target (§4.3).

Also confirmed 2026-10-20:

9. **Banner tap** opens the Settings automation screen; cancelling
   happens there, not on the banner (§7.2).
10. **The stored target is drawn always** on the main glucose chart, as
    a continuous step line, in a second color while an override is in
    effect (§7.4).
11. **Nothing on the watch.**

## 13. Open questions

None. Everything raised so far is in §12.
