# A GRDB record store for loop results and the safety ledger

Implementation spec for `dev/backlog/migrate-json-to-grdb.md` §4:
`closed_loop_results.json` and `safety_states.json` become one SQLite
database, a `LoopRecordStore`.

Ground truth for code references is `ai-interface` at commit ea14747.

The organizing decision, and the thing that makes this spec different
from the two that came before it: **`closed_loop_results.json` is doing
two jobs, and only one of them survives the migration.** It is the app's
working state — chart data, the micro-bolus throttle, the digestion
gauge — and it is also an audit log of what the algorithm saw and
decided. §2 documents everything the file holds today, field by field.
§4 migrates only the fields the app reads. §9 says what happens to the
rest.

---

## 1. Why

### 1.1 It killed the app

On 2026-08-15 at 22:44 the app was woken in the background, spent its
entire 30-second launch allowance decoding this file on the main thread,
and was killed by the process-launch watchdog. The report is
`BioKernel-2026-08-15-224405.ips` in the repo root:

```
0x8BADF00D  process-launch watchdog transgression:
            exhausted real (wall clock) time allowance of 30.00 seconds
ProcessVisibility: Background
```

The triggered thread is `com.apple.main-thread`, and its stack is
`JSONDecoder.decode` → `Array<A>.init(from:)` → nested keyed containers,
which is the shape of `[ClosedLoopResult]` and nothing else in the app.

The path is not subtle. `AppComposition.init` is `@MainActor`
(@ios/BioKernel/BioKernel/DependencyInjection/AppComposition.swift:14)
and constructs `LoopRunner` eagerly with a `let` at line 174.
`LoopRunner.init` reads the file synchronously
(@ios/BioKernel/BioKernel/Services/ClosedLoopService.swift:86):

```swift
closedLoopResults = (try? storage.read()) ?? []
```

So every launch — foreground, BGTask, and the before-first-unlock
Bluetooth wakes the CGM generates — pays a full decode before any device
manager exists. `dev/backlog/ble-register.md` names this as the thing
that actually closes that issue out; it lists the deferral as a non-goal
of its own change.

### 1.2 What a row costs

§4 of the survey estimated 4–5 KB per row and ~1.3 MB for the file. That
is low, and the reason is worth knowing before designing the schema.

The following is a **model**, not a measurement of a device file: a
representative dosed row built field by field, encoded the way
`StoredJsonObject` encodes it. The two array sizes are exact, because
they are deterministic constants from the pod driver.

| Section | compact | pretty-printed |
|---|---:|---:|
| `supportedBasalRates` + `supportedBolusVolumes` | 6,207 B | 9,811 B |
| `cgmPumpMetadata` (whole) | 6,412 B | 12,452 B |
| `settings` | 907 B | 1,074 B |
| `replay.dataFrame` (24 rows) | 2,377 B | 3,098 B |
| `outputs` (whole pipeline) | 779 B | 971 B |
| **one dosed row** | **10,700 B** | **21,817 B** |

At 288 loops/day:

| Build | row | 24h file | rewrites/day |
|---|---:|---:|---:|
| Release (compact) | 10.7 KB | 2.9 MB | ~830 MB |
| **DEBUG (pretty)** | **21.8 KB** | **6.0 MB** | **~1.7 GB** |

`StoredJsonObject.write` turns on `.prettyPrinted, .sortedKeys` whenever
`debugEnabled`
(@ios/BioKernel/BioKernel/ExtensionsAndUtils/StoredJsonObject.swift:83),
which is any `DEBUG` or simulator build. A 6 MB pretty-printed decode
explains 30 seconds considerably better than 1.3 MB does.

The dominant field is not `replay.dataFrame`, which §4.6 of the survey
singled out. It is `cgmPumpMetadata`, at **58% of every row**, because
`OmniPumpManager.supportedBasalRates` returns `(0...600).map { $0 / 20 }`
and `supportedBolusVolumes` returns 600 more
(@ios/OmnipodKit/OmnipodKit/PumpManager/OmniPumpManager.swift:2225).
That is 1,201 constant doubles, re-serialized 288 times a day, that
nothing ever reads. Even a `.skipped` row — no snapshot, no data frame —
costs ~7.4 KB, essentially all of it that constant table.

### 1.3 Two writes that describe one tick

`safetyService.record` runs inside `runLoop`
(@ios/BioKernel/BioKernel/Services/ClosedLoopService.swift:205).
`storeClosedLoopResult` runs at line 131, after `runLoop` has returned.
Two separate atomic file writes, no transaction between them. Kill the
app in the gap and the safety ledger holds a record the loop log does
not, and the two disagree about what the app did.

The safety ledger is not diagnostic. `LocalSafetyService.tempBasal`
(@ios/BioKernel/BioKernel/Services/SafetyService.swift:76) filters it by
time range to compute `historicalMlInsulin`, which is the machine-learning
insulin budget — the safety property the service exists to enforce.

### 1.4 What it blocks

`dev/backlog/issues.md` §3 asks for a plan to hold something closer to 90
days. In this file the 24-hour cap is not a requirement, it is the
largest number that could be rewritten 288 times a day. In a table it is
a constant and a `DELETE`.

---

## 2. What the file stores today

This section exists to be complete. Every field, whether the app reads it
back, and where.

### 2.1 `closed_loop_results.json`

A `[ClosedLoopResult]` array
(@ios/BioKernel/BioKernel/DataTypes/ClosedLoopDataTypes.swift:387),
`.secondsSince1970` dates, written `.atomic` + `.noFileProtection`,
filtered to 24 hours on every append.

**Top level**

| Field | Contents | Read back? |
|---|---|---|
| `at` | loop tick instant | **yes** — the only field anything filters or orders on |
| `durationInSeconds` | wall time of the run | no |
| `settings` | full `CodableSettings`: 22 fields including two 6-slot learned schedules | no |
| `cgmPumpMetadata` | CGM/pod start + expiry, reservoir %, **`supportedBasalRates`, `supportedBolusVolumes`** | no |
| `outcome` | `.skipped(reason)` / `.dosed(snapshot)` / `.pumpError(attempted:)` | **yes** |

`cgmPumpMetadata` is write-only in the entire app — a `grep` for it
returns only the constructor at DeviceDataManager.swift:181 and the
plumbing that carries it into `ClosedLoopResult`. Nothing reads a stored
one.

**`outcome.snapshot` → `LoopSnapshot.inputs`**

| Field | Read back? | By |
|---|---|---|
| `glucoseInMgDl` | **yes** | chart |
| `insulinOnBoard` | **yes** | chart |

**`outcome.snapshot` → `LoopSnapshot.outputs` (`PipelineOutputs`)**

| Field | Read back? | By |
|---|---|---|
| `predictedGlucoseInMgDl` | no | — |
| `targetGlucoseInMgDl` | no | — |
| `insulinSensitivity` | **yes** | `digestionCalibrated()` |
| `basalRate` | **yes** | `digestionCalibrated()`, chart |
| `machineLearningInsulinLastThreeHours` | **yes** | chart |
| `decision` | **yes** | `lastMicroBolus` (dosing), chart |
| `predictedAddedGlucoseInMgDlPerHour` | **yes** | `digestionCalibrated()` |
| `timings` (3 stage durations) | no | — |
| `candidates` (4 fields) | **yes** | chart, via `insulinPerLoopInterval` |
| `pidTempBasalResult` | **partly** | see below |

**`outputs.pidTempBasalResult` (`PIDTempBasalResult`, 13 fields)**

| Field | Read back? | By |
|---|---|---|
| `at` | **yes** | filtered-glucose chart |
| `filteredGlucose` | **yes** | filtered-glucose chart |
| `Kp`, `Ki`, `Kd` | **yes** | chart, PID contribution arithmetic |
| `error` | **yes** | chart |
| `accumulatedError` | **yes** | chart |
| `derivative` | **yes** | chart |
| `deltaGlucoseError` | **yes** | chart |
| `basalRateInsulinOnBoard` | **yes** | chart |
| `tempBasal` | no | — (the *decision* is read instead) |
| `lastGlucose`, `lastGlucoseAt` | no | — |

**`outcome.snapshot` → `LoopSnapshot.replay` (`LoopReplayInputs`)**

| Field | Read back? |
|---|---|
| `dataFrame` — 24 × `AddedGlucoseDataRow` | no |
| `lastMicroBolus` | no |

`replay` exists, per its own doc comment
(@ios/BioKernel/BioKernel/DataTypes/ClosedLoopDataTypes.swift:238), so
the dosing pipeline can be deterministically replayed against a persisted
result. That is an audit capability, and nothing in the app uses it.

### 2.2 `safety_states.json`

A `[SafetyState]` array
(@ios/BioKernel/BioKernel/Services/SafetyService.swift:25), sorted and
filtered to 24 hours on every append.

| Field | Contents | Read back? |
|---|---|---|
| `at` | tick instant | **yes** — range filter |
| `duration` | correction duration the command was programmed for | **yes** — `deltaUnitsDeliveredByMachineLearning` |
| `kind` | `.tempBasal(programmed:physiological:)` / `.microBolus(programmed:physiological:)` / `.suspended` | **yes** — all of it |

All of it is live. ~288 rows × ~100 B ≈ 29 KB. It is in scope not for its
size but because it is read on the dosing path and because §1.3 is about
it.

### 2.3 The tally

Of 5 top-level `ClosedLoopResult` fields, 2 are read back. Of the ~26
fields inside a snapshot, 18 are read back. By bytes it is far more
lopsided than that: `cgmPumpMetadata` and `replay.dataFrame` alone are
~82% of a row and neither is read.

---

## 3. Approach

One database, two tables, one transaction per loop.

1. **`LoopRecordStore`** — a protocol seam in the shape of
   `GlucoseRecordStore` and `AlertRecordStore`, with
   `GRDBLoopRecordStore` behind it. GRDB never crosses the boundary; row
   structs stay private; dates are epoch-second `DOUBLE`; the database
   lives in its own directory carrying `NSFileProtectionNone`.
2. **A `LoopRecord` domain type** — the persisted projection of a
   `ClosedLoopResult`: exactly the fields §2 marks as read back.
   `ClosedLoopResult` itself stays as the in-memory pipeline result and
   stops being a persisted type.
3. **One `record(...)` call** takes the loop record and the optional
   safety state together and writes both in a single transaction. §1.3
   stops being possible by construction rather than by convention.
4. **The dosing-path reads become queries** — `lastMicroBolus` is
   `ORDER BY at DESC LIMIT 1` over a partial index; the safety ledger is
   a range scan.
5. **`LoopRunner.init` does no I/O at all.** Nothing is loaded at
   construction. That is the fix for §1.1.

### 3.1 Why one database and not two

Splitting them into a `LoopRecordStore` and a `SafetyRecordStore` would
keep the defect in §1.3 and add a file. The whole argument for pairing
them is that the two writes describe the same tick and must land
together. A foreign key from `safety_state` to `loop_result` makes the
pairing checkable rather than merely intended.

---

## 4. Schema

### 4.1 `loop_result`

28 columns, all of them a field §2 marks as read back.

```sql
CREATE TABLE loop_result (
  id                            INTEGER PRIMARY KEY AUTOINCREMENT,
  at                            DOUBLE NOT NULL,  -- epoch seconds; the tick instant
  outcome                       TEXT NOT NULL,    -- 'skipped' | 'dosed' | 'pumpError'
  skip_reason                   TEXT,             -- non-NULL iff outcome = 'skipped'

  -- The decision. NULL for skipped rows, which never reached the pipeline.
  decision_kind                 TEXT,             -- 'tempBasal' | 'microBolus' | 'suspendForBiologicalInvariant'
  decision_temp_basal_u_per_hr  DOUBLE,
  decision_micro_bolus_units    DOUBLE,
  decision_suspend_mg_dl_per_hr DOUBLE,

  -- LoopSnapshotInputs
  glucose_mg_dl                 DOUBLE,
  insulin_on_board              DOUBLE,

  -- PipelineOutputs, the read-back subset
  insulin_sensitivity           DOUBLE,
  basal_rate                    DOUBLE,
  predicted_added_glucose_mg_dl_per_hr DOUBLE,
  ml_insulin_last_three_hours   DOUBLE,

  -- DoseCandidates
  physiological_temp_basal      DOUBLE,
  ml_temp_basal                 DOUBLE,
  physiological_micro_bolus     DOUBLE,
  ml_micro_bolus                DOUBLE,

  -- PIDTempBasalResult, the read-back subset
  pid_at                        DOUBLE,
  pid_kp                        DOUBLE,
  pid_ki                        DOUBLE,
  pid_kd                        DOUBLE,
  pid_filtered_glucose          DOUBLE,
  pid_error                     DOUBLE,
  pid_accumulated_error         DOUBLE,
  pid_derivative                DOUBLE,   -- optional in the domain type
  pid_delta_glucose_error       DOUBLE,   -- optional in the domain type
  pid_basal_rate_iob            DOUBLE    -- optional in the domain type
);

CREATE INDEX idx_loop_result_at ON loop_result(at);

-- The one dosing-path read. A partial index so the scan is over
-- micro-bolus ticks only, not every row.
CREATE INDEX idx_loop_result_micro_bolus ON loop_result(at)
  WHERE outcome = 'dosed' AND decision_kind = 'microBolus';
```

`id AUTOINCREMENT` rather than `at` as the primary key: `at` comes from a
`Date()` at the call site and nothing guarantees it is unique across two
ticks. It also gives `safety_state` something stable to reference and
gives reads a total order when two rows share an instant — the same
reason `glucose_reading` breaks ties on `sync_identifier`.

Storing `Kp`/`Ki`/`Kd`/`error`/`accumulatedError` rather than the three
precomputed PID contributions keeps the display arithmetic in
`DiagnosticViewModel.convertToChartData` where it is today. That
arithmetic is the thing a reader is checking; moving it into the write
path would hide it.

Roughly 28 numeric columns plus overhead is on the order of **250–300 B
per row** — about 2% of today's 10.7 KB. 90 days is ~26,000 rows and
~7 MB, held permanently, against 2.9 MB held for 24 hours today.

### 4.2 `safety_state`

```sql
CREATE TABLE safety_state (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  loop_result_id INTEGER NOT NULL
                 REFERENCES loop_result(id) ON DELETE CASCADE,
  at             DOUBLE NOT NULL,  -- epoch seconds
  duration       DOUBLE NOT NULL,  -- the programmed correction duration
  kind           TEXT NOT NULL,    -- 'tempBasal' | 'microBolus' | 'suspended'
  programmed     DOUBLE,           -- NULL iff kind = 'suspended'
  physiological  DOUBLE            -- NULL iff kind = 'suspended'
);

CREATE INDEX idx_safety_state_at ON safety_state(at);
```

`loop_result_id NOT NULL` is the invariant from §1.3 written into the
schema: a safety state cannot exist without the loop result it belongs
to. `ON DELETE CASCADE` then makes retention a single `DELETE` on
`loop_result`, which is also why both tables share one retention horizon.
Foreign key enforcement must actually be on for that to hold — GRDB
enables it by default, and the store should assert it at open rather than
assume it.

### 4.3 `store_state`

```sql
CREATE TABLE store_state (
  id                            INTEGER PRIMARY KEY,  -- always 0
  created_at                    DOUBLE NOT NULL,
  safety_history_complete_since DOUBLE NOT NULL
);
```

`safety_history_complete_since` is load bearing and §8 is about it. It is
separate from `created_at` so that if a seed is ever added it can move
backwards without lying about when the store was made.

### 4.4 Retention

90 days on `loop_result`, cascading to `safety_state`. Matches
`GlucoseRecordStorePolicy.retention`, `InsulinRecordStorePolicy.retention`,
and `AlertRecordStorePolicy.retention`, so every store answers
retrospective questions over the same span.

No exemptions. Unlike the insulin store's retained suspend/resume markers
or the alert store's unretracted rows, nothing here is state that
outlives its own timestamp: the ledger is only ever read over a 3-hour
window and the chart over 24 hours.

```swift
enum LoopRecordStorePolicy {
    static let retention = 90.0.daysToSeconds()

    /// How much history the diagnostic charts draw. A stated window, so
    /// that when the store holds 90 days the view asks for a day because
    /// that is what it shows — not because that is all there is. Same
    /// reasoning as `DiagnosticViewModel.pumpHistoryWindow`.
    static let chartWindow = 24.0.hoursToSeconds()

    /// The ledger's lookback, moved here from `LocalSafetyService`
    /// because §8's completeness check needs the same number.
    static let safetyTimeHorizon = 3.0.hoursToSeconds()
}
```

---

## 5. Writes

### 5.1 One transaction, and the ordering it forces

```swift
func record(_ record: LoopRecord, safetyState: SafetyState?, at: Date) async throws
```

One `dbQueue.write`: insert the loop result, insert the safety state
against the returned row id if there is one, run retention, commit.

Making that one call means `safetyService.record` can no longer run
inside `runLoop`. The restructure:

- `runLoop` returns the result **and** the safety state it would have
  recorded, and writes nothing.
- `SafetyService.record(at:decision:candidates:duration:)` is removed
  from the protocol. The mapping it performs
  (@ios/BioKernel/BioKernel/Services/SafetyService.swift:110) becomes a
  pure `SafetyState.init(at:decision:candidates:duration:)` on the type
  itself. `LocalSafetyService` keeps `tempBasal` and becomes read-only.
- `loop()` calls `store.record(...)` once with both.

**This moves the AI interface marker, and that is an improvement.**
`aiInterfaceStorage.recordCgmTickHandled` currently runs at
ClosedLoopService.swift:217, which is *between* the two writes. Its
comment at line 212 is explicit that the marker must not be published
before the safety record. Under the new shape it moves out of `runLoop`
and runs after the transaction commits, so it is published only once both
records are durable. Strictly more true than today; the invariant the
comment states is preserved and tightened.

Order in the rewritten `loop()`:

1. `runLoop` — enact pump commands, build the result and the pending
   safety state
2. `store.record(...)` — one transaction
3. `recordCgmTickHandled` — only on a `.dosed` outcome, as today
4. `lastClosedLoopRun`, the chart delegate, the observable state

### 5.2 What is written for each outcome

| Outcome | `loop_result` | `safety_state` |
|---|---|---|
| `.skipped(reason)` | row with `outcome`/`skip_reason`, everything else NULL | none |
| `.pumpError(attempted:)` | full row | **none** — matches today, where `runLoop` returns at lines 193/200 before `safetyService.record` |
| `.dosed(snapshot)` | full row | one row |

### 5.3 The crash window this does not close

Be precise about the claim. The transaction guarantees the loop result
and the safety state agree. It does not guarantee either exists: the pump
commands are enacted at ClosedLoopService.swift:191–202, before the
transaction, so a crash in between still leaves a delivered dose that the
ledger has not counted — an over-generous ML budget for the next three
hours.

Closing that would mean reserving budget before dosing and reconciling
after, which counts insulin that may never be delivered. Out of scope,
noted so it is not mistaken for something this spec fixed.

---

## 6. Reads

### 6.1 `lastMicroBolus` — the dosing path

```sql
SELECT at FROM loop_result
WHERE outcome = 'dosed' AND decision_kind = 'microBolus'
ORDER BY at DESC LIMIT 1
```

Replaces the reverse scan at ClosedLoopService.swift:35. Served by the
partial index in §4.1.

Scope, stated honestly: this feeds `MicroBolusPolicy.pastThrottleWindow`,
whose window is 252 s while loops are ~300 s apart, so the throttle binds
only when two runs land closer together than 4.2 minutes — a pump
heartbeat and a CGM reading arriving near each other. It is a real
dosing-path read and it must not fail silently, but a wrong answer
loosens a throttle rather than changing a dose amount.

### 6.2 The safety ledger — the dosing path

```sql
SELECT * FROM safety_state
WHERE at >= ? AND at < ?
ORDER BY at
```

Bounds `[at - timeHorizon - duration, at)`, exactly the filter at
SafetyService.swift:76. The `zip(events, nextTimes)` tally and
`deltaUnitsDeliveredByMachineLearning` are unchanged — the query returns
domain `SafetyState` values and the arithmetic stays where it is.

### 6.3 The chart reads

Both are currently whole-array operations that would become 26,000-row
operations at 90 days, so both take `chartWindow`:

```swift
func records(since: Date) async throws -> [LoopRecord]
func filteredGlucose(since: Date) async throws -> [FilteredGlucose]
```

`registerClosedLoopChartDataDelegate` currently returns
`[ClosedLoopResult]` and its only caller immediately maps them to
`ClosedLoopChartData`
(@ios/BioKernel/BioKernel/ViewModels/DiagnosticViewModel.swift:82). Since
a stored row no longer reconstructs a `ClosedLoopResult`, it returns
`[LoopRecord]` instead and the delegate becomes
`update(record: LoopRecord)`. `convertToChartData` takes a `LoopRecord`;
the arithmetic in it does not change.

`updateFilteredGlucoseChartData` (ClosedLoopService.swift:92) currently
re-projects the entire array on every loop. It becomes a two-column
windowed `SELECT`, still on every loop, which at 288 rows is not worth
optimizing into an incremental append.

### 6.4 `AppObservableState`

`lastClosedLoopRun` becomes `LoopRecord?`. `digestionCalibrated()`
(@ios/BioKernel/BioKernel/Services/AppObservableState.swift:31) needs
`at`, `insulinSensitivity`, `basalRate`, and
`predictedAddedGlucoseInMgDlPerHour` — all four are columns.

Worth noting while touching it: `latestClosedLoopResult()` returns the
in-memory `lastClosedLoopRun`, which is `nil` until a loop runs in this
process, so the digestion gauge is blank after every relaunch even though
the data is on disk. That is pre-existing, it is now a one-row query away
from being fixed, and fixing it is **not** in this spec. Flagged so the
next person does not have to rediscover it.

### 6.5 The launch path

`LoopRunner.init` reads nothing. No `storage.read()`, no
`closedLoopResults` array, no decode. The filtered-glucose chart
population moves into the existing `Task` guarded by `startBackgroundTask`.

This is the whole of §1.1.

---

## 7. Failure behavior

The other three stores each answer "what happens when there is no store"
differently, and the answer here is different again, because this one has
a read that fails **open**.

`historicalMlInsulin` is subtracted from the ML deviation budget
(SafetyService.swift:95–96). An empty ledger therefore reads as *no ML
insulin has been delivered*, which grants the maximum deviation. Today
`(try? storage.read()) ?? []` produces exactly that on any decode
failure, silently. The header of
`ios/BioKernel/BioKernelTests/SafetyStateCodableTests.swift` already
names this failure mode:

> the silent failure mode where post-restart decoding falls back to `[]`
> and the 3-hour ML budget tally invisibly resets

So the rule for this store:

> **A safety-ledger read that cannot be answered must return the
> reactive-safe temp basal unchanged, never an empty tally.**

```swift
// No store, a failed read, or an incomplete window (§8) all land here.
return SafetyTempBasal(
    tempBasal: reactiveSafeTempBasalUnitsPerHour,
    machineLearningInsulinLastThreeHours: 0
)
```

A zero deviation means `DoseSelector` gets the physiological PID's number
whether or not `useMachineLearningClosedLoop` is set. That is the
conservative branch, and it is already in the code as the divide-by-zero
fallback at SafetyService.swift:100–102 — so this is an existing
behavior being reused, not a new one being invented.

The reported `machineLearningInsulinLastThreeHours: 0` is display-only
and is a lie in the "we don't know" case. It is worth a log line and not
worth a new optional in the return type.

For the other calls:

| Call | On failure |
|---|---|
| `record(...)` | log; the dose already happened and cannot be un-enacted. §5.3 |
| `lastMicroBolus` | log and return `nil` — the throttle opens, per §6.1's scope |
| chart reads | log and return empty; a blank chart is honest |

A store that cannot be opened leaves `LoopRecordStore?` nil in the
composition root, the same shape as the other three factories.

---

## 8. Cutover

Straight cut, no import, matching the alert store's reasoning in the
survey's §6.1: an import path has to be migrated away again later, which
is exactly what `glucose_reading`'s v2 migration exists to undo. Both old
JSON files are left on disk, orphaned.

For `closed_loop_results.json` this is easy — the contents are chart data
and a throttle timestamp, and losing 24 hours of them costs a blank chart
and one possibly-early micro bolus.

For `safety_states.json` it is not, because §7 is the whole point: an
empty ledger reads as full ML budget. A straight cut with no further
thought would hand the ML controller maximum deviation authority for the
three hours after the upgrade.

**`safety_history_complete_since` handles it.** Set to the store's
creation instant on first open. Before tallying, the safety read checks
that the window it needs is covered:

```swift
let start = at - LoopRecordStorePolicy.safetyTimeHorizon
guard start >= safetyHistoryCompleteSince else {
    // The ledger cannot account for part of this window, so it cannot
    // say how much ML insulin is already out. Grant none.
    return fallback
}
```

Self-healing: three hours after the store is created the guard stops
firing and never fires again. Same idea as the insulin store's
`history_complete_since` clamp, and it covers more than the cutover — a
deleted store, a reinstall, a restore from a backup that predates the
database all take the safe branch for their first three hours.

The rejected alternative was seeding `safety_state` from
`safety_states.json` once. It preserves continuity across exactly one
event, costs an import path that must later be deleted, and leaves every
other way of arriving at an empty ledger still failing open.

### 8.1 `DataExportView`

"Share closed loop data" points at the raw JSON file by name
(@ios/BioKernel/BioKernel/Views/DataExportView.swift:152). It becomes a
`VACUUM INTO` snapshot, the same treatment the insulin store already has
at GRDBInsulinRecordStore.swift:1237 — `loop_records.export.sqlite`,
`NSFileProtectionNone` re-asserted on the copy, section hidden when the
store is nil.

---

## 9. The audit log

§2 says 82% of a row's bytes are never read by the app, and §4 does not
migrate them. That is what was asked for, and it is the right call for a
store on the dosing path — but it is a real capability being set down,
and this section says exactly what and how to pick it back up.

**Not persisted after this change:** `durationInSeconds`, the full
`CodableSettings` per tick, all of `cgmPumpMetadata`,
`replay.dataFrame`, `replay.lastMicroBolus`, `outputs.timings`,
`outputs.predictedGlucoseInMgDl`, `outputs.targetGlucoseInMgDl`,
`pid.tempBasal`, `pid.lastGlucose`, `pid.lastGlucoseAt`.

Three things make this recoverable rather than lost:

1. **`ClosedLoopResult` still exists, unchanged.** It stays the in-memory
   pipeline result and keeps its `Codable` conformance; only its trip to
   disk goes away. Anything that wants the full record subscribes to the
   same value `loop()` already has in hand.
2. **A column is an `ALTER TABLE` away.** Promoting an audit-only field
   to a real column later is a v2 migration and a NULL on old rows — the
   pattern `glucose_reading` already demonstrates. Compare with JSON,
   where the schema is whatever the last writer encoded.
3. **The expensive parts should not come back as-is anyway.**
   `supportedBasalRates` and `supportedBolusVolumes` are pump-model
   constants; if they are worth auditing they belong in a `device`
   table with one row per pod, not 288 copies a day. And per-tick
   `settings` is the survey's §8: a `settings_version` foreign key into a
   versioned table, which stores every distinct settings value exactly
   once and answers "what was in effect at time T" as a join. Settings
   change a few times a month. That is the right shape for the audit
   requirement and it is a much smaller change once this store exists.

The honest summary is that this file was not a good audit log: 24-hour
retention, no durability guarantee, no schema, and most of its bytes a
constant. Splitting the roles is what lets each be done properly.

Two candidate follow-ons, neither in scope here:

- **Settings versioning** (survey §8) — now unblocked, and the single
  highest-value piece of the audit payload.
- **A replay sink** — `replay.dataFrame` exists to make the pipeline
  deterministically replayable. If that is worth keeping, it is an
  append-only JSONL file written off the main thread with its own
  retention, not a column in the store the loop reads from.

---

## 10. Testing

**New, store-level** (in-memory `init`, per the pattern):

- `lastMicroBolus` returns the newest `.dosed` micro-bolus tick, and
  ignores `.skipped`, `.pumpError`, and temp-basal decisions
- the safety range query matches the JSON filter at the boundaries —
  `>=` on the left, `<` on the right
- **atomicity**: a forced failure inserting the safety state leaves no
  `loop_result` row either
- **the foreign key holds**: a safety state cannot be inserted without a
  loop result, and deleting a loop result takes its safety state with it
- retention deletes past 90 days and cascades
- `LoopRecord` round-trips every field, including the three optional PID
  fields as NULL

**New, behavioral** — these are the ones that matter:

- an unopenable store makes `SafetyService.tempBasal` return
  `reactiveSafeTempBasalUnitsPerHour` with a zero tally, **not** an empty
  ledger's full budget
- a read failure does the same
- a window reaching before `safety_history_complete_since` does the same,
  and stops doing it once three hours of history exist
- `LoopRunner.init` performs no store reads (pins §1.1 / §6.5)
- the AI marker is written after the transaction commits, and not at all
  when the transaction fails (pins §5.1)

**Existing, must stay green:** `LoopFunctionTests`,
`ClosedLoopSafetyTests`, `ClosedLoopTests`, `SafetyServiceTests`.
`MockStoredObject.read` already returns nil, so these start from an empty
history today and will start from an empty store after.

**Existing, changing meaning:**

- `SafetyStateCodableTests` guards a JSON shape that is no longer
  persisted. Its actual subject — the tally must not silently reset —
  moves to the fail-closed tests above. Delete it when those land, not
  before.
- `LoopOutcomeCodableTests` likewise pins a wire format with no on-disk
  consumer. `ClosedLoopResult` keeps its conformance per §9, so keep the
  test and restate its purpose in the header.

---

## 11. Decisions

1. One database, two tables, one transaction. Splitting the stores would
   preserve §1.3. (§3.1)
2. Only fields the app reads become columns. Everything else in §2 is
   documented and dropped. (§4, §9)
3. `ClosedLoopResult` stops being a persisted type and stays as the
   in-memory pipeline result, so the audit payload is still in hand for a
   future sink. (§9)
4. `LoopRecord` is the persisted projection and what the chart layer
   consumes; `registerClosedLoopChartDataDelegate` returns it.
5. `safety_state` carries a `NOT NULL` foreign key to `loop_result`, so
   the pairing is enforced and retention is one `DELETE`. (§4.2)
6. `SafetyService.record` is removed; state construction becomes a pure
   `SafetyState` initializer and the write moves into the store call.
   (§5.1)
7. The AI interface marker moves after the transaction — later than
   today, which strengthens the invariant its comment already states.
   (§5.1)
8. A safety read that cannot be answered returns the reactive-safe temp
   basal, never an empty tally. (§7)
9. `safety_history_complete_since` gates the ledger, which is both the
   cutover answer and a permanent guard. (§8)
10. Straight cut, no import of either JSON file, for the same reason the
    alert store took one. (§8)
11. 90-day retention on both tables, matching the other three stores.
    Chart reads take an explicit 24-hour window. (§4.4, §6.3)
12. `LoopRunner.init` performs no I/O. (§6.5)
13. PID gains are stored raw rather than as precomputed contributions, so
    the display arithmetic stays in the view layer. (§4.1)

---

## 12. Open questions

1. **Is the modeled row size right?** §1.2 is a construction, not a
   measurement. Pulling the real `closed_loop_results.json` off the
   device would confirm it. Nothing in the design depends on the exact
   number — the schema is driven by which fields are read, not by how big
   the old ones were — but the DEBUG multiplier is the difference between
   "slow" and "watchdog kill", so it is worth confirming.
2. **Does the pretty-printing deserve its own fix regardless?** One line
   in `StoredJsonObject.write` halves every remaining JSON store in
   debug builds, including `ai_export_state.json`, which the survey's §5
   has not started on. Independent of this work and much cheaper.
3. **Should `latestClosedLoopResult()` read the store?** §6.4 — it would
   fix the blank digestion gauge after a relaunch. Deliberately excluded
   here; worth its own small change.
4. **Does anything downstream consume the shared JSON file?** §8.1
   assumes the ShareLink feeds ad-hoc analysis. If a script parses that
   file, it needs to move to the SQLite snapshot, and that is a
   consumer this spec has not surveyed.
