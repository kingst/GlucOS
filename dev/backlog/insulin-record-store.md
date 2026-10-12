# Insulin record store — stop deleting the evidence

Companion to @dev/backlog/ai-interface-prompt.md, which built the AI
export on top of on-demand derivation over a 24-hour log. This doc
proposes replacing that log with a complete, indexed store of
pump-reported events, and leaving inference exactly where it is: a pure
sweep, computed on demand, never persisted.

Ground truth for the code references below is branch `ai-interface` at
commit 098be75. The bug being fixed is present on public `main` as
well; see §15.

Motivating write-up is @stateful-issue.md. §1 restates only the root
cause.

## 1. Root cause

The phantom needs two ingredients, and only the second is a defect.

1. **Scheduled basal is inferred on every read.** It has to be — the
   OmniPod records no scheduled-basal events, so a stretch with no temp
   basal running can only be inferred. Re-deriving on demand is fine by
   itself.
2. **The input loses the evidence between reads.** `syncDataToDisk`
   (@ios/BioKernel/BioKernel/Services/InsulinStorage.swift:255) trims
   the event log to 24 hours but keeps up to three events from before
   the cutoff via `getMostRecentStatefulOldEvents` (line 223): the most
   recent temp basal, alarm, and suspend/resume. Those are **state
   markers** — they answer "what was the pump doing when our window
   opens". `InsulinTimeline.basalSegments` then reads them back as
   ordinary timeline events and fills the span between each consecutive
   pair with scheduled basal.

So each re-derivation reads a thinner history than the last and tells a
bigger story about the same interval. On a device observed 2026-08-03
that produced one 40.4-hour, 16.164 U phantom basal record — 95% of the
day's published basal — bounded on the left by a `resume` from 40 hours
earlier and on the right by the first surviving temp basal.

Two properties make it structural:

- **The stale marker is stale by design.** OmnipodKit mints
  `.suspend`/`.resume` doses only for explicit suspend/resume commands
  (@ios/OmnipodKit/OmnipodKit/PumpManager/PodCommsSession.swift:932,
  @ios/OmnipodKit/OmnipodKit/PumpManager/PodState.swift:399); a pod
  change does not produce them. On a device that has not suspended
  delivery in three weeks the retained `resume` is three weeks old and
  *should* be — it is the only thing that says the pump is running. The
  defect is that one datum does two jobs: "the pump is running" and
  "the timeline starts here".
- **The segment's identity is stable while its size is not.** Its id is
  anchored to its left edge (`syntheticId`,
  @ios/BioKernel/BioKernel/Services/AiInterfaceStorage.swift:344), which
  never moves, while its right edge advances with the retention cutoff.
  The dedup ledger hides that until `AiExportState.ledgerRetention` (7
  days) prunes the key, after which the same id is appended again at its
  new, larger size — and again every 7 days, growing about 9.6 U per day
  at a 0.4 U/hr scheduled rate. `resetPublishedData` does it
  immediately, which is how the observed row surfaced.

**The lesson, stated as a rule:** every deletion boundary needs a
matching inference clamp. GlucOS has the boundary and no clamp.

### 1.1 What Trio does, and why it does not have this bug

Worth recording, because it is the reason this doc is shorter than its
first draft. nightscout/Trio#1300 ("Finalized Pump Events and Infer
Scheduled Basal In-Memory") adopts LoopKit's dose lifecycle — upsert by
`syncIdentifier`, mutable rows updated in place, finalized reports
freezing the row with actual `deliveredUnits` — and keeps scheduled
basal inference in memory. `ScheduledBasalInference.swift`: *"Pure
timeline sweep computed on demand; nothing is persisted."*

Trio has ingredient 1 without ingredient 2. Its 24 hours is a *fetch*
window over a complete Core Data store, so the events bounding a gap
still exist and re-deriving is idempotent. GlucOS's 24 hours is a
*deletion* boundary. That is the whole difference.

Trio also carries a `coveredUntil` guard that prevents inference from
opening a gap before already-covered time — the clamp this doc's §6
adopts — and never infers across suspension. Their hybrid is worth
copying wholesale: pumps that genuinely report basal-profile-start
events (MinimedKit) get those persisted as real rows tagged
`isScheduledBasal`, because they are pump-reported facts; pumps that do
not (Omnipod, Medtrum, Dana) leave gaps that in-memory inference fills.
GlucOS already has the flag for this distinction
(`pumpRecordsBasalProfileStartEvents`).

Their leftover TODO — "potentially address open-suspend at 24h look-back
boundary" — is this bug in their codebase, still open. Theirs gets
suspension state wrong; ours fabricates insulin, because our events are
deleted rather than merely out of scope.

## 2. The proposal

Three changes. Only the first is essential; the other two are the clamps
that keep it honest.

1. **Stop deleting.** Pump-reported events go into an indexed SQLite
   table and stay there for the retention period. Mutable doses are
   upserted in place by `syncIdentifier` and freeze when the immutable
   report arrives — LoopKit's dose lifecycle, as in Trio#1300.
2. **Separate the state query from the timeline query.** "Is the pump
   suspended", "what is the current alarm", and "what insulin are we
   using" are point-in-time state questions answered by their own
   queries, which may look arbitrarily far back. The timeline array that
   gap-filling zips over contains only events inside the query window.
   A three-week-old `resume` can no longer be mistaken for a delivery
   boundary.
3. **Clamp inference to complete coverage.** Inference refuses to fill
   any gap beginning before `historyCompleteSince` (§4.2). Nothing else
   protects the two boundaries that remain: the migration instant, and
   the retention cutoff once it starts pruning.

Inference itself does not move and is not persisted.
`InsulinTimeline.basalSegments` stays a pure function; it just gets a
complete input and a left-edge clamp.

| | today | proposed |
|---|---|---|
| pump events | 24h JSON log, pruned, 3 markers retained | indexed table, retention only |
| mutable dose resolution | `removeStaleMutableDoses` + prefer-immutable at read | upsert by `syncIdentifier`, freeze on finalize |
| suspension / alarm state | re-inferred from retained events in the timeline | its own query |
| inferred scheduled basal | derived per read, over a lossy log | derived per read, over a complete log, clamped |
| history depth | 24 hours, hard ceiling | retention policy, independent of IOB |
| export dedup | `AiExportState.exportedIds` ledger | unchanged, but now over a stable derivation |

### 2.1 Why not persist the inferred segments

The first draft of this doc proposed committing inferred basal to the
store once, at ingest. That is the wrong line to draw. We never hold
evidence for an inferred segment — the evidence is *absence*. Writing a
conclusion drawn from absence into a store that cannot revise it is
precisely what produced a permanent 16 U record.

Keeping inference in memory also preserves the property a committed
store would destroy: **it is self-healing.** A dose that arrives late,
inside a span we previously inferred, simply changes the answer. No
watermark, no dropped events, no dilemma about mutating a finalized row.
That hazard now exists only in the export (§7), where the append-only
contract forces a decision anyway, and where it is bounded.

## 3. Invariants

> **I1.** The store holds what the pump reported, and nothing derived.
>
> **I2.** A row is mutable until the pump's finalized report replaces
> it; once immutable it never changes.
>
> **I3.** State queries may look back past the window. Timeline queries
> may not.
>
> **I4.** Inference never fills a gap that starts before
> `historyCompleteSince`.

I3 is the root-cause fix. I4 is what makes I1 survive retention.

## 4. Layout

### 4.1 One table

No separate frontier file. Mutable and immutable rows live in the same
table, distinguished by a column — the model Trio#1300 adopted from
LoopKit's `DoseStore`. That removes the two-phase commit an earlier
draft needed, and with it a whole class of crash-window reasoning.

All pump events, not only doses, so alarm state and the diagnostics view
are served from one place:

```sql
CREATE TABLE pump_event (
  sync_identifier        TEXT PRIMARY KEY,  -- pump driver's; synthetic for events without one
  date                   DOUBLE NOT NULL,   -- epoch seconds; the event's own time
  event_type             TEXT NOT NULL,     -- tempBasal | bolus | basal | suspend | resume | alarm | alarmClear | ...
  alarm_type             TEXT,
  dose_start             DOUBLE,            -- NULL for a non-dose event
  dose_end               DOUBLE,
  rate_units_per_hour    DOUBLE,            -- temp basal / basal only
  programmed_units       DOUBLE,
  delivered_units        DOUBLE,            -- NULL until the pump reports it
  insulin_type           TEXT,
  automatic              INTEGER,
  manually_entered       INTEGER,
  is_mutable             INTEGER NOT NULL,
  pump_plugin_identifier TEXT NOT NULL,
  smallest_delivery_unit DOUBLE NOT NULL,
  recorded_at            DOUBLE NOT NULL,   -- when we ingested it
  raw                    BLOB,              -- the driver's opaque payload, for diagnostics
  title                  TEXT
);

CREATE INDEX idx_event_date      ON pump_event(date);
CREATE INDEX idx_event_dose_span ON pump_event(dose_end, dose_start);
CREATE INDEX idx_event_type_date ON pump_event(event_type, date);
```

- `sync_identifier` as the primary key *is* the dedup mechanism. Trio's
  PR notes one sharp edge worth stealing: their old dedup shadowed a
  bolus and a temp basal sharing a timestamp. Keying on the identifier
  rather than on time avoids it.
- Events with no `syncIdentifier` (alarms, `replaceComponent`) get a
  synthetic one derived from date plus type — the same shape
  `HealthKitStorage` already uses for its fallback
  (@ios/BioKernel/BioKernel/Services/HealthKitStorage.swift:92).
- `pump_plugin_identifier`, `insulin_type`, and
  `smallest_delivery_unit` are stored **per row**, not globally. People
  change pods, pumps, and insulins across a history, and the published
  record is the only place that pairing survives.
- Dose range reads must test for **overlap** (`dose_end >= :from AND
  dose_start < :to`), never `dose_start` alone: a temp basal can begin
  before a window and deliver inside it.
- `idx_event_type_date` is what makes the state queries in §6.3 cheap.

### 4.2 Two singletons

A one-row table, in the same database so it shares the transaction and
the protection class — the pattern `SQLitePersistentStorage` already
uses in the ClueClue port for its ingest watermark.

```
history_complete_since : DOUBLE  -- I4's clamp
last_pump_metadata     : TEXT    -- for the launch pass, before any pump has reported
last_reconciliation    : DOUBLE
```

`historyCompleteSince` is `max(migrationInstant, retentionCutoff)`. It
starts at the moment the store is created — before which history is
whatever the old 24-hour log happened to contain, i.e. lossy — and
later tracks the retention cutoff, because pruning at 90 days
re-creates exactly the boundary that caused this bug. This one value is
the general answer to the rule in §1.

`pump_events.v2.json` goes away. So does `logRetentionTimeInterval` as a
limit on what GlucOS can know.

## 5. Ingest

On each `addPumpEvents`:

1. Upsert every incoming event by `sync_identifier` inside one
   transaction. An immutable report overwrites a mutable row and sets
   `is_mutable = 0`. An event arriving mutable when we already hold the
   immutable version is ignored.
2. If `replacePendingEvents` is set, delete mutable rows in the affected
   span that the incoming batch did not assert (§10).
3. Update `last_pump_metadata` and `last_reconciliation` in the same
   transaction.
4. Advance `history_complete_since` to the retention cutoff if
   retention ran.
5. Export (§7).

`removeStaleMutableDoses` and the prefer-immutable half of
`deduplicatedDoses` both disappear: the primary key enforces what they
were reconstructing on every read.

Nothing about inference happens here. That is the point.

## 6. Reads

### 6.1 Inference

`InsulinTimeline.basalSegments` keeps its signature and its logic, with
two changes:

- It takes a `windowStart` and refuses to emit a segment whose left edge
  is before `max(windowStart, historyCompleteSince)` — I4, and Trio's
  `coveredUntil`.
- The `doses` array it receives no longer contains suspend/resume as
  timeline elements. Suspension arrives as a *parameter*: whether the
  pump was suspended at `windowStart`, plus the suspend/resume
  transitions that occur inside the window. A transition inside the
  window is real evidence and behaves exactly as today; a transition
  before it informs the starting state and nothing else.

That second change is I3, and it is the fix. The 40-hour phantom cannot
be constructed, because the three-week-old `resume` is no longer an
element of the array that `zip(basalDoses, basalDoses.dropFirst())`
walks.

### 6.2 IOB and delivered

`insulinOnBoard(at:)` and `insulinDelivered(startDate:endDate:)` fetch
overlapping doses for the window, run §6.1, and sum as they do today.
The window for IOB is DIA-sized rather than "whatever the log holds",
which is a simplification: `insulinDelivered` over an arbitrary range no
longer silently returns a truncated answer for ranges older than a day.

`AddedGlucoseDataFrame.createDataFrame`
(@ios/BioKernel/BioKernel/ExtensionsAndUtils/AddedGlucoseDataFrame.swift:70)
currently calls `insulinOnBoard(at:)` and `insulinDelivered(...)` once
per row, each rebuilding the whole timeline, and cannot see past 24
hours regardless of `numberOfRows`. It should fetch once and derive
once across the frame.

### 6.3 State

Each of these is its own query and may look back past the window:

- suspended at `t` — latest `event_type IN ('suspend','resume')` with
  `date <= t`
- `pumpAlarm()` — latest `event_type IN ('alarm','alarmClear')`
- `currentInsulinType()` — latest non-null `insulin_type`
- `activeBolus(at:)` — bolus rows overlapping `t`

`getMostRecentStatefulOldEvents` existed only to keep these answerable
across the prune. It is deleted.

## 7. Export: the one place a belief is committed

Unlike Trio, which excludes inferred basal from Nightscout upload
entirely, @dev/ai-interface.md promises AI apps a normalized history
with scheduled basal and suspension abstracted away — so GlucOS *must*
turn a belief into an append-only immutable record. This is the only
place that happens, and it stays where it already is.

`buildExport` keeps its finalization gate (`segment.hasSettledBoundaries
&& segment.endDate <= at`,
@ios/BioKernel/BioKernel/Services/AiInterfaceStorage.swift:206) and its
ledger. What changes is the derivation underneath: with a complete store
a segment's right edge stops moving, so a given id stops denoting a
growing quantity, and the 7-day re-append cannot happen. `AiExportState`
could later be replaced by an `exported_at` column, but that is an
optional cleanup, not part of the fix.

Two residual hazards, both bounded and both export-only:

- A late-arriving dose can contradict an already-published inferred
  record. Policy in §10.
- `resetPublishedData` re-derives and re-publishes. That is now safe for
  any span inside `historyCompleteSince`, and by construction unsafe
  outside it — so reset must clamp identically. Worth an explicit test
  (§14).

## 8. Pulse quantization

`BasalSegment.unitsDelivered` integrates `rate × duration` for an
inferred segment (@ios/BioKernel/BioKernel/Services/InsulinTimeline.swift:66-71),
which overstates delivery by roughly 6% versus counting pulses — the
figure in the comment at line 54. Round to the nearest whole multiple of
`smallest_delivery_unit` instead.

This needs no commit point: quantization is a pure function of rate,
duration, and the pulse size, so a stable derivation gives a stable
result on every pass. It could not be done before only because the right
edge kept moving.

## 9. Safety: a failed write

A lost write means a missing dose, IOB reads low, and the loop doses
**more**. The existing mechanism is the right one and is currently
honored: `addPumpEvents` returns an error, `DeviceDataManager+Pump`
passes it to the completion handler
(@ios/BioKernel/BioKernel/LoopKitSupport/DeviceDataManager+Pump.swift:54),
and the driver keys off that — `OmniPumpManager` clears
`state.unstoredDoses` only on success (line 1204-1209) and advances
`lastPumpDataReportDate` only on success (line 3116-3120). So a failed
transaction gets re-delivered rather than lost.

Rules:

- The whole batch is one transaction. Partial application then an error
  return would double-apply on redelivery; upsert-by-identifier makes
  that harmless, but do not rely on it.
- Return the error. Never swallow a write failure to keep the loop
  quiet — redelivery is the safety net and it only works if we report.
- A database that cannot be opened is a dosing outage and must be loud.
  This is stricter than today, where a failed JSON read silently yields
  `eventLog = []` and IOB 0 — a failure mode worth fixing on its own.
- The database file, its directory, and the WAL/SHM sidecars need
  `NSFileProtectionNone`, or a pre-first-unlock CGM BLE wake cannot read
  it. Own the directory rather than chasing per-file attributes; this is
  already why `AiInterfaceContainer.reassertFileProtection` exists.

## 10. Late-arriving events

For the store, this is now a non-issue: nothing derived is persisted, so
a late dose just changes the next derivation. That self-healing is the
main thing §2.1 buys.

`replacePendingEvents` is the driver telling us which mutable doses it
still asserts. `OmniPumpManager.store(doses:)` passes `true` (line
3132), and GlucOS drops it: the parameter is in the delegate signature
at @ios/BioKernel/BioKernel/LoopKitSupport/DeviceDataManager+Pump.swift:46
and never reaches `addPumpEvents`. Adopt LoopKit's `DoseStore`
semantics, as Trio#1300 did — revoke unasserted mutable rows — which
also answers what to do with a mutable dose that never gets an immutable
twin. It gets revoked by the driver rather than lingering until
retention drops it, which is today's silent behavior.

Immutable rows are never revoked.

For the export, the hazard is real but narrow: a dose arriving inside a
span already published as inferred basal. Recommendation: publish the
correction as an ordinary record and log the overlap. The alternative —
suppressing it — hides real insulin, and over-counting is the safer
direction for a reader. Track the frequency; if it is not
approximately never, revisit.

## 11. Migration

Import the existing `pump_events.v2.json` verbatim. Every event in it is
real, including the three retained markers — they are genuine events
with genuine dates, and once they are rows in a complete store they stop
being special.

Set `history_complete_since` to the migration instant. That is what
makes the import safe: the one span that *is* permanently lossy — before
the migration, where the old log's pruning already destroyed the
evidence — is the span inference now refuses to fill. Without the clamp,
the first post-migration export would reproduce the phantom exactly
once and write it down forever.

No history is reconstructed, and none should be: there is no correct
history to reconstruct, only a 24-hour log and 90 days of published
files that may contain phantoms.

## 12. What this deletes

- `getMostRecentStatefulOldEvents` and the retained-marker concept.
- `removeStaleMutableDoses`, and the prefer-immutable pass in
  `deduplicatedDoses`.
- `logRetentionTimeInterval` as a limit on what GlucOS can know, and
  with it the 24-hour ceiling on every historical question.
- `pump_events.v2.json`, and the whole-file read-modify-write on every
  pump sync.
- The 7-day ledger re-append. (`AiExportState` itself can stay; see §7.)
- `insulinDeliveredFromAutomaticTempBasal` has no callers outside
  `MockClasses.swift`. Decide deliberately whether to port it forward.
- The separate ring buffer §14 of the first draft wanted for
  `DiagnosticViewModel`: it reads the table.

## 13. GRDB vs Core Data

**Recommendation: GRDB.**

1. **There is no object graph.** One flat table, an upsert, a few range
   reads, and four state queries. Core Data's central feature —
   managing a mutable object graph with faulting, relationships, and
   merge policies — is what this does not need, and the ceremony is not
   free.
2. **Swift 6 strict concurrency.** GRDB row types are `Codable` structs
   that stay inside the storage actor while domain values cross the
   boundary. `NSManagedObject` is a non-`Sendable` reference type with
   thread confinement, so you map to structs at every actor boundary
   anyway — GRDB's job, done by hand.
3. **Explicit transactions.** `try db.write { ... }` commits or throws,
   which is exactly §9's rule. Core Data's `save()` is a framework
   decision about what SQL runs and when.
4. **The safety-critical queries are reviewable.** `SELECT ... WHERE
   dose_end >= ? AND dose_start < ?` can be checked by someone who does
   not know the codebase. The `NSExpression` plus
   `.dictionaryResultType` equivalent cannot.
5. **Migrations are source.** `DatabaseMigrator` registrations read in a
   diff. A `.xcdatamodeld` bundle does not, and it is one more
   non-source artifact in a target that uses Xcode's
   filesystem-synchronized groups.
6. **File protection is ours to control.** Getting the main file, the
   WAL/SHM sidecars, and SQLite's temp files onto `NSFileProtectionNone`
   is a known footgun; the fix is to own the directory. See §9.
7. **In-memory databases for tests.** `DatabaseQueue()` with no path
   makes the store testable with no file system, matching how
   `buildExport` and the mock storage classes are tested today.
8. **The ClueClue port already runs this pattern** —
   `SQLitePersistentStorage` is a GRDB actor behind a
   domain-model-only protocol seam, with `DatabaseMigrator`,
   own-directory-per-database, and `NSFileProtectionNone`. Matching it
   keeps porting between the codebases mechanical.

**In fairness to Core Data:** Trio#1300 is a working existence proof
that it can do all of this — mutable/immutable rows, `syncIdentifier`
uniqueness constraint plus fetch index, additive lightweight migration
verified against a populated store. The cost is editing a
`.xcdatamodeld`, relying on implicit migration, and living with merge
policies for the uniqueness constraint.

**The real cost of GRDB** is a third-party dependency in the most
safety-critical store in the app. Mitigations: put it behind a protocol
seam so it is swappable and tests never touch it; pin it in
`Package.resolved`; note that the SQL surface here is small enough to
hand-roll on the `sqlite3` C API if it ever became a problem — the
schema and queries are portable, the wrapper is not load-bearing.

**When Core Data would win:** CloudKit sync, or `@FetchRequest` over a
large mutable graph. Neither applies, and syncing insulin history to
iCloud is a privacy decision nobody has asked for.

## 14. Testing

`main` already has the harness: `InsulinPersistentStorageTests` and
`ReplayLogs.immutableReplayLogs()`. The valuable new tests assert about
*time*, which was not previously expressible:

- **The phantom, directly.** Ingest a `resume`, then 24+ hours of temp
  basals, letting retention run. Assert total basal matches
  pump-reported basal and that no segment spans the retention boundary.
  Fails against today's code.
- **Derivation is idempotent.** Derive at T, ingest more events, derive
  again over the same window; the overlap must be byte-identical. This
  is the property the bug violated, and the one worth pinning.
- **The clamp holds at both boundaries** — the migration instant and the
  retention cutoff. Fabricating past either is the regression.
- **State queries see past the window; timeline queries do not.** A
  three-week-old `resume` must make `isSuspended` false and must
  contribute no segment.
- **`replacePendingEvents` revokes only mutable rows**, never immutable
  ones.
- **A failed transaction returns an error and loses nothing**, given
  redelivery.
- **Reset is not a rewrite.** `resetPublishedData` then re-export
  reproduces byte-identical rows for spans inside
  `historyCompleteSince`, and publishes nothing outside it.
- **Parity across the change.** `AiInterfaceParityTests` replays
  recorded logs; extend it to assert old and new paths agree on logs
  with no stale markers — the case where both are correct, so any
  difference is a regression.

## 15. Public / private split and sequencing

The bug is in the **public** repo. On `main`, `inferBasalDoses`
(`InsulinStorage.swift:286-305`) has the identical
`zip(basalDoses, basalDoses.dropFirst())` inference, and
`getMostRecentStatefulOldEvents` (line 189) plus the marker retention
(lines 227-228) are all present. It corrupts public GlucOS's own IOB and
`insulinDelivered` today; the AI export did not create it, it only wrote
the result down where it could be seen. So this lands on `origin/main`
as a correctness fix, motivated without reference to the AI work.

**Sequence: public first, then rebase.** The refactor makes the private
diff *smaller* — `InsulinTimeline` belongs on `main` anyway, being a
pure extraction of `main`'s `inferBasalDoses` and `createBasalDose`.

Four things to handle:

1. **`PumpMetadata` has to move.** It is defined in
   `AiInterfaceDataTypes.swift:150`, private-branch-only, and §4.1 needs
   `pluginIdentifier`, `insulinType`, and `smallestDeliveryUnit`.
   `main`'s `addPumpEvents` takes `insulinType: InsulinType`; the
   private branch already widened it to `pump: PumpMetadata`. Move the
   struct to a neutral `DataTypes` file and land that signature change
   publicly.
2. **GRDB becomes a visible public dependency**, with the SwiftPM and
   `project.pbxproj` changes that implies. The design doc landing
   alongside it is worth the effort on a public medical-adjacent repo.
3. **The rebase.** Twelve commits on `ai-interface` over a rewritten
   `InsulinStorage.swift`, plus `ai-release`; conflicts concentrate in
   `InsulinStorage.swift`, `AppComposition.swift`,
   `DeviceDataManager+Pump.swift`, and `MockClasses.swift`. Doing the
   refactor publicly first means resolving that once instead of
   maintaining a divergence on the most safety-critical file in the app.
4. **This doc needs splitting.** §7 and parts of §1 reference
   @dev/ai-interface.md, which is private. The public version should
   stand on the correctness bug and justify each column on its own
   merits.

Also worth doing: comment on nightscout/Trio#1300 while it is open. Its
open-suspend TODO is the same defect, their instinct ("exclude the
suspend event from the fetch") is §2's separation, and both projects
landing the same shape is worth more than either landing it alone.

## 16. Open questions

1. **Retention on `pump_event`.** 90 days matches the published files
   and is nearly free. Longer unlocks real historical analysis, which is
   arguably the biggest latent win here.
   *Recommendation:* 90 days now; whatever it is, `history_complete_since`
   must track it.
2. **Does HealthKit stay the parallel write?**
   `healthKitStorage.save(pumpEvents:)` currently writes raw events and
   no inferred basal, so the two stores disagree about scheduled basal.
   *Recommendation:* leave it alone in this change; note the divergence.
3. **Should `insulinDelivered` publish inferred basal to callers at
   all, or return reported-only plus a separate inferred figure?** The
   meal banner and TDD want the total; a diagnostic view might want the
   split.
   *Recommendation:* keep one total, add the split only if something
   asks.
4. **Window size for IOB derivation.** DIA plus a margin is right, but
   an inferred segment can legitimately be long — a pod that ran
   unattended for 40 hours — and truncating its left edge to the window
   changes the sum.
   *Recommendation:* fetch the last dose *before* the window as the
   left anchor, subject to I4, and clip the resulting segment to the
   window rather than dropping it.
5. **Does this land before or after the `kind` work ships?**
   *Recommendation:* after — `kind` is small and already on a branch,
   and neither should block the other.
