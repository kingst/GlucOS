# Scheduled basal history — record what the pod was programmed with

Companion to @dev/backlog/insulin-storage-grdb.md. That doc replaced the
24-hour JSON log with a complete record store and kept inference a pure
sweep computed on demand. This adds the one input that sweep still reads
from the present tense.

Ground truth for the code references below is branch `ai-interface` at
commit 573a1b0. "The parent doc" throughout means
@dev/backlog/insulin-storage-grdb.md; section references without
qualification are to this doc.

## 1. The defect

`InsulinRecordTimeline.derive`
(@ios/BioKernel/BioKernel/Services/InsulinRecordTimeline.swift:158)
takes `scheduledRateInUnitsPerHour: Double`, supplied at every call site
from `settingsStorage().snapshot().pumpBasalRateUnitsPerHour`
(@ios/BioKernel/BioKernel/Services/InsulinStorage.swift:253, :274,
:458).

That is a **now** value applied to **then**. Against a 24-hour log it was
nearly harmless. Against 90-day retention, every retrospective
derivation — TDD, daily summaries, `resetPublishedData`, the verifier —
silently re-runs history at today's rate.

It is the same shape as the bug the store was built to fix: one datum
doing two jobs. There it was a retained `resume` answering both "the pump
is running" and "the timeline starts here". Here it is one scalar
answering both "what the pod runs now" and "what the pod ran then".

### 1.1 The setting is not the pod

Worse than staleness. `SettingsViewModel.persistUpdatedSettings` writes
the setting to disk (@ios/BioKernel/BioKernel/ViewModels/SettingsViewModel.swift:120)
*before* pushing it to the pod (line 130), and says so in between:

```swift
// FIXME: if we error at this point the settings will be out of sync with what's running on the pump
```

So `pumpBasalRateUnitsPerHour` is what the user asked for, not what the
pod is running. A failed sync leaves the two divergent with nothing
recording the divergence.

**Any design that sources the rate from the setting records the wrong
number in exactly the case that matters.** This is the reason the design
below keys on the pod's acknowledgment instead, and it is worth more than
the staleness argument on its own.

### 1.2 Scope, so this does not get gold-plated

The trailing inferred segment — the only one inside DIA, and therefore
the only dosing-relevant one — runs to `at` and so always uses the newest
rate. It is correct today and stays correct.

What a rate change corrupts is retrospective only: totals, re-derivations
after `resetPublishedData`, and the verifier. Already-finalized export
rows are frozen with the rate current at publish and are not rewritten
underneath a reader.

This is a correctness-of-history problem, not a dosing-safety problem.
Worth doing properly; not worth an elaborate design.

## 2. The mechanism this rests on

**Every write of a basal schedule to a pod mints a resume.**
`PodCommsSession.setBasalSchedule` sets `podState.unfinalizedResume`
unconditionally
(@ios/OmnipodKit/OmnipodKit/PumpManager/PodCommsSession.swift:932), and
all three paths reach it:

- **Pod activation**, via `programInitialBasalSchedule` (line 503).
- **A schedule change**, via `OmniPumpManager.setBasalSchedule`
  (@ios/OmnipodKit/OmnipodKit/PumpManager/OmniPumpManager.swift:1714),
  which cancels all delivery (line 1759), minting a suspend, and then
  programs.
- **`resumeBasal`** (PodCommsSession line 949), which delegates to it.

Confirmed against a device export (`pump_events.export.sqlite`, covering
2026-08-04 → 08-08): both pod changes are preceded by a resume 11 and 12
seconds earlier.

```
04:27:11  resume                 08-08 02:55:22  resume
04:27:23  replaceComponent:pump  08-08 02:55:33  replaceComponent:pump
```

The resume is therefore an **acknowledgment**. It exists only because the
pod accepted the program; a failed sync mints nothing. That is precisely
what makes it the right event to key on, and it is what §1.1 needs.

**It is more than an acknowledgment, and the design rests on the stronger
statement.** `PodCommsSession.setBasalSchedule` sets
`podState.suspendState = .resumed(now)` and mints the resume at that same
`now` (lines 930-932), so the resume's date *is* the instant the new rate
begins running. Nothing is delivered at that rate before it. The two
paths reach this from opposite directions:

- **A schedule change on an active pod is a suspension.**
  `OmniPumpManager.setBasalSchedule` calls
  `session.cancelDelivery(deliveryType: .all)` (OmniPumpManager.swift:1759)
  before programming, and that mints `unfinalizedSuspend` via
  `handleCancelDosing`
  (@ios/OmnipodKit/OmnipodKit/PumpManager/PodState.swift:435-440). The
  interval between the request and the resume is a real suspension
  carrying 0 U, so it needs no rate at all.
- **Activation has nothing to suspend.** `setBasalSchedule`'s own
  belt-and-braces cancel is guarded by `podState.setupProgress ==
  .completed` (PodCommsSession.swift:921-923), so initial programming
  mints a bare resume with no preceding suspend. Both resumes in the
  export above are activations, which is why neither shows one.

So **no span anywhere requires the new rate before the resume exists.**
That is what makes §4.1 possible and what kills the alternative: any
design that timestamps a rate record before seeing the resume is writing
a number nothing needed, at an instant it cannot know.

### 2.1 A correction owed to the parent doc

§1.1 and §2.1 of the parent doc both state that a pod change does not
produce suspend/resume, citing `PodCommsSession.swift:932` — but 932 is
*inside* `setBasalSchedule`, which activation calls. The citation
refutes the claim, and the export confirms it.

The replacement claim needs the distinction from §2's second half, since
the two cases differ: **activation mints a bare resume** — the internal
cancel is skipped before setup completes — while **a schedule change on a
live pod mints a suspend and then a resume.** Neither produces nothing.

Two edits to make there as part of this work:

- **The claim itself**, in both sections.
- **§1.1's severity argument.** It reasons that "on a device that has not
  suspended delivery in three weeks, the retained `resume` is three weeks
  old and *should* be." On a pod user a resume lands at every activation,
  so that marker is bounded by how long a pod runs — and a pod stops at
  `Pod.serviceDuration`, **80 hours**
  (@ios/OmnipodKit/OmnipodKit/OmnipodCommon/Pod.swift:42; 72 h nominal).
  Back-to-back pods therefore put a resume in the log at least every 80
  hours, bounding a resume-anchored phantom at roughly that, or ~32 U at
  0.4 U/hr.

  The corrected story also **predicts the observation**, which the
  original does not. A three-week-old resume implies a phantom of some
  500 hours; what was measured was 40.4. That is the strongest evidence
  the correction is right, beyond the call path and the export.

Two qualifications belong with the new bound, because "bounded" is easy
to over-read:

- **It bounds the resume-anchored phantom only.**
  `getMostRecentStatefulOldEvents` also retains the most recent *temp
  basal* older than the cutoff, and that marker takes the same `else`
  branch. Temp basals arrive every five minutes while the loop runs, so
  normally it is barely stale — but during a comms outage none arrive at
  all, and then it is bounded by outage duration, which is genuinely
  unbounded. @stateful-issue.md's "unbounded in principle" is therefore
  correct; it is attached to the wrong marker.
- **80 hours assumes pods are replaced immediately.** The interval
  between resumes is pod life *plus* any gap before the next activation.
  The export contains one: `08-07 03:32:39 suspend → 08-08 02:55:22
  resume`, 23.4 hours with no pod. That case lands on the benign path —
  the retained marker is the suspend, which infers at rate 0, and that is
  correct, since a pod that is not attached delivers nothing. But that is
  luck about which marker happens to be most recent, not a property to
  rely on. A pod pulled without minting a suspend leaves the resume as
  the marker and fills a no-pod stretch with scheduled basal, which is
  the most wrong this bug ever gets.

Nothing about the fix, the invariants, or the rollout depends on any of
this — I3 and I4 hold regardless of how long the fabricated span would
have been. Only the severity framing changes, and it matters because
§1.1 is the paragraph someone will quote out of context when deciding
how urgent this is.

## 3. Design

### 3.1 A record, not a column

New table. Not a column on `pump_event`, and not a field on the resume
row.

`pump_event` holds what the pump reported (I1). The programmed rate is
something GlucOS learns from the **acknowledgment**, not from the event
payload — the resume dose carries no schedule, because
`UnfinalizedDose(resumeStartTime:)` has nowhere to put one. Denormalizing
it onto the resume would mean annotating a pump-reported row with an
app-side value, which is the mixing I1 exists to prevent.

```sql
CREATE TABLE scheduled_basal (
  resume_sync_id      TEXT PRIMARY KEY
                        REFERENCES pump_event(sync_identifier) ON DELETE CASCADE,
  rate_units_per_hour DOUBLE NOT NULL,
  source              TEXT NOT NULL,       -- acknowledged | backfilled
  recorded_at         DOUBLE NOT NULL
);
```

Same database as `pump_event`, so it shares the transaction and the
file-protection class — the same argument §4.2 of the parent doc makes
for the singletons.

**The link points from the rate record to the resume, not the other
way,** and it is the primary key. That keeps `pump_event` purely
pump-reported, and it reads as what it is — *this rate was programmed by
that acknowledgment*.

**There is no timestamp column.** The record's effective instant is
`pump_event.date` for `resume_sync_id`, read by join. An earlier draft
stored a copy of it and required the two doubles to be bit-identical,
because `effective_at <= gapStart` is only correct at a boundary if they
are. That is a real invariant with nothing enforcing it: any refactor
routing either value through a `Date` reconstruction, a JSON round-trip,
or an epoch-base conversion breaks it silently, and the symptom is a few
seconds of segment at the wrong rate — invisible to every test we would
think to write.

Four things follow from having no copy:

- **There is no equality to preserve.** The rate and the boundary come
  from one row and cannot disagree.
- **The load-bearing comparison disappears rather than acquiring an
  epsilon.** When `derive` splits a gap at a rate change it holds the
  record that produced the instant, so it reads that record's rate
  directly (§5). Timestamp comparison survives only for instants that did
  not come from a record — the left edge at `inferenceStart` — where a tie
  is measure-zero and tolerance is harmless.
- **Retention is the join.** The cascade removes a record with its resume,
  so §7 needs no separate prune rule.
- **A revoked resume takes its record with it.** Resumes arrive mutable
  and finalize under the same `sync_identifier` (parent §4.1), so the key
  is stable across that transition. If `replacePendingEvents` ever revokes
  a resume, the program did not stick and the record *should* go — a
  withdrawal path a timestamp-keyed table cannot express.

`source` is provenance only; both values resolve through the identical
lookup path and neither branches behavior. It exists so a backfilled row
(§4.2) is never mistaken for an observation, and so §8 can count them.

### 3.2 Why this does not contradict §2.1 of the parent doc

§2.1 argues against persisting anything inference concludes. It does not
apply here, and the distinction belongs in writing:

- An **inferred segment** is a conclusion drawn from *absence*. It must
  stay revisable, because a late dose changes the answer. Persisting it
  freezes a guess.
- A **programmed rate** is a positive fact, observed at the instant the
  pod acknowledged it, and never retroactively revised. It is an input to
  inference, not a conclusion of it.

I1 as currently worded — "what the pump reported, and nothing derived" —
reads like it excludes this. Sharpen it to "no conclusions", and scope
the new table explicitly as evidence-of-programming rather than
evidence-of-delivery.

**`source = backfilled` is the one row that does not satisfy that
argument,** and it is worth saying so rather than letting the column pass
unexamined. A backfilled row is an assumption about the past, not a
positive fact — which is precisely why it is labeled, why the label is
never read as evidence, and why §4.2 has to name the out-of-band reason it
is true. It exists once, for a migration; nothing writes another.

### 3.3 Periodic re-assertion, not a change log

A record is written on **every resume**, whether or not the rate changed
— roughly every pod change, and 8 times in 4.5 days on the sample device.

That is a feature rather than waste. Each record is an independent
observation of what the pod was programmed with at a known instant. The
alternative — write only when the value changes — leaves a single record
from years ago asserted to still hold today, which is extrapolation
wearing a timestamp. It is also what makes §7's retention rule work at
all.

## 4. Writing

The rate must come from what the pod acknowledged.

`OmniPumpManager.state` is public
(@ios/OmnipodKit/OmnipodKit/PumpManager/OmniPumpManager.swift:203) but
`OmniPumpManagerState.basalSchedule`
(@ios/OmnipodKit/OmnipodKit/PumpManager/OmniPumpManagerState.swift:32)
and `BasalSchedule` itself are both internal to OmnipodKit, so the pod's
schedule is not readable across the module boundary. **Do not widen them
to reach it** — the acknowledged value already comes back through the
public protocol.

Two write points. Neither writes a `scheduled_basal` row — both enqueue a
*pending program* that a resume later consumes (§4.1).

1. **`syncBasalRateSchedule` success.** It returns
   `Result<BasalRateSchedule, Error>` through the public `PumpManager`
   protocol, and @ios/BioKernel/BioKernel/LoopKitSupport/ManagerExtensions.swift:59
   already wraps it for async use. Called from
   `SettingsViewModel.swift:130`, unconditionally on every settings save
   whether or not the rate changed — a property §7 relies on. **Enqueue on
   success only** — never before it, never on failure. That is §1.1's fix.
2. **Pod activation.** GlucOS supplies the schedule itself via
   `PumpManagerSetupSettings`
   (@ios/BioKernel/BioKernel/LoopKitSupport/DeviceDataManager.swift:466),
   so the rate is known; enqueue when onboarding completes.

**There is no genesis write point.** §7's clamp covers the span before the
first record, and §7 is where the argument for that lives.

`pumpManager(_:didRequestBasalRateScheduleChange:)`
(@ios/BioKernel/BioKernel/LoopKitSupport/DeviceDataManager+Pump.swift:78)
**stays a stub.** It is the pump *asking* us to change a schedule, not
telling us it did.

**Success does not imply the pod was touched.** `setBasalSchedule` opens
with `guard state.hasActivePod else { save the schedule to state;
completion(nil); return }`, so `syncBasalRateSchedule` reports success
without programming anything when no pod is active. A design that wrote a
record on success would write a false one there. Under §4.1 the enqueued
program is simply never consumed and is abandoned, which is the correct
outcome and the second reason the queue exists.

### 4.1 The pending-program queue

A write point knows the rate at acknowledgment time. It does not know the
pod's instant for it, because the resume arrives later in a pump event
batch — and per §2 nothing needs the rate in the meantime. So
acknowledgment does not produce history. It produces a queue entry:

```sql
CREATE TABLE scheduled_basal_program (
  id                  INTEGER PRIMARY KEY,
  rate_units_per_hour DOUBLE NOT NULL,
  requested_at        DOUBLE NOT NULL,   -- app clock; matching and diagnostics only
  consumed_by_sync_id TEXT               -- NULL until a resume claims it
);
```

In the table rather than in memory, so it survives an app kill between
acknowledgment and the next sync. **A pending program is not history and
never serves a lookup.**

On ingest, each arriving resume resolves one of two ways:

- **A pending program within tolerance** — ~120 s before the resume's
  date, oldest first, one-to-one → mint the `scheduled_basal` row at that
  rate and set `consumed_by_sync_id`.
- **No pending program** → a bare `resumeBasal`, which re-programs the
  schedule already on the pod. Mint the row at the *previous record's*
  rate. That is §3.3's re-assertion, derived rather than stored.

Two things this fixes about the earlier design. First, a failed program now
writes nothing any lookup can see. The earlier version inserted a row at
the app's clock and, when it went unlinked, said to *keep serving lookups
from it* — so a failed sync would silently govern the rate from an instant
at which the pod was suspended and never resumed at that rate. That is the
§1.1 defect reintroduced downstream of the fix for it. Second,
`requested_at` is no longer a rate boundary, so nothing rests on it being
right.

The tolerance window survives, doing less work and different work: it no
longer reconciles a timestamp, it guards against **mis-attribution**.
Without it, a program that failed on the pod would sit in the queue until
the user's next manual suspend/resume, and that unrelated resume would
claim it and record a rate the pod never ran. **Programs older than the
window are marked abandoned rather than left queued**, and abandonment is a
diagnostic (§8): it means we programmed and never saw the acknowledgment.

The cost, stated plainly: between acknowledgment and the next ingest,
lookups return the previous rate. That is the conservative direction, it
self-heals because inference is a pure sweep over the store, and per §2
the span in question is a suspension inferring at 0 anyway.

### 4.2 Migration backfill

The store already exists on the development device with roughly four days
of events in it (`pump_events.export.sqlite`, 2026-08-04 → 08-08) —
including eight resumes and no `scheduled_basal` table at all. Under §7's
clamp, and with no genesis record, those four days would go
non-inferable until the next pod change.

So the migration backfills: **for every existing resume row in
`pump_event`, insert a `scheduled_basal` row at
`settingsStorage().snapshot().pumpBasalRateUnitsPerHour`, with
`source = backfilled`.**

- **The value comes from settings at migration time**, read once, rather
  than being written into this doc as a literal. There is nothing to fill
  in and nothing to keep in sync.
- **This is not the defect in §1.** §1's complaint is that the setting is
  read on *every derivation*, so history re-runs at today's rate forever.
  Reading it once, to stamp fixed rows that are then never revised, is the
  opposite shape — and it is why those rows have to be labeled (§3.2).
- **Every resume, not just the earliest.** They all carry the same rate, so
  §5's re-assertion filter makes the derivation output identical either
  way. Retention is what decides it: with all of them present, the day-90
  prune advances the clamp to the next resume, hours or days later. With
  only the earliest, the clamp jumps forward to the first genuinely
  acknowledged record, which could be much further out.
- **The registration therefore captures a runtime value,** so this is not a
  pure SQL migration — build the migrator with the rate and let the closure
  close over it. The property that makes that safe: the backfill selects
  existing resume rows, so **it is a no-op on any store with none.** A fresh
  install inserts nothing regardless of which rate was captured, which makes
  it a permanent migration needing no flag and no version guard.
- **Phase 1 is unaffected.** Every backfilled row carries the same rate the
  old path's scalar uses, so §8's divergence stays exactly zero across the
  backfilled span. The migration cannot muddy the residual.

**These rows assert a rate that was not observed.** What makes them true is
out of band — the rate did not change over that window — and that
justification cannot live in the store, so it lives in decision 9 with the
window named. `source = backfilled` is what keeps the rows from later being
read as evidence, and it is the whole reason §3.1 carries the column.

Cheap way to put the premise on the record rather than in memory:
`ClosedLoopResult` embeds a full `CodableSettings` per loop tick
(@ios/BioKernel/BioKernel/DataTypes/ClosedLoopDataTypes.swift:387-392), so
`closed_loop_results.json` is a five-minute-resolution history of
`pumpBasalRateUnitsPerHour`. One pass over it confirms the rate was
constant across those four days — which is what licenses stamping one
present-tense reading across all eight resumes. Optional; it changes no
design, it just turns decision 9's premise into a checked fact.

## 5. Reading

`PumpDoseTimeline` gains the rate history, fetched in the same
transaction as everything else so the row set and the rates cannot
disagree with each other. It is a join — `scheduled_basal` to the resume
row supplying each record's instant — served by the parent doc's existing
`idx_event_type_date`. Same I3 shape as suspension: the newest record at
or before `inferenceStart`, plus every record in `(inferenceStart, at]`.

```swift
struct ScheduledBasalHistory {
    /// One resolved record: the rate, and the resume that programmed it.
    struct Record {
        let resumeSyncId: String
        let effectiveAt: Date          // pump_event.date for resumeSyncId
        let rateUnitsPerHour: Double
    }

    /// Ordered by effectiveAt. The first entry is at or before inferenceStart,
    /// so every instant the derivation can reach has a rate.
    let records: [Record]

    /// For instants that did not come from a record — the left edge at
    /// inferenceStart. Never called at a record's own instant.
    func rate(at: Date) -> Double

    /// Records whose rate differs from the preceding record.
    func changes(in range: Range<Date>) -> [Record]
}
```

`derive(timeline:scheduledRateInUnitsPerHour:)` becomes
`derive(timeline:)`. That removes the last place a present-tense value
reaches a past-tense conclusion.

**`changes` returns records, not bare dates.** The caller needs the rate
that begins at each boundary, and taking it from the record it already
holds is what keeps §3.1's boundary out of a float comparison. Returning
dates would force a `rate(at:)` lookup at exactly the instant where `<=`
is load-bearing, which is the fragility the schema was shaped to avoid.

**`changes` must filter re-assertions.** §3.3 writes a record at every
resume, so most records repeat the previous rate. A repeat is not a
boundary and must not split a segment — otherwise every pod change
fragments an inferred segment for no reason, costing a pulse and shifting
the quantization grid. This is also what makes §8's parity claim true, and
what makes §4.2's backfill invisible to derivation.

## 6. Inference

One change, in `InsulinRecordTimeline.derive`.

**Rate changes subdivide gap pieces. They must never join the
`boundaries` array** (InsulinRecordTimeline.swift:244).

`boundaries` is evidence of delivery. A rate change is not evidence that
the pump did anything, and putting one there would let it act as an
inference left-anchor where no dose evidence exists — opening a gap from
a non-delivery event, which is the exact fabrication class this store was
built to prevent.

The place to do it is after the suspension subtraction (line 274): split
each remaining piece at the changes inside it, and emit one segment per
piece at its own rate — taking each rate from the `Record` that produced
the split, never by looking it up at the boundary (§5). The interval
machinery is already there.

Three consequences, predicted here rather than discovered later:

- **Quantization.** Each sub-piece truncates to whole pulses
  independently, so a change costs up to one pulse (0.05 U) downward.
  Single-signed, which is what the `Q` term already assumes.
- **Chunk grid.** Splitting re-anchors `insulinDeliveryQuantized`'s
  five-minute chunks at the new left edge, so a windowed sum can move by
  up to one chunk — the effect already described in the comment at
  InsulinRecordTimeline.swift:238-243. Correct here, because the boundary
  is real.
- **Only on actual changes.** Because `changes` filters re-assertions
  (§5), a device whose rate never changes produces output identical to
  passing the scalar.

## 7. Retention and the clamp

Records prune with everything else at 90 days, via §3.1's cascade, so
there is no separate rule to write. **No carve-out.** What makes that safe
is one addition:

```
history_complete_since = max(storeCreation,
                             retentionBoundary,
                             earliestSurvivingScheduledBasal.effectiveAt)
```

Computed after the prune, inside the same transaction.

Without the third term there is a band between the clamp and the first
*retained* resume where inference is live (I4 permits it, since the gap
starts after the clamp) but no rate record covers it. It is up to one
inter-resume interval wide and it recurs every time the clamp advances.

**Superseded in the ordinary case, and worth reading in order.** The band
above is real, and the third term closes it *by refusing to infer across
it* — correct, and a permanent hole in the oldest stretch of retained
history, rolling forward daily. The parent doc's §4.3 removes the band
instead: retention cuts at the newest resume at or before the cutoff that
carries a rate record, so the deletion boundary, the earliest surviving
record, and the clamp are the same instant and the three terms above
coincide. The second term is that boundary, **not** `now − 90d`; passing
the nominal cutoff makes `max` pick it and silently restores the band with
every row still present.

The third term therefore stops being load-bearing on the anchored path and
stays load-bearing on two others, which is why it is not removed: genesis
(§7.1), and the unanchored fallback when no resume is found within the
look-back bound. Everything below still describes those cases exactly.

### 7.1 The same term is why there is no genesis record

A store created mid-life has no rate record until its first resume. That
is the identical uncovered band at the other end of history, and the
identical clamp closes it — so genesis was doing work the clamp already
does.

The tempting alternative is to fall back to the current setting wherever
no record covers the instant. **That reintroduces §1 exactly,** confined
to the band: a rate changed on Wednesday leaves Monday-to-Wednesday with
no record, falling back to Wednesday's value — a now value applied to
then, in the one span with no evidence. It would also break the parent
doc's §10 idempotence test ("derive at T, ingest more, derive again; the
overlap must be identical"), since a settings edit would rewrite past
derivations. And it would give §8's divergence the same shape as the old
bug, so that term would stop being attributable.

A refusal is what we have grounds for. The setting is not evidence about
the pod (§1.1), and this unifies rather than carves out:
`history_complete_since` already means "we cannot trust ourselves before
here", and *we do not know what rate the pod was running* is that same
statement. The cost is losing up to a pod cycle of inferable history at
each edge, which touches retrospective totals only.

That cost is now paid only at the genesis edge and on the unanchored
fallback. At the retention edge the parent doc's §4.3 pays it in stored
rows instead — keeping the resume rather than refusing the span it
covers — which is the better trade in the one direction where we have the
option, because the evidence still exists and only the deletion was ours
to choose.

### 7.2 An empty table must clamp everything

This is the edge case dropping genesis makes load-bearing, and the natural
implementation gets it backwards: coalesce the missing third term to nil,
let `max` fall through to `storeCreation`, and inference runs across a span
with no rate at all. Genesis prevented that by construction. Without it the
empty case has to be written down and tested (§9).

A fresh store reaches its first record at the next pod change — up to
`Pod.serviceDuration` plus any gap — which lengthens the warm-up the parent
doc's §7.3 already plans for, against its decision 6's one-week run. The
cheap fix needs no code: `persistUpdatedSettings` calls
`syncBasalRateSchedule` on every save whether or not the rate changed
(SettingsViewModel.swift:130), so one tap of Save mints a resume and a
first record. That belongs on the parent doc's §11.1 forcing list.

**Do not have the app program the pod automatically at store creation to
bootstrap this.** It is a real suspend/resume of insulin delivery, and not
something to spend silently on a first launch after an update. On the
development device §4.2's backfill makes the question moot anyway.

## 8. Verifier

The old path (`InsulinTimeline.basalSegments` with the current scalar)
diverges from the new one in any window containing a rate change.
Because §5 filters re-assertions, that divergence is **exactly zero until
a rate actually changes** — so a phase 1 parallel run stays clean unless
the thing being fixed has occurred.

If a change does land mid-run it has to be attributable rather than a
mystery residual. Add a term alongside `C`/`Q`/`T`/`R`: the difference
between deriving with the history and deriving with the single current
rate. Zero when no change falls in the window, and exactly the correction
when one does.

§4.2's backfill does not disturb this. Every backfilled row carries the
same rate as the scalar, so the divergence stays zero across the
backfilled span and the migration cannot be mistaken for a regression.

Worth surfacing in `exportSnapshotURL()` as well, since none of it can be
asked of the residual series alone: record count split by `source`,
actual-change count, abandoned-program count, and any resume that resolved
to neither a pending program nor a preceding record.

## 9. Testing

- **No changes → output identical to passing the scalar.** This is the
  regression gate for every device that never changes its rate, and it is
  what lets this land during phase 1.
- One change mid-gap → two segments, correct rates, boundary at the
  resume's own date.
- **Re-assertion of the same rate mid-gap → one segment, not two.** Guards
  the pulse-loss and grid-shift regressions from §5.
- Change coinciding with a resume → the segment starting at the resume uses
  the new rate, **and reads it from the record rather than by comparing
  timestamps.** This is the boundary §3.1 is shaped around.
- Change inside a suspension → neither side gains units; the suspension
  still reads zero.
- Clamp interaction → prune until the earliest record moves, assert
  `historyCompleteSince` follows and that nothing is emitted before it.
- **Empty `scheduled_basal` → nothing inferred at all**, rather than
  everything inferred from `storeCreation`. §7.2.
- **Failed `syncBasalRateSchedule` → nothing enqueued, no record.** The
  §1.1 case.
- **Success with no active pod → program enqueued, no resume, no record,
  program abandoned.** The `hasActivePod` case in §4.
- **A pending program outside the tolerance window is not consumed by a
  later unrelated resume** — that resume re-asserts the previous rate
  instead. The mis-attribution case §4.1's window exists for.
- **A revoked resume takes its record with it**, and the clamp follows.
- **The anchoring resume keeps its record across a prune**, while resumes
  below the boundary lose theirs to §3.1's cascade — so the earliest
  surviving record and the retention boundary are the same instant, which
  is what collapses the three terms in §7.
- **Backfill is a no-op on a store with no resumes**, and re-running the
  migration changes nothing. §4.2.

## 10. Decisions

1. **Keyed on the pod's acknowledgment, not on the setting.** The setting is
   what the user asked for; the resume is what the pod accepted — and per §2
   it is also the instant the rate begins running. §1.1.
2. **Separate table, primary-keyed on `resume_sync_id`.** Keeps
   `pump_event` purely pump-reported and makes the link the identity. §3.1.
3. **Re-assert on every resume rather than write only on change.** Each
   record becomes an observation instead of an extrapolation, and it is
   what makes decision 7 safe. §3.3.
4. **No timestamp is stored.** The effective instant is the resume row's
   `date`, read by join, so there is no copy to keep bit-identical and the
   load-bearing comparison disappears instead of acquiring an epsilon.
   §3.1.
5. **Acknowledgment enqueues a pending program; only a resume mints a
   record.** A program that is never acknowledged never reaches a lookup.
   §4.1.
6. **Rate changes subdivide gaps and are never `boundaries`.** §6.
7. **Prune with everything else; the clamp absorbs the coverage requirement
   at both edges, and there is no genesis record.** §7, §7.1. **Narrowed
   by the parent doc's decision 16:** at the retention edge the coverage
   requirement is met by keeping the anchoring resume rather than by
   refusing the span, so the clamp absorbs it only at genesis and on the
   unanchored fallback. Records still prune with everything else via
   §3.1's cascade — what changed is where "everything else" stops.
8. **`didRequestBasalRateScheduleChange` stays a stub.** §4.
9. **The migration backfills every existing resume** at
   `pumpBasalRateUnitsPerHour` read from settings at migration time,
   `source = backfilled`. Justified out of band: the rate did not change
   over 2026-08-04 → 08-08 on the development device. That premise is the
   only thing making those rows true and the store cannot carry it, which
   is what this entry is for. §4.2.
10. **Flat rate for now.** GlucOS programs a single
    `RepeatingScheduleValue` at `startTime: 0`
    (SettingsViewModel.swift:118), so `rate_units_per_hour` is a scalar.
    If a real time-of-day profile is ever supported this becomes a
    schedule blob plus a timezone, and `rate(at:)` becomes
    timezone-dependent — a lookup change rather than a migration, given
    the record is keyed on the resume rather than on a time.

## 11. Suggested order

1. Both tables, the migration, and the record type behind the existing
   `InsulinRecordStore` protocol seam — including §4.2's backfill, so the
   four days already on the device stay inferable.
2. `ScheduledBasalHistory` on `PumpDoseTimeline`, fetched in the same
   transaction; `derive` loses its scalar parameter. At this point
   behavior is unchanged and §9's first test should pass.
3. The pending-program queue and both write points (§4, §4.1), with the
   tolerance window and abandonment. Rate history now grows on its own.
4. Gap subdivision in `derive` (§6), plus the re-assertion filter.
5. Clamp change (§7) and retention, including §7.2's empty-table case.
6. Verifier term and snapshot counters (§8).
7. The parent-doc corrections in §2.1.

Steps 1-2 are a no-op by construction and can land independently of the
rest — and with the backfill in step 1 that holds for the existing device
history too, not only for a fresh store.

## 12. Open questions

None outstanding.

The question this doc used to carry — whether a two-step timestamp
reconciliation earned its complexity — is answered by removing the
timestamp (decision 4) rather than by deciding how carefully to copy it.
Its proposed fallback, app-clock-only `effective_at`, was the one option
that had to be rejected outright rather than kept in reserve: §4.1 is why.
