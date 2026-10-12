# Migrating the remaining JSON stores to GRDB

An audit of every remaining `StoredJsonObject` file, and which of them
should follow pump events and glucose into SQLite.

Ground truth for code references is `ai-interface` at commit 687d3d0.

This is a survey, not an implementation plan. Each store that clears the
bar gets its own doc in the style of `insulin-storage-grdb.md` before any
code moves — except §6, which was small enough to do directly.

**Status.** §6 (alerts) is **done**: `GRDBAlertRecordStore`,
`AlertRecordStore`, and a rewritten `LocalAlertStorage` over it, covered by
`AlertRecordStoreTests`. §4, §5, and §8 are not started.

## 1. Where things stand

Two stores have already moved. `GRDBInsulinRecordStore` replaced
`pump_events.v2.json` (`insulin-storage-grdb.md`), and
`GRDBGlucoseRecordStore` replaced `glucose.json` — the latter with no
parallel run at all, because glucose has no dose lifecycle to reconcile
and nothing is inferred between two readings.

`GRDBGlucoseRecordStore` is the reference implementation for anything
that follows. The pattern it establishes:

- a private row struct that never crosses the protocol boundary
  (@ios/BioKernel/BioKernel/Services/GRDBGlucoseRecordStore.swift:30),
- raw-SQL migrations registered on a `DatabaseMigrator`, with schema
  changes added as a new version rather than edited into an old one
  (line 231),
- epoch-second `DOUBLE` dates, never GRDB's default ISO-8601 text, because
  every read is a numeric range comparison (line 18),
- one database per directory, with the directory carrying
  `NSFileProtectionNone` re-asserted on every launch (line 202),
- an in-memory `init` so tests never touch a file system (line 169).

Ten JSON stores remain, all created through
`storedObjectFactory.create(fileName:)`
(@ios/BioKernel/BioKernel/DependencyInjection/AppComposition.swift:79),
plus one on the watch.

## 2. The bar

A JSON blob is the right storage when the whole value is read at once,
written at once, and small. It becomes the wrong storage when any of
three things is true:

1. **It is a log, not a value.** Rows are appended over time and read
   back by time range. The array is only ever a container.
2. **Reads are queries.** Callers filter, sort, or take the last matching
   row. Each of those is a linear scan the format forces.
3. **The retention policy is fighting the format.** A cap exists because
   rewriting the file got expensive, not because the requirement says so.

Volume matters, but it is not the test. `safety_states.json` is 29 KB and
still belongs in the database (§6); `glucose_alerts.json` is a query-free
singleton and does not.

## 3. The inventory

| File | Owner | Shape | Verdict |
|---|---|---|---|
| `closed_loop_results.json` | `LoopRunner` | 24h append-only series | **Migrate — first** |
| `ai_export_state.json` | `LocalAiInterfaceStorage` | 7-day keyed dedup ledger | **Migrate** |
| `alerts.json` | `LocalAlertStorage` | unbounded append + filtered reads | **Migrate** |
| `safety_states.json` | `LocalSafetyService` | 24h append-only series | **Migrate — with §4** |
| `settings.json` | `LocalSettingsStorage` | singleton | Leave (but see §8) |
| `pid_state.json` | `LocalPhysiologicalModels` | singleton, 5 fields | Leave |
| `health_kit_preferences.json` | `LocalHealthKitStorage` | 2 Bools | Leave |
| `glucose_alerts.json` | `PredictiveGlucoseAlertStorage` | singleton settings | Leave |
| `glucose_alert_notification_state.json` | same | 2 fields | Leave |
| `appState.json` | Watch `StateViewModel` | singleton, separate target | Leave |

Out of scope, and worth saying why so the next audit doesn't re-derive it:

- **`PersistedProperty`** (`CGMManagerState`, `PumpManagerState`,
  @ios/BioKernel/BioKernel/LoopKitSupport/DeviceDataManager.swift:231) is
  LoopKit-owned opaque plist state. We do not define its shape and never
  query into it.
- **`LocalMealAnnouncementStorage`** reads AI-written JSONL out of the
  shared app-group container. We are not the writer, and the format is
  the published interface (`dev/ai-interface.md`).

## 4. Closed loop results, and the safety ledger with it

`closed_loop_results.json` is the clearest case in the codebase, and the
one to do first.

### 4.1 The write path

`storeClosedLoopResult`
(@ios/BioKernel/BioKernel/Services/ClosedLoopService.swift:111) rewrites
the entire array on every loop:

```swift
closedLoopResults.append(result)
closedLoopResults = closedLoopResults.filter { $0.at >= (at - 24.hoursToSeconds()) }
try storage.write(closedLoopResults)
```

A dosed `ClosedLoopResult`
(@ios/BioKernel/BioKernel/DataTypes/ClosedLoopDataTypes.swift:387)
carries a full `CodableSettings` copy, `PipelineOutputs` including a
13-field `PIDTempBasalResult`, and `replay.dataFrame` — 24 rows of
`AddedGlucoseDataRow`
(@ios/BioKernel/BioKernel/ExtensionsAndUtils/AddedGlucoseDataFrame.swift:11).

Estimated from field counts rather than measured off a device, that is
roughly 4–5 KB per row, so **~1.2–1.4 MB** at 288 loops/day steady state.
Someone should pull the real file before the implementation doc is
written; the argument does not depend on the exact number, but the
numbers below are only as good as this estimate.

At that size the loop performs ~288 full-file atomic rewrites a day of a
~1.3 MB file — call it **~375 MB/day of writes** — on a device whose
dosing path also runs on before-first-unlock CGM wakes.

### 4.2 The launch path

`LoopRunner.init` line 86 does the read synchronously:

```swift
closedLoopResults = (try? storage.read()) ?? []
```

`AppComposition.init` is `@MainActor` (line 14) and constructs
`LoopRunner` inline (line 174), so that is a ~1.3 MB JSON decode on the
main thread at every launch, background wakes included.

### 4.3 The reads are already SQL

- `lastMicroBolus` (line 35) reverse-scans for the newest `.dosed` result
  whose decision was a micro bolus — `ORDER BY at DESC LIMIT 1` over a
  filtered index. This one feeds dosing, via `LoopInputs.lastMicroBolus`.
- `updateFilteredGlucoseChartData` (line 92) maps every row to two
  columns, on every loop — a projection.
- `registerClosedLoopChartDataDelegate` (line 106) hands the UI the whole
  array; it wants a recent window.

### 4.4 Retention is a format artifact

The 24-hour cap at line 114 exists because the file is rewritten whole.
`dev/backlog/issues.md` §3 explicitly asks for a plan to keep something
closer to 90 days. In a table that is a retention constant and a `DELETE`,
exactly as in `GRDBGlucoseRecordStore.runRetention`
(@ios/BioKernel/BioKernel/Services/GRDBGlucoseRecordStore.swift:336).

### 4.5 Why `safety_states.json` comes along

On volume alone `safety_states.json` would not qualify: ~288 rows of
~100 B is ~29 KB. Two other things put it in scope.

It is read on the dosing path. `LocalSafetyService.tempBasal`
(@ios/BioKernel/BioKernel/Services/SafetyService.swift:76) filters
`$0.at >= (start - duration) && $0.at < at` — a range query — and the
result is the machine-learning insulin budget, which is the safety
property the whole service exists to enforce.

And it is written separately from the loop result that describes the same
tick. `safetyService.record` runs at ClosedLoopService.swift:205, inside
`runLoop`; `storeClosedLoopResult` runs at line 131, after `runLoop`
returns. Two non-atomic file writes. If the app dies in between, the
safety ledger holds a record the loop log does not, and the two disagree
about what happened.

**Both tables belong in one database** — call it a `LoopRecordStore` —
so that pair of writes becomes one transaction. That is the main design
decision this section is arguing for; splitting them into two GRDB stores
would keep the defect and add a file.

### 4.6 A note on the replay payload

`replay.dataFrame`
(@ios/BioKernel/BioKernel/DataTypes/ClosedLoopDataTypes.swift:241) is
roughly half of each row and nothing queries into it. It maps to a `BLOB`
column, the same role `pump_event.raw` and `glucose_reading.device`
already play. Deciding this up front keeps the schema from growing 24
rows of columns it will never filter on.

## 5. The AI export ledger

`AiExportState`
(@ios/BioKernel/BioKernel/Services/AiInterfaceStorage.swift:67) holds two
`[String: Double]` dedup ledgers — one for insulin ids, one for glucose
sync identifiers — with 7-day retention.

At ~338 finalized doses/day (the count observed in
`finalized_insulin_dosing.2026-08-03.jsonl`, per `stateful-issue.md`) plus
~288 glucose readings/day, that is on the order of 4,400 entries, and
`writeStateToDisk` (line 624) re-encodes all of it on **every** export
pass — every CGM reading and every pump sync. `pruneLedger` (line 598)
additionally runs a full linear filter over both dictionaries each pass.

A keyed set with time-based retention is a two-column table with an index
on the timestamp. Migrating also tightens a durability rule the current
shape can only approximate: `appendFinalized` (line 514) marks each record
exported only once its bytes land, but the ledger itself is one bulk file
write afterward, so a crash between the two loses the whole batch's
bookkeeping and republishes those lines on restart. Per-record inserts in
the same transaction make that atomic.

Independent of any of this, and worth fixing either way:
`exportedGlucoseIds` retains 7 days while the caller only ever re-offers
`aiInterfaceCatchUpWindow = 6.hoursToSeconds()`
(@ios/BioKernel/BioKernel/Services/GlucoseStorage.swift:50). Most of that
ledger is dead weight the comment at line 98 already anticipates.

## 6. Alerts — done

`alerts.json` is low volume, so this is not a performance argument. It is
that the file is an unbounded log being used as a queryable table.

Nothing prunes it — the FIXME at
@ios/BioKernel/BioKernel/Services/AlertStorage.swift:61 says so — and it
grows for the life of the install. Every accessor is a `WHERE`:

| Method | Query |
|---|---|
| `doesIssuedAlertExist` (line 86) | `WHERE identifier = ?` |
| `lookupAllUnretracted` (line 92) | `WHERE manager_identifier = ? AND retracted_at IS NULL` |
| `lookupAllUnacknowledgedUnretracted` (line 106) | ...`AND acknowledged_at IS NULL` |
| `activeAlert` (line 129) | ...`ORDER BY issued_at DESC LIMIT 1` |

`retractAlert` (line 72) is the tell: it `map`s the entire array to
rewrite one field on one row, then rewrites the file. That is an `UPDATE`.

This was the cheapest of the four and closed an existing FIXME, so it went
first, as a way to exercise the pattern on something that cannot affect
dosing.

### 6.1 As implemented

Straight cut, no import of `alerts.json`. The only cross-restart consumers
are LoopKit's `PersistedAlertStore` lookups, and nothing in the vendored
pump and CGM kits calls them — so the worst case is one duplicate alert
after the upgrade, against the cost of an import path that then has to be
migrated away again (which is what `glucose_reading`'s v2 exists to undo).
The old file is left on disk, orphaned.

Retention is 90 days, matching the other two stores, and applies **only to
retracted alerts**. An unretracted alert is outstanding state whose age
says nothing about whether it can go — pruning one would silently drop the
alert `lookupAllUnretracted` exists to return. Same exemption in spirit as
the insulin store's retained suspend/resume markers.

One JSON-path behavior was preserved rather than tightened, because a
storage migration is mostly the wrong place to change semantics, and it is
pinned by a test so that changing it is deliberate:

- **`doesIssuedAlertExist` counts retracted rows.** The question LoopKit
  asks through it is "have I issued this before", not "is it live now".

One was fixed rather than preserved, because retention made it load
bearing. **`retract` used to re-stamp `retracted_at` on rows it had
already retracted**, not just live ones. No read could observe the
rewritten value — both lookups filter to `retracted_at IS NULL` — but the
retention sweep compares against exactly that column, so an alert that
fired and was retracted repeatedly kept pushing its oldest records' cutoff
forward and they never aged out. Adding `AND retracted_at IS NULL` to the
`UPDATE` fixes it and makes a retraction with nothing live a complete
no-op, which is what LoopKit's redundant retractions on driver reconnect
should be. An alert is retracted once, at the instant it stopped being
true.

That one is pinned from both directions: a test that fails against the old
`UPDATE` (verified by reverting it), and one that checks a re-issued alert
still retracts normally.

One thing did change, deliberately: the three read methods now report
failure instead of returning an empty success. A caller told "no
outstanding alerts" by a broken store would stop re-issuing them. The three
write methods have no error channel in LoopKit's protocols, so they still
swallow — but they log now, which the JSON path did not.

## 7. What stays JSON, and why

`settings.json`, `pid_state.json`, `health_kit_preferences.json`,
`glucose_alerts.json`, `glucose_alert_notification_state.json`, and the
watch's `appState.json` are all singletons: read once at construction,
rewritten whole on change, never queried. SQLite buys them nothing and
costs them a migration.

`pid_state.json`
(@ios/BioKernel/BioKernel/Services/PhysiologicalModels.swift:86) deserves
its own sentence. It is the PID controller's resume point, and the
staleness check that decides whether to resume or reset the integrator
reads `savedAt` off it. Keeping it a dead-simple file that either parses
or doesn't is a feature, not an oversight. It could ride along in the loop
database for transactional consistency with the result it belongs to;
that is a small win against a real loss in legibility, and the
recommendation is to leave it alone.

The watch's `appState.json`
(@ios/BioKernel/BioKernelWatch Watch App/StateViewModel.swift:15) is in a
different target that does not link GRDB. Not worth changing that for one
singleton.

## 8. The settings-history follow-on

`LocalSettingsStorage`
(@ios/BioKernel/BioKernel/Services/SettingsStorage.swift:24) stores a
one-element array and reads `.first`. On its own it is a singleton and
§7 applies.

It becomes interesting only as a follow-on to §4. Today every
`ClosedLoopResult` embeds a full `CodableSettings` copy, roughly 1.2 KB
of the ~4.5 KB row. If settings moved to a versioned table, the loop
result would carry a `settings_version` foreign key instead — cutting the
largest table by about a quarter, and giving the verification tooling a
real "what settings were in effect at time T" query instead of one that
has to decode loop results to find out.

Sequenced the other way round it is a migration with no consumer. Do §4
first, then decide.

## 9. Suggested order

1. **`closed_loop_results.json` + `safety_states.json`**, as one
   `LoopRecordStore` database (§4). Biggest win, and it unblocks
   `issues.md` §3.
2. **`ai_export_state.json`** (§5). Highest write frequency after the loop
   log, and it makes the export ledger durable per record.
3. ~~**`alerts.json`** (§6). Cheap, off the dosing path, closes a FIXME.~~
   **Done** — see §6.1.
4. **Settings versioning** (§8), only if §4 lands and the row size or the
   verification query turns out to matter.

Items 1 and 2 need their own doc before implementation. The question every
one of them has to answer is the cutover: glucose needed none, insulin
needed a full dual-write and a residual gate
(`insulin-storage-grdb.md` §7). Closed-loop results are diagnostic and
chart data — losing 24 hours of them at cutover is survivable, so a
straight cut is probably right. The safety ledger is *not* diagnostic; it
feeds the dosing path, so it needs an answer of its own even though it is
riding in the same database.
