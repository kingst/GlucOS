# Insulin storage: a GRDB record store for pump events

Replace the 24-hour JSON pump-event log with a complete, indexed SQLite
store, and stop re-deriving scheduled basal over an input that has had
the evidence deleted from it.

Ground truth for code references is `main` at commit 2cf1ed8.

Rolled out as a **dual write** first: the existing code stays
authoritative while the new store is written and read in parallel, with
every difference between the two paths predicted and checked, so the
cutover happens on measured agreement rather than on faith. §7 is that
plan.

The new path is fully featured from the start — `replacePendingEvents`,
pulse quantization, and retention past 24 hours all on. That makes the
two paths differ on purpose, which is fine: the gate is not equality but
a residual (§7.3). Building it this way needs a real verifier up front
and gets everything measured on one parallel run instead of four.

## 1. Why

### 1.1 The defect

`LocalInsulinStorage` keeps a raw `[NewPumpEvent]` log in
`pump_events.v2.json` and derives everything from it on demand. The
OmniPod records no scheduled-basal events, so any stretch with no temp
basal running has to be inferred — `inferBasalDoses`
(@ios/BioKernel/BioKernel/Services/InsulinStorage.swift:286) walks
consecutive pairs of basal-ish doses and fills the span between each
pair at the pump's scheduled rate.

Deriving on demand is fine. The problem is the input. `syncDataToDisk`
(line 221) trims the log to 24 hours (`logRetentionTimeInterval`, line
93) but deliberately keeps up to three events from *before* the cutoff
via `getMostRecentStatefulOldEvents` (line 189): the most recent temp
basal, alarm, and suspend/resume. Those are **state markers** — they
exist to answer "what was the pump doing when our window opens", and
each can be arbitrarily far in the past.

`inferBasalDoses` then reads them as ordinary timeline events. A
retained marker becomes the left edge of an inferred segment whose right
edge is the first surviving event, and the span between them is filled
with scheduled basal. But that span is not a period in which nothing
happened — it is the period whose events we deleted.

Two things make this structural rather than incidental:

- **A retained suspend/resume is stale by design.** It is the only thing
  that says the pump is running, so it is retained however old it is, and
  the defect is that one datum does two jobs: "the pump is running" and
  "the timeline starts here".

  **Correction.** An earlier draft of this section said OmnipodKit mints
  `.suspend`/`.resume` only for explicit suspend/resume commands and that
  a pod change produces neither, citing
  @ios/OmnipodKit/OmnipodKit/PumpManager/PodCommsSession.swift:932. That
  citation refutes the claim: 932 is *inside* `setBasalSchedule`, which
  pod activation reaches via `programInitialBasalSchedule`, so **every
  pod activation mints a resume.** A schedule change on a live pod mints
  a suspend as well, because `OmniPumpManager.setBasalSchedule` cancels
  all delivery first (OmniPumpManager.swift:1759 →
  @ios/OmnipodKit/OmnipodKit/PumpManager/PodState.swift:435-440). A
  device export covering 2026-08-04 → 08-08 confirms it.

  So the retained marker is bounded by how long a pod runs, not by how
  long since the user last suspended: a pod stops at
  `Pod.serviceDuration`, **80 hours**
  (@ios/OmnipodKit/OmnipodKit/OmnipodCommon/Pod.swift:42), so back-to-back
  pods put a resume in the log at least that often — roughly 32 U of
  phantom at 0.4 U/hr rather than the ~500 hours a three-week-old resume
  would imply. The corrected story also **predicts the observation**: what
  was measured below is 40.4 hours, not 500. That is the strongest
  evidence the correction is right, beyond the call path and the export.

  Two qualifications, because "bounded" is easy to over-read. It bounds
  the *resume*-anchored phantom only — `getMostRecentStatefulOldEvents`
  also retains the most recent temp basal, and during a comms outage none
  arrive, so that one is bounded by outage duration and is genuinely
  unbounded. And 80 hours assumes pods are replaced immediately; a pod
  pulled without minting a suspend leaves the resume as the marker and
  fills a no-pod stretch with scheduled basal, which is the most wrong
  this bug ever gets.

  Nothing about the fix, the invariants, or the rollout depends on any of
  this — I3 and I4 hold regardless of how long the fabricated span would
  have been. Only the severity framing changes, and it matters because
  this is the paragraph someone will quote out of context when deciding
  how urgent this is. See dev/backlog/scheduled-basal-history.md §2.1.
- **Each re-derivation reads a thinner history than the last.** The
  right edge of the fabricated segment advances with the retention
  cutoff, so the same span keeps growing. A retained `resume` was
  observed on a live device producing a 40.4-hour inferred segment
  carrying 16.164 U against 0.90 U of actual pump-reported basal over a
  comparable window — the loop was zero-temping almost continuously, so
  the inference was off by roughly 18x.

A retained stale **temp basal** has the same defect. A retained
**suspend** happens to be safe, because `createBasalDose` is only
reached when `curr.type != .suspend` (line 293), so that gap
contributes nothing — right answer, and for the right reason: a
retained suspend with no later resume means the pump really was
suspended across that stretch.

**The rule this violates:** every deletion boundary needs a matching
inference clamp. We have the boundary and no clamp.

### 1.2 What it costs today

Honestly assessed, because the case for this change is mostly about what
it prevents and unblocks rather than about a live emergency:

- **Steady state: latent.** The fabricated span's right edge is the
  first event newer than the cutoff, so it ends roughly 24 hours before
  the derivation that produced it — well past DIA. It contributes
  nothing to `insulinOnBoard(at:)`, so the loop
  (`ClosedLoopService.swift:160`), the summary view
  (`MainViewSummaryView.swift:105`), and the watch
  (`WatchCommsService.swift:37`) are unaffected. `AddedGlucoseDataFrame`
  is called with `numberOfRows: 24`, a two-hour window, so it does not
  reach the span either.
- **After a pump outage longer than the retention window: live, and
  dosing-relevant.** When the pump reports again, trimming runs first
  and prunes everything before the outage except the markers, so the
  gap becomes an inferred segment ending at *now*. That is inside DIA
  and it does reach `insulinOnBoard`. Whether it is correct depends on
  something not in the log: a live pod with a dead phone really does
  keep running its schedule, so the inference may be right; a pod that
  expired or was removed delivered nothing, and the loop then carries
  several units of phantom IOB and under-doses.
- **Any total over a window wider than a day is corrupted.** Nothing on
  `main` sums delivery over such a window today, which is precisely why
  this has gone unnoticed — and why it would surface the moment
  something did.

### 1.3 What it blocks

The 24-hour log is a hard ceiling on every historical question.
`insulinDelivered(startDate:endDate:)` silently returns a truncated
answer for any range older than a day, and
`AddedGlucoseDataFrame.createDataFrame`
(@ios/BioKernel/BioKernel/ExtensionsAndUtils/AddedGlucoseDataFrame.swift:70)
calls `insulinOnBoard(at:)` and `insulinDelivered(...)` once per row,
each rebuilding the whole timeline from the log. Total daily dose,
longer training frames, and any retrospective analysis are all blocked
on storage, not on algorithms.

## 2. Approach

Three changes. Only the second is the root-cause fix; the other two are
what make it hold.

1. **Stop deleting.** Pump-reported events go into an indexed SQLite
   table and stay for the retention period. Mutable doses are upserted
   in place by `syncIdentifier` and freeze when the pump's finalized
   report arrives — LoopKit's dose lifecycle.
2. **Separate the state query from the timeline query.** "Is the pump
   suspended", "what is the current alarm", "what insulin are we using"
   are point-in-time state questions with their own queries, which may
   look arbitrarily far back. The array that gap-filling walks contains
   only events inside the query window. A three-week-old `resume` can
   then inform the starting state without becoming a delivery boundary.
3. **Clamp inference to complete coverage.** Refuse to fill any gap
   beginning before `historyCompleteSince` (§4.2). Two boundaries
   remain after change 1 — the migration instant, and the retention
   cutoff once it starts pruning — and this is what keeps them from
   fabricating.

Inference does not move and is not persisted. It stays a pure sweep over
the query window; it just gets a complete input and a left-edge clamp.

### 2.1 Why inferred basal is not persisted

Tempting, and wrong. We never hold evidence for an inferred segment —
the evidence is *absence*. Writing a conclusion drawn from absence into
a store that cannot revise it is how a 40-hour fabrication becomes
permanent instead of merely repeated.

Keeping inference in memory also preserves the property persisting it
would destroy: it is **self-healing**. A dose that arrives late, inside
a span previously inferred, simply changes the next answer. No
watermark, no dropped events, no dilemma about correcting a committed
row.

This matches nightscout/Trio#1300 ("Finalized Pump Events and Infer
Scheduled Basal In-Memory"), which adopts the same dose lifecycle and
keeps inference in a pure module documented as *"Pure timeline sweep
computed on demand; nothing is persisted."* Their design is worth
following in one more respect: pumps that genuinely report
basal-profile-start events get those persisted as real rows, because
they are pump-reported facts, while pumps that do not leave gaps for
inference to fill. GlucOS already has the flag for that distinction
(`pumpRecordsBasalProfileStartEvents`, line 122).

**That branch is unreachable in GlucOS, and must be labeled as such**
(decision 14). `OmniPumpManager.pumpRecordsBasalProfileStartEvents`
returns hard-coded `false`
(@ios/OmnipodKit/OmnipodKit/PumpManager/OmniPumpManager.swift:2257), and
no MinimedKit is vendored — `ios/RileyLinkKit` is the radio, not a pump
driver. The flag is wired through from LoopKit
(`DeviceDataManager+Pump.swift:153`, `DeviceDataManager.swift:281`) and
costs nothing to keep, but nothing may be tested against it or reasoned
from it: on every device GlucOS runs on, inference is always active. Say
so at the guard sites (`InsulinStorage.swift:318` and its sibling) so a
later reader does not mistake dead code for a supported configuration.

Trio also carries a `coveredUntil` guard preventing inference from
opening a gap before already-covered time, which is change 3, and their
open TODO about suspend state at the 24-hour look-back boundary is this
same defect in their codebase. Theirs gets suspension state wrong;
ours fabricates insulin, because our events are deleted rather than
merely out of scope.

## 3. Invariants

> **I1.** The store holds what the pump reported, and nothing derived.
>
> **I2.** A row is mutable until the pump's finalized report replaces
> it; once immutable it never changes.
>
> **I3.** State queries may look back past the window. Timeline queries
> may not.
>
> **I4.** Inference never fills a gap starting before
> `historyCompleteSince`.
>
> **I5.** History is trustworthy on
> `[historyCompleteSince, lastReconciliation]`. Before the left edge we
> deleted the evidence; after the right edge the pump has not told us
> what it did. Both edges come from outside the derivation and neither is
> optional.
>
> **I6.** Nothing is retained below `historyCompleteSince`. Every row the
> store holds is one that inference may span, so retained history and
> answerable history are the same span.

I5 is the invariant LoopKit encodes structurally and GlucOS currently has
no expression of at all — `lastPumpReconciliation` is stored and
explicitly unused (lines 90-91: *"we don't use this so we can ignore it
for now"*). See §5.2.

I6 is the one added after the fact, and it is the only invariant here
that is about *retention* rather than about derivation. It says the clamp
is never allowed to sit later than the oldest row: a store that holds
data it refuses to reason over has an answerable window narrower than its
file, and nothing in the schema would show it. §4.3 is how it holds. Two
qualifications, both deliberate: the state markers of §6.3 are exempt,
because I3 already keeps them out of the array gap-filling walks, and the
invariant lapses on the unanchored fallback path, where §4.3 chooses a
bounded loss of answerable history over an unbounded file.

## 4. Schema

### 4.1 One table

All pump events, not only doses, so alarm state and the diagnostics view
are served from one place. Mutable and immutable rows share the table,
distinguished by a column.

```sql
CREATE TABLE pump_event (
  sync_identifier        TEXT PRIMARY KEY,  -- driver's; synthetic when absent
  date                   DOUBLE NOT NULL,   -- epoch seconds; the event's own time
  event_type             TEXT NOT NULL,     -- tempBasal | bolus | basal | suspend | resume | alarm | alarmClear | rewind | prime | replaceComponent
  alarm_type             TEXT,
  dose_start             DOUBLE,            -- NULL for a non-dose event
  dose_end               DOUBLE,
  rate_units_per_hour    DOUBLE,
  programmed_units       DOUBLE,
  delivered_units        DOUBLE,            -- NULL until the pump reports it
  insulin_type           TEXT,
  automatic              INTEGER,
  manually_entered       INTEGER,
  is_mutable             INTEGER NOT NULL,
  deleted_at             DOUBLE,            -- soft delete; NULL means live
  smallest_delivery_unit DOUBLE,
  recorded_at            DOUBLE NOT NULL,   -- when we ingested it
  raw                    BLOB,              -- driver's opaque payload, diagnostics only
  title                  TEXT
);

CREATE INDEX idx_event_date      ON pump_event(date)                   WHERE deleted_at IS NULL;
CREATE INDEX idx_event_dose_span ON pump_event(dose_end, dose_start)   WHERE deleted_at IS NULL;
CREATE INDEX idx_event_type_date ON pump_event(event_type, date)       WHERE deleted_at IS NULL;
CREATE INDEX idx_event_mutable   ON pump_event(is_mutable, dose_start) WHERE deleted_at IS NULL;
```

- `sync_identifier` as primary key **is** the dedup mechanism, replacing
  `removeStaleMutableDoses` (line 169) and the prefer-immutable pass in
  `deduplicatedDoses` (line 261). Keying on the identifier rather than
  on time also avoids a bolus and a temp basal at the same timestamp
  shadowing each other — a bug Trio#1300 had to fix in their old
  time-keyed dedup.
- Events with no `syncIdentifier` (alarms, `replaceComponent`) get a
  synthetic one from date plus type, the same shape `HealthKitStorage`
  already uses for its fallback (line 92).
- `insulin_type` and `smallest_delivery_unit` are per row, not global:
  people change pods, pumps, and insulins across a history.
- Dose range reads must test **overlap** (`dose_end >= :from AND
  dose_start < :to`), never `dose_start` alone — a temp basal can begin
  before a window and deliver inside it.
- **`deleted_at` is a soft delete and every read must filter on it.**
  This is not bookkeeping fastidiousness — it is the property
  `InsulinDeliveryStore` relies on (§5.1). A revoked dose has to stay
  legible so the revocation can propagate to consumers and so the phase 1
  verifier can account for it; a `DELETE` makes a row's disappearance
  indistinguishable from its never having existed. Partial indexes keep
  the filter free.
- `idx_event_mutable` is what makes the orphan-revocation query in §5.1
  and the staleness diagnostic in §5.3 cheap.

### 4.2 Singletons

A one-row table in the same database, so it shares the transaction and
the file-protection class:

```
history_complete_since : DOUBLE  -- I5's left edge
last_reconciliation    : DOUBLE  -- I5's right edge, from the driver
```

**`history_complete_since`** is `max(storeCreationInstant,
retentionBoundary, earliestScheduledBasal)`, made monotonic. It starts
when the store is created — before which history is whatever the old
24-hour log happened to hold, i.e. lossy — and thereafter tracks
retention, because pruning at 90 days recreates exactly the boundary that
caused this bug.

The second term is **retention's actual boundary, not the nominal
cutoff**. Under §4.3 those differ, and passing the nominal cutoff here is
the one mistake that silently undoes the anchor: the cutoff is later than
an anchored boundary, so `max` picks it and strands exactly the band the
anchor exists to eliminate, with every row still present and nothing
looking wrong. The third term is scheduled-basal-history §7's, and when
the boundary is anchored the two coincide by construction.

**`last_reconciliation`** is the pump driver's own statement of how far
its reported history is complete, handed to us on every
`addPumpEvents` call and currently thrown away. It is not a diagnostic:
in LoopKit it is the load-bearing boundary between "the pump has told us
what it did" and "we are guessing". §5.2.

The two are independent and both required. `history_complete_since`
answers "how far back can we trust ourselves"; `last_reconciliation`
answers "how far forward has the pump committed". Together they are I5.

### 4.3 Retention cuts at a resume, not at the wall clock

Decision 16, and the reason I6 can be stated at all.

**The defect it fixes.** Pruning at `now − 90d` leaves the store's oldest
*event* earlier than its oldest *rate record*, because the resume that
carried the rate is itself below the cutoff and gets deleted — the
state-marker exemption saves it only while no newer suspend/resume exists
to claim that exemption instead, which on a live device is never for long.
The clamp then has to sit at the first surviving record
(scheduled-basal-history §7), and every dose between the cutoff and that
record is retained and permanently uninferable: real rows whose
intervening gaps no gap-fill may span. The band is up to one inter-resume
interval wide, and because the cutoff rolls forward daily, **the oldest
day of any 90-day answer is always the bad one, and which day that is
keeps moving.** For a store whose entire purpose is answering historical
questions (§1.3), that is a defect in the deliverable, not a rounding
error.

**The fix.** Retention finds the newest resume at or before the cutoff
that carries a rate record, and deletes strictly before *it*. The
deletion boundary, the earliest rate record, and the clamp then land on
one instant by construction, and there is no band. The store deliberately
keeps **more** than 90 days — up to one pod cycle more — so that 90 days
of it are answerable. That trade is the whole point: rows are cheap and a
rolling hole in the answer is not.

Three things this rests on, in descending order of how easy they are to
get wrong:

- **The anchor must carry a rate record, not merely be a resume.** A
  resume with no record answers "the pod was running" and not "at what
  rate", which is the same uninferable band by another route. The query
  joins `scheduled_basal`; scheduled-basal-history §8 already tracks
  resumes that resolve to no record, so this case is known to occur.
- **The clamp must move with the boundary actually used** (§4.2). This is
  the silent one.
- **The look-back is bounded, and the bound is a backstop rather than a
  tuning knob.** Anchoring makes retention a function of driver behavior
  instead of of time alone, and the behavior it depends on —
  every basal-schedule write minting a resume — is one this document's own
  §1.1 got wrong once and had to correct. If it stops holding, an
  unbounded look-back means a store that never prunes again. So:
  `retentionAnchorMaxLookback`, 14 days, far past the 80-hour pod bound on
  purpose. Past it, retention cuts at the nominal cutoff and the store
  degrades to exactly its pre-anchor behavior — correct, with a clamped
  left edge, I6 lapsed. **Losing a pod cycle of answerable history is a
  much better failure than storage exhaustion on a device that doses
  insulin, and it is the failure that does not arrive silently.**

The fallback firing is logged permanently in `LocalInsulinStorage` and
recorded as a `retention_unanchored` observation (§7.3.1). It is expected
never, and it means the mechanism scheduled-basal-history §2 rests on has
stopped firing — a fact about the driver worth having a row for, and not
something the verifier should be the only witness to, since the verifier
is deleted at phase 3 and this concern is permanent.

**What it does not buy.** Two things, because "the whole database is
always valid" is easy to over-read:

- **Genesis still needs the clamp.** A store created mid-life has no
  resume until its first pod change, so the invariant is "always, once the
  first anchor exists", not "always". The clamp becomes quiescent in
  steady state; it does not become removable.
- **A pod pulled without minting a suspend still fabricates.** The anchor
  guarantees no evidence was *deleted* after it. It says nothing about
  whether the pod was physically delivering, which is §1.1's "most wrong
  this bug ever gets" case and is untouched by any of this.

One alternative, rejected: writing a synthetic marker row at the prune
boundary recording the derived state and rate there. It violates I1, and
it is precisely the one-datum-doing-two-jobs shape — a marker asserting
"the pump was running here" that is not itself pump-reported — that this
whole document exists to eliminate. Anchoring on a real event is better
for exactly that reason.

## 5. Ingest

On each `addPumpEvents` (line 135), in one transaction:

1. Upsert every incoming event by `sync_identifier`. An immutable report
   overwrites a mutable row and clears `is_mutable`. An event arriving
   mutable when the immutable version is already held is ignored.
2. **If and only if `replacePendingEvents` is true**, soft-delete every
   live mutable row the batch did not assert (§5.1).
3. Update `last_reconciliation` from the call's `lastReconciliation`.
4. Run retention, then advance `history_complete_since` with the boundary
   it actually used — not with the nominal cutoff (§4.2, §4.3).

Nothing about inference happens here.

Note the order: upsert first, then revoke what remains unasserted. That
is deliberate and differs from LoopKit — see §5.1.

### 5.1 replacePendingEvents

The flag is accepted in the delegate signature
(@ios/BioKernel/BioKernel/LoopKitSupport/DeviceDataManager+Pump.swift:24)
and never forwarded to `addPumpEvents`, so GlucOS drops it today. It is
the subtlest thing in this document; LoopKit is the reference.

**What it means:** *this batch is the driver's complete current set of
pending (mutable) doses.* A full replacement of the mutable frontier, not
a merge. Anything mutable we hold that the batch does not assert is, by
definition, no longer asserted by the driver.

**It is per-call, and both values occur in one driver.**
`OmniPumpManager.store(doses:)` passes `true` (line 3132) because a dose
report *is* a full re-assertion; the pod-change pseudo-event passes
`false` (line 265) because it asserts nothing about pending doses. A
store that treats the purge as always-on deletes every in-flight dose the
moment a pod change fires. `MockPumpManager` passes `true` on both its
paths, so a mock-only test will not catch this.

**LoopKit's mechanics** (@ios/LoopKit/LoopKit/InsulinKit/DoseStore.swift:704):

```swift
if replacePendingEvents {
    try self.purgePumpEventObjects(matching: NSPredicate(format: "mutable == YES"))
}
```

Global, unbounded in time, hard purge, then the whole batch is inserted —
including the mutable rows just deleted. Both inside one
`managedObjectContext.perform` and one `save`. Deliberately **not** scoped
to the batch's span or to any window.

### 5.1.1 Where we deliberately differ, and why

LoopKit has **two** stores, and `replacePendingEvents` only touches the
outer one. Collapsing them into one table means inheriting behavior from
both layers, not just from the one the flag names.

| | LoopKit layer 1 | LoopKit layer 2 | us |
|---|---|---|---|
| entity | `DoseStore` → `PumpEvent` | `InsulinDeliveryStore` → `CachedInsulinDeliveryObject` | `pump_event` |
| role | raw staging | authoritative, feeds IOB | both |
| dedup key | unique constraint on `NewPumpEvent.raw` | `syncIdentifier` + provenance | `sync_identifier` |
| revocation | `replacePendingEvents`, **hard purge** | `resolveMutable`, **soft delete** | soft delete |
| revocation shape | purge all, reinsert batch | mark all deleted, revive by id | upsert, revoke unasserted |

Layer 2's `addDoseEntries(resolveMutable:)`
(@ios/LoopKit/LoopKit/InsulinKit/InsulinDeliveryStore.swift:429) is the
same idea with different mechanics: fetch every live mutable object, set
`deletedAt = now` on all of them, then revive-and-update the one whose
`syncIdentifier` matches each incoming entry. Unmatched ones stay
soft-deleted. `resolveMutable: true` is passed on exactly the
`addPumpEvents` path (line 762), so both layers resolve on every pump
sync.

Three consequences for our single table:

1. **Soft delete, not `DELETE`.** Layer 2's soft delete is load-bearing:
   HealthKit only receives `!isMutable && !isFault` (line 486), and
   `deletedAt` is what lets a revocation propagate rather than silently
   vanish. Layer 1 can afford a hard purge precisely because nothing
   downstream reads it. A single store is read directly, so it needs
   layer 2's semantics. Trio#1300 hard-deletes and compensates in
   `DeviceDataManager` by deleting withdrawn treatments from Nightscout —
   which works, but moves an invariant out of the store and into each
   consumer, and consumers drift.
2. **Revoke the unasserted; do not purge and reinsert.** LoopKit's
   delete-everything-then-insert is an artifact of keying on `raw`, where
   a row has no stable identity to preserve. Keyed on `sync_identifier`,
   deleting and recreating a row that the batch re-asserts churns
   identity and `recorded_at` for no reason. Compute the batch's asserted
   set, upsert it, then revoke live mutable rows outside it. Trio#1300
   does it this way and is right to.
3. **Global scope is correct, and safe for a different reason than
   LoopKit's.** LoopKit's purge spans at most `cacheStartDate`; ours
   spans 90 days of retention. That is fine — a mutable dose older than a
   few hours is an orphan by definition, so revoking it is the point. But
   it does mean one malformed batch could revoke a genuinely in-flight
   dose anywhere in history, which is why §5.3 exists.

### 5.2 lastReconciliation

The concept GlucOS is missing, and more important than the flag above.

In LoopKit it is the seam between the two stores. **Promotion** into the
authoritative store is bounded by it — `guard let endingAt =
lastPumpEventsReconciliation, endingAt > startingAt` (DoseStore line 968)
— so nothing becomes authoritative past the pump's own claim about how
far its history is complete. **Reads** compose the layers across it
(`getNormalizedDoseEntries`, line 1211):

```swift
let filteredStart = max(self.lastPumpEventsReconciliation ?? start, start)
doses = insulinDeliveryDoses.appendedUnion(
    with: try self.getNormalizedPumpEventDoseEntries(start: filteredStart, end: end))
```

The authoritative store supplies history up to `lastReconciliation`, the
raw cache supplies everything after it, and `appendedUnion` walks
`self + otherDoses` keeping the first occurrence of each
`syncIdentifier` (@ios/LoopKit/LoopKit/InsulinKit/InsulinMath.swift:957),
so the authoritative version wins on overlap. Note also that layer 2 is
read with `includeMutable: true`, so Loop's IOB *does* count in-flight
doses — just from the store where they are soft-deletable.

With one table that seam does no work automatically, which means the
bound has to be re-established explicitly rather than inherited:

- Doses after `last_reconciliation` are held, read, and counted toward
  IOB — an in-flight bolus must not be invisible — but they are
  understood as unreconciled and are the rows `replacePendingEvents` may
  revoke.
- Any consumer that needs settled history (totals, retrospective
  analysis, anything published) reads
  `[history_complete_since, last_reconciliation]` and no further. That is
  I5, and it is the single-store expression of what LoopKit's promotion
  bound does for free.

**Caveat (decision 12):** there is no such consumer on `main`
today, so honoring `last_reconciliation` changes no present-day behavior.
It is nearly free and it is correct, but it is preparation, not a fix —
this section should not be read as describing a live defect the way §1.1
does.

### 5.3 Staleness diagnostic

A live mutable row older than roughly twice the longest temp basal
duration is an anomaly, not a dose. It means either the driver stopped
re-asserting it — the orphan case `replacePendingEvents` exists to clear
— or our own finalization is broken. Log it, with the row's age and unit
contribution, and surface a count in the diagnostics view. This is the
cheapest available detector for both failure modes in §5.1.1, and the
phase 1 verifier's `R` term is meaningless without it.

## 6. Reads

### 6.1 Inference

`inferBasalDoses` keeps its shape with three changes:

- It takes a `windowStart` and emits no segment whose left edge precedes
  `max(windowStart, historyCompleteSince)` — I4.
- Suspend and resume stop being elements of the array it walks.
  Suspension arrives as a parameter: whether the pump was suspended at
  `windowStart`, plus the transitions occurring *inside* the window. A
  transition inside the window is evidence and behaves as today; one
  before it informs the starting state and nothing else.
- It **over-fetches** — the query reaches back to the last dose *before*
  `windowStart` rather than a fixed duration, subject to I4, and the
  surplus is discarded after reconciling rather than emitted. A segment
  whose left edge lands outside the window is clipped to it, not dropped.
  LoopKit over-fetches the same way but bounds it at a flat 24 hours
  (`pumpEventReconciliationWindow`, DoseStore line 172), commented "make
  sure we look far back enough to have prior temp basal records to
  reconcile resumption of temp basal after suspend/resume" (line 1126).
  A fixed bound silently truncates the case it exists to handle — a pod
  that ran unattended for 40 hours — so we bound by the data instead.
  (Decision 3.)

The over-fetch is worth dwelling on: it is the *correct* solution to the
problem `getMostRecentStatefulOldEvents` was invented for. Both answer
"what was in flight when the window opens." Retaining three markers past
a prune answers it by keeping a fossil and then mistaking the fossil for
evidence; over-fetching from a complete store answers it with the real
events and throws the surplus away. The clamp then only has to cover the
case where over-fetching cannot help, because the events genuinely are
not there.

The second change is I3 and is the fix. The fabricated segment cannot be
constructed, because the stale marker is no longer an element of the
array that `zip(basalDoses, basalDoses.dropFirst())` walks (line 292).

### 6.1.1 Adopting reconciled()

Decision 10. LoopKit runs `doses.reconciled()`
(@ios/LoopKit/LoopKit/InsulinKit/InsulinMath.swift:396) before anything
else looks at a dose timeline, and it does two things GlucOS does not.

**It trims an overlapping temp basal** to the next one's start —
`endDate = Swift.min(last.endDate, dose.startDate)` — and `trimmed`
rescales the delivered units proportionally, `unitsInDeliverableIncrements
× (newDuration / originalDuration)` (InsulinMath lines 118-126). So it is
a real reduction, not a redistribution. GlucOS today emits both doses at
full duration and counts the overlap twice.

`InsulinTimeline` justifies that on the grounds that "the pump driver
truncates a superseded temp basal's `endDate` when it goes immutable, so
overlaps don't survive deduplication." That is probably true and is
currently taken on faith. Adopting `reconciled()` makes it *measurable*:
the `T` term in §7.3 is exactly the insulin the old path double-counted,
so `T ≈ 0` confirms the assumption and a large `T` refutes it. That is why
adopting this in phase 1 is cheap rather than risky — the change is
expected to be a no-op, and the value is in finding out if it isn't.

**It synthesizes a suspend when a resume never arrives**, covering
`[suspend, nextBasal)`. The unit impact is nil — a suspend dose is 0 U —
but the rule it encodes is one GlucOS lacks: **a temp basal arriving while
we believe the pump is suspended is itself evidence that the pump
resumed.** GlucOS currently reaches the same IOB by skipping the gap after
a suspend (`curr.type != .suspend`, line 293), which is the right number
from a weaker argument. Under §6.1's change 2, where suspension is a
parameter rather than a timeline element, that rule has to be written down
explicitly — so this half of `reconciled()` is not optional dressing, it
is the thing that bounds the suspended interval.

One place not to follow LoopKit: `unitsInDeliverableIncrements`
(@ios/LoopKit/LoopKit/InsulinKit/DoseEntry.swift:147) pulse-rounds with
`round()` against a Minimed-specific constant
(`minimumMinimedIncrementPerUnit`). Decision 2 truncates against the
pump's own `smallestDeliveryUnit`, which is better founded for a pod.
Both only apply when `deliveredUnits` is absent, so reported units still
win in either case — but nobody should "fix" ours to match LoopKit's.

### 6.2 IOB and delivered

`insulinOnBoard(at:)` and `insulinDelivered(startDate:endDate:)` fetch
overlapping live doses for the window, run §6.1, and sum as they do now.
`insulinDelivered` over a wide range stops silently truncating.
`AddedGlucoseDataFrame` should fetch once and derive once across the
frame rather than per row.

Two read-time rules taken from LoopKit:

- **Every read filters `deleted_at IS NULL`.** A revoked dose is not a
  dose. The partial indexes in §4.1 make this free; forgetting it
  resurrects orphans.
- **An unfinished suspend is extended at read time, not stored
  open-ended.** LoopKit maps a suspend whose `startDate == endDate` to
  `endDate = end ?? Date()` (DoseStore lines 1228-1234). Storing an
  open-ended suspension instead would make a row's meaning depend on when
  it is read, which is the mistake this whole document is about.

### 6.3 State

Each is its own query and may look back past the window:

- suspended at `t` — latest `event_type IN ('suspend','resume')` with
  `date <= t`
- `pumpAlarm()` (line 127) — latest `event_type IN ('alarm','alarmClear')`
- `currentInsulinType()` (line 109) — latest non-null `insulin_type`
- `activeBolus(at:)` (line 255) — bolus rows overlapping `t`

`getMostRecentStatefulOldEvents` existed only to keep these answerable
across the prune, and is deleted at cutover.

## 7. Rollout

Three phases. The new path is fully featured throughout; what changes
between phases is which path the app *believes*.

### 7.1 Phase 0 — the store, unwired

Schema, `DatabaseMigrator` migrations, the actor, and unit tests. Nothing
in the app calls it. Validate against `ReplayLogs.immutableReplayLogs()`
offline first: replaying recorded logs is free and catches schema and
upsert mistakes before any device is involved.

### 7.2 Phase 1 — dual write, shadow read, full verifier

`LocalInsulinStorage` takes an optional record store, ingests the same
events into it after `syncDataToDisk()`, and derives IOB and delivered
insulin from both paths on every loop tick. Nothing consumes the new
values.

Everything is on: `replacePendingEvents`, pulse quantization, retention
past 24 hours, the clamp.

**Authority stays with JSON.** Database errors are logged and *not*
returned from `addPumpEvents`. This is the opposite of the final rule
(§8) and is correct only here: a store nothing believes must not be able
to fail the loop.

Write-level checks, after each ingest:

- Every event in `eventLog` has a row, matching on id, mutable state, and
  dose fields, with a millisecond tolerance on dates.
- The comparison is **one-directional and windowed**. The database holds
  strictly more rows, because it does not prune at 24 hours; compare only
  within the span the JSON log still covers. Retention past 24 hours is
  therefore free — it was already outside the comparison.
- Every row revoked by `replacePendingEvents` is soft-deleted, so its
  unit contribution stays queryable — that is what makes the `R` term in
  §7.3 measurable rather than inferred. A revoked
  `sync_identifier` that the driver later re-asserts must come back
  intact; a revoked one that reappears *without* being re-asserted means
  the revocation was wrong, which is the failure mode of §5.1.1 and the
  one thing in phase 1 that could have lost data had JSON not been
  authoritative.
- Revocations must correlate with `replacePendingEvents == true` calls
  only. A revocation on a `false` call is a regression, and the pod-change
  pseudo-event (`OmniPumpManager.swift:265`) is the case that exercises
  it — worth forcing during the run rather than waiting for it.
- `removeStaleMutableDoses` dropping a mutable dose and upsert-by-id
  replacing it must leave the same surviving row.
- The §5.3 staleness count should trend to zero. If it does not, either
  the driver is orphaning doses more often than expected — which is the
  `R` term telling us something real — or finalization is broken.

### 7.3 The verifier

A naive "the two paths match" gate cannot pass, and should not: the paths
differ on purpose, in five places we can each predict exactly. So the
gate is a **residual**. For a window `W` inside the JSON log's coverage:

```
old − new  ==  P + C + R + Q + T
residual   =   (old − new) − (P + C + R + Q + T)   must be < float tolerance
```

| term | what it is | how it is measured | sign | expected |
|---|---|---|---|---|
| **P** | insulin the *old* path fabricated | tag the ids `getMostRecentStatefulOldEvents` returned; sum the contribution of every old-path inferred segment whose left edge is one of them | ≥ 0 | the bug; nonzero |
| **C** | segments the new path's clamp withheld (I4) | the clamp logs what it suppressed | ≥ 0 | ~0 after the first day |
| **R** | mutable rows revoked by `replacePendingEvents` that the JSON log still holds | sum over rows with `deleted_at NOT NULL` in the window; the soft delete is what makes this a query rather than a guess (§4.1) | ≥ 0 | small |
| **Q** | pulse quantization | Σ (raw − truncated) over new-path inferred segments | ≥ 0 | ~6% of inferred |
| **T** | insulin the old path double-counted across overlapping temp basals | for each overlapping pair, the earlier dose's units apportioned over `[next.startDate, previous.endDate)` — what `reconciled()` trims away (§6.1.1) | ≥ 0 | **~0** |

**P is the important one, and it is measured on the old path, not the
new one.** An earlier draft of this doc attributed the whole delta to the
clamp, which is wrong: the new path avoids the fabrication because the
database still holds the real events, so there is no gap to fill — not
because a clamp caught it. With retention at 90 days, C is zero except
in the store's first 24 hours and again past the retention horizon. If
you look for the phantom in C you will conclude, wrongly, that there was
never a bug.

**T is the one whose expected value is the finding.** It should be
approximately zero, because `InsulinTimeline` asserts the driver truncates
superseded temp basals before we ever see them. A materially nonzero `T`
means that assumption is wrong and GlucOS has been double-counting
overlapping basal all along — which would be a second bug, found for free.

Checks that hold regardless of the terms, and stay sharp:

| observation | verdict |
|---|---|
| residual within float tolerance | pass |
| residual nonzero | **regression** — an unexplained difference |
| new > old for basal, anywhere | **regression** |
| bolus totals differ at all | **regression** |
| pump-reported temp basal totals differ at all | **regression** |
| a revoked row reappears without the driver re-asserting it | **regression** (§5.1.1) |
| a revocation on a `replacePendingEvents == false` call | **regression** (§5.1) |

Log all five terms separately on every comparison, not just the residual.
The terms are the interesting output, and three of them answer questions
we would otherwise be guessing at: **P** is how much insulin this bug was
inventing on real devices, **R** is how often the driver actually orphans
a mutable dose (decision 9), and **T** is whether overlapping temp basals
survive deduplication at all (§6.1.1). The residual is the gate; the terms
are the result.

One precondition that is easy to miss: **warm up before comparing.**
Until `historyCompleteSince` predates the comparison window, C
legitimately withholds nearly everything and the log is noise. That is
roughly the store's first 24 hours.

Phase 1 also measures the quantization model itself for free. For
pump-*reported* temp basals we hold both the reported units and `rate ×
duration`, so the parallel run can confirm empirically that truncation to
whole pulses is the right model before it is relied on for inferred
segments. Decision 2.

The run is **one week** (decision 6), which is shorter than the natural
arrival rate of the events it needs to observe — a pod change, a
suspend/resume, and a comms outage. Those have to be forced rather than
waited for; §11.1 says which and how.

### 7.3.1 Where verifier results go

**A second GRDB database, `verifier.sqlite`, in its own directory — not a
table in the store under test.** Three reasons, in order of weight:

1. **I1.** The store holds what the pump reported and nothing derived.
   Verifier output is the most derived data in the app.
2. **Evidence should not live inside the suspect.** The store is what is
   on trial for a week. Recording the verdict in the same file means a
   storage bug can corrupt its own audit trail, and the failure mode is
   silent agreement.
3. **Phase 3 is a deletion.** A separate file is `rm` plus removing one
   actor. A table means writing a migration against the store we have just
   started trusting, for no reason.

Two tables. The first is the residual time series:

```sql
CREATE TABLE comparison (
  at           DOUBLE NOT NULL,   -- when the comparison ran
  metric       TEXT   NOT NULL,   -- 'iob' | 'delivered'
  window_start DOUBLE NOT NULL,
  window_end   DOUBLE NOT NULL,
  old_value    DOUBLE NOT NULL,
  new_value    DOUBLE NOT NULL,
  p DOUBLE NOT NULL, c DOUBLE NOT NULL, r DOUBLE NOT NULL,
  q DOUBLE NOT NULL, t DOUBLE NOT NULL,
  residual     DOUBLE NOT NULL,
  verdict      TEXT   NOT NULL,   -- 'pass' | 'regression:<reason>'
  PRIMARY KEY (at, metric)
);
```

The second is the discrete observations, which are what the write-level
checks in §7.2 and the diagnostic in §5.3 produce:

```sql
CREATE TABLE observation (
  at              DOUBLE NOT NULL,
  kind            TEXT   NOT NULL,  -- revocation | reappearance | stale_mutable
                                    -- | write_mismatch | quantization_sample
                                    -- | retention_unanchored (§4.3)
  sync_identifier TEXT,
  units           DOUBLE,
  detail          TEXT
);
```

`quantization_sample` is where decision 2's empirical check lands: for each
pump-*reported* temp basal, the reported units alongside `rate × duration`
and the truncated value, so the model is confirmed from data rather than
from the argument in §11.

Four rules:

- **`NSFileProtectionNone`, same treatment as the store.** The verifier
  runs on background BLE wakes, including before first unlock — and those
  are exactly when comms outages and odd pump states happen. A protected
  verifier database fails to write precisely when the data is most
  interesting, and fails *silently*, so the week reads clean because the
  evidence is missing rather than because nothing went wrong.
- **A verifier write failure must never reach the loop.** Log and drop.
  This is deliberately the inverse of §8: the store is load-bearing, the
  verifier is not, and a diagnostic that can fail a dose is worse than no
  diagnostic.
- **No retention.** One week at two rows per five-minute tick is about
  4,000 rows. Keep all of it.
- **Export through `ShareLink`.** `DataExportView` already shares
  `closed_loop_results.json` this way; add a row for the database file.
  That is the whole extraction story — no Console.app, no tethering, no
  parsing os_log.

`DiagnosticLog` stays useful for watching in real time, but it is not the
record: os_log is lossy under memory pressure and cannot be aggregated.
"What was the worst residual this week" is a query, and it should be one.

Which makes the cutover gate three queries rather than a judgment:

```sql
SELECT MAX(ABS(residual)) FROM comparison;                       -- must be ~0
SELECT COUNT(*) FROM comparison WHERE verdict != 'pass';         -- must be 0
SELECT COUNT(*) FROM observation WHERE kind = 'reappearance';    -- must be 0 (decision 9)
```

Plus the three findings worth reading rather than gating on:
`SELECT SUM(p)` (how much insulin the bug was inventing), `SELECT SUM(r)`
(how often the driver orphans a dose), and `SELECT SUM(t)` (whether
overlapping temp basals survive deduplication at all, §6.1.1).

### 7.4 Phase 2 — cutover

Reads move to the store. Authority flips: database errors are returned
from `addPumpEvents` so the driver re-delivers (§8). The JSON write and
the verifier stay for one release as a rollback path, behind a settings
toggle so a revert does not need a build.

**As built.** The toggle is `InsulinCutoverSettings.useRecordStoreForDosing`,
persisted in its own `insulin_cutover.json` rather than as a field on
`CodableSettings` — `SettingsViewModel` rebuilds the whole settings object
on every save, so a flag living there would be silently reset by an
unrelated edit, and a rollout switch that reverts itself invisibly is
worse than none. It surfaces in Data export next to the gate readout,
which is the screen the decision is made on, and outside the
`verifierSummary` check so the revert is still reachable on the day the
verifier database is the thing that broke.

**It defaults to off.** The build ships inert and the cutover happens on
the device, so installing the build and believing the store are two
separate events with a gate run in between — the build that first
believes the store should not also be the build whose green stretch
justified believing it.

Two things the flip does *not* do, both deliberate:

- **A failed store read falls back to the JSON log** rather than
  returning zero. The read signatures return `Double` with no error
  channel, and zero is precisely the failure §8 warns about — IOB reads
  low and the loop doses more. While phase 2 still writes the log there
  is a correct answer sitting next to the broken one. This expires with
  the log: phase 3 deletes the fallback and the signatures have to grow
  an error channel.

  **The second half of that turned out to be wrong, and §7.5 records what
  happened instead.** Phase 3 deleted the fallback and the signatures did
  *not* grow an error channel, because they did not need one: a failed
  read makes `lastPumpSync()` report nil, and `ClosedLoopService` already
  refuses to dose on a stale pump reading. The fail-closed path was
  sitting in the loop the whole time; what phase 2 was missing was not a
  `throws` but a reason to trust refusing over guessing.
- **A nil `recordStore` does not fail the batch.** The store failing to
  open leaves it nil, and returning an error there would put the driver
  into an unbounded redelivery loop against a store that will not exist
  until relaunch. Loud in the log, and the JSON path answers. (Still true
  after phase 3, minus the last clause: nothing answers, and the loop
  skips until relaunch.)

### 7.5 Phase 3 — retire ✅ **done, 2026-08-11**

Delete the JSON log, `getMostRecentStatefulOldEvents`,
`removeStaleMutableDoses`, `removeOldEvents` (line 185),
`logRetentionTimeInterval`, and the verifier. Then the things that
needed the store to be authoritative: a single derivation for
`AddedGlucoseDataFrame`, wide-window queries, total daily dose.

**Landed as a deletion only.** Gone: both verifier files and their tests,
`dev/tools/verify_pump_db.py`, the JSON log and everything that trimmed
it, `InsulinCutoverSettings` and the toggle, and the measurement halves
of `InsulinRecordTimeline.Derivation` (`suppressedSegments`, the
`unquantized*` twins, `unreconciledDoses`, and `derive`'s
`overridingScheduledRate`). `readFromDisk` went with the file it read.
The features this enables — a single derivation for
`AddedGlucoseDataFrame`, wide-window queries, total daily dose — were
deliberately **not** done here; they are separate work now that the store
is the only path.

Three things worth knowing about how it landed, because none of them is
what §7.5 or §8 predicted:

- **The read signatures did not grow an error channel.** §7.4 said they
  would have to. They did not, because the fail-closed path already
  existed: `lastPumpSync()` returns nil when the store cannot be read,
  and `ClosedLoopService` gates every tick on it being present and fresh
  *before* consulting IOB, so a store failure skips the tick rather than
  dosing off a zero. The `-> Double` reads still answer 0 on failure and
  that is still the dangerous value — what makes it safe is that the loop
  never reaches it. `InsulinStorageTests.aFailedStoreReadReportsNoPumpSyncSoTheLoopSkips`
  is the test that holds this together; if it ever passes while
  `lastPumpSync` returns a date, the loop will dose off a zero.
- **`InsulinTimeline` and `InsulinTimeline.basalSegments` survive**, and
  the AI interface exporter still uses them with a scalar
  `scheduledBasalRateUnitsPerHour`. Repointing `buildExport` at
  `InsulinRecordTimeline` would move every published segment id — they
  are anchored to a segment's start instant, `reconciled()` and rate
  subdivision both move those instants, and the export ledger keys on the
  id — so the switch would republish the same spans under new ids and a
  reader would sum both. The exporter is fed from the store now
  (`records(from:to:)` over a 24-hour window, the span the JSON log
  happened to retain) rather than from the log, which is what kills the
  16.164 U phantom: the fabrication needed the retained fossil `resume`
  that `getMostRecentStatefulOldEvents` kept, and that is what was
  deleted. The exporter's own present-tense-rate defect (`S`) is
  untouched and is its own change.
- **`AiInterfaceParityTests` was rewritten rather than deleted.** It
  compared the published export against the JSON read path; both sides
  are now built from the same dose set inside the test, which is what it
  was always actually asserting.

## 8. Safety

A lost write means a missing dose, IOB reads low, and the loop doses
**more**. The mechanism for this already exists and is honored:
`addPumpEvents` returns an error, `DeviceDataManager+Pump` passes it to
the completion handler (line 44), and the driver keys off that —
`OmniPumpManager` clears `state.unstoredDoses` only on success (line
1204-1209) and advances `lastPumpDataReportDate` only on success (line
3116-3120). A failed transaction is re-delivered rather than lost.

- One transaction per batch. Partial application followed by an error
  would double-apply on redelivery; upsert makes that harmless, but do
  not rely on it.
- Return the error, from **phase 2** onward — specifically, whenever the
  cutover toggle is on. Never swallow a write failure to keep the loop
  quiet; redelivery only works if we report. (This bullet said "phase 3"
  and contradicted §7.4, which flips authority at cutover and cites this
  section. §7.4 is the intent: a rollback toggle is meaningless if the
  store is not authoritative enough to fail a batch. Corrected when
  phase 2 was implemented.)
- A database that cannot be opened is a dosing outage and must be loud.
  Stricter than today, where a failed JSON read silently yields
  `eventLog = []` and an IOB of 0 — worth fixing regardless of this
  work.
- The database file, its directory, and the WAL/SHM sidecars need
  `NSFileProtectionNone`, or a pre-first-unlock CGM BLE wake cannot read
  it. Own the directory rather than chasing per-file attributes.

## 9. Why GRDB

1. **There is no object graph.** One flat table, an upsert, a few range
   reads, four state queries. Core Data's central feature — managing a
   mutable object graph with faulting, relationships, and merge policies
   — is what this does not need.
2. **Swift 6 strict concurrency.** GRDB row types are `Codable` structs
   that stay inside the storage actor. `NSManagedObject` is a
   non-`Sendable` reference type with thread confinement, so you map to
   structs at every actor boundary anyway.
3. **Explicit transactions.** `try db.write { ... }` commits or throws,
   which is §8's rule directly.
4. **The safety-critical queries are reviewable** by someone who does
   not know the codebase. The `NSExpression` plus `.dictionaryResultType`
   equivalent is not.
5. **Migrations are source.** `DatabaseMigrator` registrations read in a
   diff; a `.xcdatamodeld` bundle does not, and it is one more
   non-source artifact in a target using filesystem-synchronized groups.
6. **File protection is ours to control** — see §8.
7. **In-memory `DatabaseQueue()` for tests**, so the store is testable
   with no file system, matching how the existing mocks work.

**In fairness to Core Data:** Trio#1300 is a working existence proof
that it does all of this — mutable/immutable rows, a `syncIdentifier`
uniqueness constraint plus fetch index, additive lightweight migration
verified against a populated store. The cost is editing a
`.xcdatamodeld`, relying on implicit migration, and living with merge
policies for the constraint.

**The real cost of GRDB** is a third-party dependency in the most
safety-critical store in the app. Mitigations: a protocol seam so it is
swappable and tests never touch it; a pinned `Package.resolved`; and the
observation that the SQL surface here is small enough to hand-roll on
the `sqlite3` C API if it ever became a problem.

## 10. Testing

`InsulinPersistentStorageTests` and `ReplayLogs.immutableReplayLogs()`
already provide the harness. The valuable new tests assert about *time*,
which the current design cannot express:

- **The fabrication, directly.** Ingest a `resume`, then 24+ hours of
  temp basals, letting retention run. Total basal must match
  pump-reported basal, and no segment may span the retention boundary.
  Fails against today's code.
- **Derivation is idempotent.** Derive at T, ingest more, derive again
  over the same window; the overlap must be identical. This is the
  property the bug violates.
- **The clamp holds at both boundaries** — store creation and the
  retention cutoff.
- **Retention anchors on a resume** (§4.3). The boundary lands on the
  newest resume at or before the cutoff that carries a rate record; rows
  between it and the cutoff survive; the clamp lands on the anchor rather
  than on the cutoff. The last of those three is the assertion that
  matters — landing on the cutoff leaves every row present and three days
  of them silently uninferable.
- **A resume with no rate record cannot anchor.** It answers the state
  question and not the rate question, so treating it as a left edge
  re-opens the band it was supposed to close.
- **The look-back bound refuses rather than grows.** An anchor older than
  `retentionAnchorMaxLookback` is not used, retention cuts at the nominal
  cutoff, and the rows below it really are deleted — not retained forever
  waiting for an anchor that is not coming.
- **I6 as a property, not an example.** After an anchored prune, no dose
  row is older than the clamp. State markers are excluded, for the same
  reason I3 makes them safe.
- **The band's insulin is actually there.** Build the configuration where
  a wall-clock cut loses it — an anchor resume below the cutoff, a newer
  suspend/resume above it to claim the state-marker exemption, and doses
  with a gap between them in between — and assert the gap is filled at the
  anchor's rate. Row counts do not show this; units do.
- **State queries see past the window; timeline queries do not.** A
  three-week-old `resume` must make `isSuspended` false and contribute
  no segment.
- **A retained suspend still yields zero units**, preserving today's
  correct behavior for that case.
- **A failed transaction returns an error and loses nothing**, given
  redelivery.
- **`replacePendingEvents` is honored per call.** A `false` call revokes
  nothing, even when live mutable rows are unasserted — the pod-change
  pseudo-event is the real case. A `true` call revokes only live mutable
  rows the batch did not assert, never immutable ones, and a revoked id
  the driver re-asserts comes back intact.
- **Revocation is a soft delete.** The row survives with `deleted_at`
  set, no read returns it, and its units remain summable for the `R`
  term.
- **`lastReconciliation` bounds settled reads.** A dose after it counts
  toward IOB but is excluded from any settled-history query — I5.
- **Over-fetching does not leak.** Doses fetched from before
  `windowStart` for reconciliation must inform the segments inside the
  window and never appear as segments themselves.
- **`reconciled()` trims and rescales.** Two overlapping temp basals must
  yield the earlier one truncated to the later one's start with its
  delivered units scaled by the duration ratio — not truncated with units
  intact, which would redistribute rather than reduce. Assert the total,
  not just the boundary.
- **A suspend with no resume is closed by the next temp basal**, at rate
  0, and the temp basal itself is treated as evidence of resumption
  (§6.1.1). Assert both the zero units and that scheduled basal resumes
  after the temp basal rather than before it.
- **The §7.3 residual is zero** on recorded logs, with each of P, C, R, Q,
  and T non-zero in at least one test — a residual of zero because every
  term is zero proves nothing. `T` needs a hand-built overlapping pair,
  since recorded logs may well contain none, which is the point of
  §6.1.1.

## 11. Decisions

Settled. Recorded here because several of them are load-bearing for the
verifier, and a later reader should not have to re-derive why.

1. **Retention is 90 days**, on from phase 1, and is a floor rather than a
   ceiling — the boundary is a resume at or before the cutoff, so the
   store holds up to one pod cycle more (decision 16). It falls outside
   the comparison window, so it costs the verifier nothing.
   `history_complete_since` tracks the boundary (§4.2).
2. **Quantization truncates**, on from phase 1 — a pump cannot deliver a
   partial pulse, so truncation over the whole segment is the physical
   model, not rounding to nearest. It also keeps the `Q` term
   single-signed. §7.3's empirical check against reported temp basals
   confirms the model before cutover; if reported units turn out not to
   match truncation, that is a finding about the pump and this decision
   reopens.
3. **The over-fetch is bounded by the last dose before the window**, not
   by a fixed duration, subject to I4, with out-of-window segments clipped
   rather than dropped (§6.1).
4. **HealthKit is left alone** in this change. The divergence stands: it
   holds raw events and no inferred basal. Decision 13 spins the
   improvements out into @dev/backlog/healthkit-improvements.md rather than
   entrenching today's behavior.
5. **`insulinDelivered` returns one total.** Add a reported/inferred split
   only when something asks for it.
6. **Phase 1 runs for one week**, then cutover.
7. **The verifier is behind a compile-time flag**, one injected object
   that owns the old-path tagging, so phase 3 is a deletion rather than an
   untangling. Its results go in a second database, not the store under
   test (§7.3.1).
8. **Nothing besides the verifier consumes revocations today.** `deleted_at`
   still earns its place (§5.1.1); log revocations of doses already written
   to HealthKit so the size of the problem is known.

### 11.1 What decision 6 changes

A week is shorter than the natural arrival rate of two of the three events
phase 1 needs to see, so they have to be **forced rather than waited
for**:

- **Pod changes arrive on their own** — roughly two in a week.
- **Suspend/resume will not.** It requires deliberately suspending
  delivery, and it is the event that exercises the stale-marker path that
  caused this bug. Do it at least twice, once with a resume and once
  leaving the pump suspended across a sync.
- **A comms outage will not reliably.** Walk out of range, or turn
  Bluetooth off, long enough to exceed the retention window — that is the
  only way to exercise the one case §1.2 identifies as currently
  dosing-relevant.
- **A `replacePendingEvents == false` call** needs a pod change to fire
  (`OmniPumpManager.swift:265`), so it comes with the pod changes.

Without forcing these, a week yields `P` and `Q` observations and little
else, and the terms that actually gate correctness — `C` and `R` — stay at
zero for the wrong reason.

### 11.2 Decisions 9-15

9. **The pod's re-assertion is not assumed, it is instrumented.** The
   correctness of global revocation (§5.1.1) rests on every path into
   `store(doses:)` passing the complete pending set, and there are five
   (`OmniPumpManager` lines 1075, 1205, 1415, 1559, 1620). Rather than
   prove it by reading the driver, phase 1 measures it: the `R` term, the
   §5.3 staleness count, and a revoked-then-reappeared check. **A
   revocation of a dose that later reappears is a stop-ship for cutover.**
   This is the highest-risk unknown in the plan.
10. **`reconciled()` is adopted in phase 1** (§6.1, §6.2), not deferred.
    It adds a fifth verifier term, `T` (§7.3). The reason this is cheap:
    `T` should be approximately zero, so it doubles as a test of an
    assumption `InsulinTimeline` currently makes on faith — see §6.1.1.
11. **`registerForPumpEntryUpdates` becomes a change notification.** The
    delegate stops receiving the log; `DiagnosticViewModel` queries a
    bounded recent window on demand. Lands in phase 0.
12. **`lastReconciliation` is recorded and honored as preparation, not as
    a fix.** No consumer on `main` needs settled history today, so it
    changes no present-day behavior; it becomes load-bearing the moment
    anything publishes settled history. §5.2 says so explicitly.
13. **HealthKit fidelity gets its own doc** —
    @dev/backlog/healthkit-improvements.md — describing how the store is
    expected to be used once this lands. Behavior here is unchanged
    (decision 4).
14. **The `pumpRecordsBasalProfileStartEvents` branch is kept and labeled
    unreachable.** `OmniPumpManager` returns hard-coded `false` (line
    2257) and no MinimedKit is vendored, so nothing may be tested against
    it or reasoned from it. §2.1.
15. **GRDB is added to the project before implementation starts**, pinned
    in `Package.resolved`, matching the major version the ClueClue port
    uses so the two stay portable.
16. **Retention's boundary is a resume, not the wall clock** (§4.3). The
    store keeps up to one pod cycle beyond 90 days so that all 90 are
    answerable, because a wall-clock cut leaves a rolling band of retained
    history that inference may never span. Bounded by
    `retentionAnchorMaxLookback` so that a driver which stops minting
    resumes costs a pod cycle of answerable history rather than an
    unbounded file. This is what makes I6 statable, and it is the reason
    decision 1 is now a floor rather than a ceiling.

## 12. Open questions

None outstanding. Everything raised so far is recorded in §11.

The two worth revisiting with data rather than argument, both during phase
1: decision 2 reopens if reported temp basal units turn out not to match
truncation, and decision 10's `T` term reopens the overlap assumption in
§6.1.1 if it is not approximately zero.