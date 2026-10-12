# HealthKit improvements once the stores land

Follow-on to @dev/backlog/insulin-storage-grdb.md, which leaves HealthKit
behavior deliberately unchanged (decision 4). This is a note about what
becomes possible afterward and why, so the reasons are recorded while they
are fresh rather than rediscovered later.

Sections 1–4 are insulin, and none of it should be built until the insulin
store is authoritative — phase 2 of that doc. Section 5 is glucose, which
is gated on nothing: that store is authoritative already. It is punted, not
blocked.

## 1. What HealthKit holds today

`LocalHealthKitStorage.save(_ pumpEvent:metadata:)` writes one sample per
pump event, gated on:

```swift
guard let dose = pumpEvent.dose, !dose.isMutable, let deliveredUnits = dose.deliveredUnits else { return }
```

Boluses become `.bolus` samples and temp basals become `.basal` samples,
each carrying `syncIdentifier` and the insulin brand name in metadata.

The file's own header is candid about the gaps:

> The glucose data is solid, but we only store insulin doses that are
> already immutable. We do not include inferred basal insulin or ongoing
> tempBasal events or pump suspend / resume event, but people can use the
> event log if they want the full state.

Three consequences, in increasing order of how much the new store helps:

- **Scheduled basal is missing entirely**, so HealthKit's insulin total is
  low by however much scheduled basal ran. Small while the loop is
  temping continuously; large across any stretch it was not — open loop,
  connectivity loss, temp basal expiry.
- **A dose with no `deliveredUnits` is dropped**, even when immutable.
- **The escape hatch does not work.** "People can use the event log if
  they want the full state" is not true once the log is pruned to 24
  hours. Today HealthKit is the only long-term insulin record GlucOS
  keeps, and it is the incomplete one.

## 2. What the store changes

### 2.1 Stop writing duplicates instead of sweeping them

The most valuable change, and the least obvious.

Every insulin save kicks off `removeDuplicateEntries(sampleType:)` behind
a `isInsulinDuplicateRemovalRunning` flag. That sweep exists because the
write path has no memory: a dose is written whenever it arrives, with no
record of whether it was written before, so duplicates accumulate and are
cleaned up afterward. The `syncIdentifier` in metadata is there so a
consumer — or the sweep — can tell them apart.

With a store, "did we write this to HealthKit?" becomes a column. Write
once, on the transition to immutable, and the sweep becomes a repair tool
rather than routine hygiene. That removes a recurring background query
from the insulin path and makes duplicates a bug rather than an expected
condition.

### 2.2 Write inferred basal

The store makes GlucOS's own picture of scheduled basal stable and
reproducible, which is what made it unsafe to export before: the value
being written could change on the next derivation. It cannot now.

Two constraints carry over from the storage doc:

- Write only inside `[historyCompleteSince, lastReconciliation]` (I5).
  Outside that span we either deleted the evidence or the pump has not
  committed, and HealthKit is exactly the wrong place to put a guess —
  samples there are read by other apps and outlive the device.
- Write the quantized value (decision 2), not `rate × duration`, so
  HealthKit agrees with GlucOS's own totals rather than being ~6% high.

Inferred samples need a stable synthetic `syncIdentifier`; anchoring to
the segment's start in whole milliseconds is the obvious choice and is
already the shape `HealthKitStorage` uses for events without one.

### 2.3 Withdraw revoked doses

`deleted_at` exists so a revocation can propagate rather than vanish
(storage doc §5.1.1), and HealthKit is the consumer that makes it matter.
Today a dose revoked by `replacePendingEvents` stays in HealthKit forever
if it was written before the revocation — though in practice that is rare,
since only immutable doses are written and revocation only touches mutable
rows.

Worth doing for correctness, but the storage doc's phase 1 measures the
frequency first (decision 9). If `R` is effectively zero, this is a
one-line delete-by-`syncIdentifier` for completeness rather than a
feature.

### 2.4 Backfill after an outage

Writes are fire-and-forget: a failed `healthStore.save` is printed and
dropped. If HealthKit authorization is revoked and later restored, or a
save fails during a background wake, that dose is gone from HealthKit even
though GlucOS still has it — until retention drops it too.

With 90 days of history and a written-to-HealthKit column, a sweep can
find and fill the holes. This is the change that turns HealthKit from a
best-effort mirror into an actual mirror.

## 3. What not to do

- **Do not write mutable doses.** An in-flight bolus's delivered amount
  grows as it ramps, and HealthKit has no notion of a sample that is still
  settling. The existing `!dose.isMutable` guard is right.
- **Do not write GlucOS's IOB.** It is a pure function of doses, a model,
  and a time; storing it lets it go stale, and HealthKit has no insulin
  activity type anyway.
- **Do not write suspend/resume as events.** A suspension is legible as
  the absence of delivery, or as a zero-unit basal sample if HealthKit
  accepts one — see question 2. It is not a dose.

## 4. Open questions

1. **Does HealthKit accept a zero-quantity `insulinDelivery` sample?** If
   it does, a suspension can be published explicitly as a rate-0 basal
   sample and a reader never has to infer suspension. If not, suspension
   is representable only as a gap, and any consumer summing basal will
   read a gap as missing data rather than as zero delivery.
   *Unverified.* Worth testing before designing around either answer.
2. **Should the `written_to_healthkit` marker live in `pump_event` or its
   own table?** A column is simpler; a separate table keeps a
   pump-reported-facts table free of our own bookkeeping, which is the
   line the storage doc draws in its I1.
   *Leaning:* separate table, for I1.
3. **What happens to the samples already written?** Existing HealthKit
   data has no scheduled basal and possibly duplicates. Backfilling
   historical inferred basal would mean writing samples for periods whose
   evidence is gone — precisely what I4 forbids.
   *Recommendation:* do not backfill before `historyCompleteSince`. Start
   correct going forward and leave history as it is.
4. **Is `removeDuplicateEntries` still needed at all** once writes are
   idempotent, or does it stay as a repair path for data written by older
   builds?
   *Leaning:* keep it, but move it off the per-save path to a manual or
   infrequent trigger.

## 5. Glucose

`GlucoseRecordStore` / `GRDBGlucoseRecordStore` is authoritative from its
first launch — no parallel run, no cutover, because a CGM reading has no
dose lifecycle to reconcile and nothing is inferred between two readings.
So none of this section waits on a phase gate the way §2 does.

### 5.1 The glucose write loses readings today

The file header calls the glucose data "solid", and as a picture of what
the CGM reported it is. What is not solid is whether HealthKit got it.
`LocalHealthKitStorage.save(_ glucoseSample:metadata:)` drops a reading on
the floor three ways, all silent:

```swift
guard cachedPreferences.writeGlucose else { return }
guard HKHealthStore.isHealthDataAvailable(), healthStore.authorizationStatus(for: glucoseType) == .sharingAuthorized else { return }
...
} catch { print("LocalHealthKit: Error storing glucose: \(error)") }   // and gone
```

`LocalGlucoseStorage.addCgmEvents` calls it from a detached `Task` it never
awaits, so nothing observes the failure either.

This is §2.4's argument, but it bites harder for glucose than for insulin,
for two reasons:

- **Authorization is not granted yet on a fresh install.** Every reading
  that arrives before the user taps Allow is absent from HealthKit
  permanently. Insulin has the same hole, but a new install takes a while
  to produce its first immutable dose and produces a reading within five
  minutes.
- **The failures land on the wake path.** The app is woken by CGM
  Bluetooth before first unlock, and the glucose store carries
  `NSFileProtectionNone` precisely so that wake can write to it. HealthKit
  is protected data, so the readings most likely to fail the save are the
  ones only this store has. See §5.5 question 1.

We now hold 90 days of readings and cannot say which of them made it.

### 5.2 The shape: `healthkit_saved_at` on `glucose_reading`

A nullable `DOUBLE`, not a boolean. Same storage, and `IS NULL` is the same
query as `= 0`, but the timestamp says *when*, which makes "how far behind
is the sweep" answerable and a stuck row visible. It also matches every
other has-this-happened field in both schemas — `deleted_at`,
`recorded_at`, `last_reconciliation`, `legacy_import_at`. A boolean would
be the only one of its kind.

A column rather than the side table §4 question 2 leans toward for
`pump_event`. **The glucose store has no I1**: nothing infers across
glucose readings, so there is no pump-reported-facts invariant to keep our
bookkeeping out of, and `recorded_at` already puts our bookkeeping in that
table deliberately. Two lesser reasons: `WHERE healthkit_saved_at IS NULL
AND date > ?` can be checked by someone who does not know this codebase,
which is the standard the schema holds itself to, and a `NOT EXISTS`
subquery cannot; and at 288 readings a day a side table would roughly
double the row count of the largest table in the app to carry one bit.

Add `CREATE INDEX ... ON glucose_reading(date) WHERE healthkit_saved_at IS
NULL` and the pending set stays a handful of rows however much history
accumulates.

### 5.3 The sweep, and which side effects belong in it

The column is only worth having if something sweeps it; otherwise it is a
wider row. What it buys:

- **HealthKit becomes query-driven rather than `inserted`-driven.** Select
  where NULL, save, then mark. That closes the crash window between our
  ingest and the detached `Task`, and it makes a revoked-then-restored
  authorization self-healing.
- **Save, then mark — never mark, then save.** A crash between the two
  re-saves rather than skips, and re-saving is benign because
  `removeDuplicateEntries` already dedups on the `syncIdentifier`
  metadata. Ordering it the other way turns a crash into permanent data
  loss.
- **Bound the sweep by date** (24 hours, or a week). That handles "the user
  has glucose writing switched off" without inventing a third state — rows
  simply stay NULL — and means flipping the preference on backfills a day
  rather than ninety.
- **Alerts, watch context, and the chart stay keyed to
  `result.inserted`.** They are time-sensitive and must fire once, now, or
  not at all: a catch-up sweep must never raise a four-hour-old low alert.
  That is the line — a saved-at column belongs to durable mirrors, not to
  notifications.

### 5.4 The AI export column, when it exists

Deliberately not added yet. @dev/backlog/ai-interface-prompt.md §11 puts
glucose export out of scope, so an `ai_exported_at` column would have no
writer, and an unused column invites a reader to assume it means
something. Adding it later is `ALTER TABLE ADD COLUMN` in a v2 migration,
which SQLite satisfies without rewriting the table.

Worth recording for when it does land: a column beats extending
`AiExportState.exportedIds`. That ledger is a JSON dictionary rewritten on
every export pass, and at 288 readings a day against its seven-day
retention it would carry ~2,000 entries — which is the kind of thing moving
to SQLite is supposed to end.

### 5.5 Open questions

1. **Does the HealthKit save actually fail before first unlock, and with
   what error?** `HKError.errorDatabaseInaccessible` is the expected
   answer, and it decides whether the sweep is the main path for readings
   ingested on a Bluetooth wake or merely a safety net for them.
   *Unverified.* Cheap to test: write on a locked device and read the
   error.
2. **Does the divergence from §4 question 2 stand?** If the insulin side goes
   with a side table, glucose using a column means the two stores stop
   being structurally identical, which costs reviewability — the thing
   `GRDBGlucoseRecordStore` otherwise optimizes for by mirroring
   `GRDBInsulinRecordStore`. Worth deciding both at once.
   *Leaning:* accept the divergence; the I1 reason for a side table is
   real for `pump_event` and absent for `glucose_reading`.
3. **Should first-time authorization backfill wider than the sweep's
   window?** Unlike inferred basal there is no I4 objection — a reading is
   a reading, and every one of the 90 days we hold is exactly as true as
   the newest. The reason to bound it is taste rather than correctness:
   silently depositing three months of samples into someone's Health app
   the moment they tap Allow is a surprise.
   *Leaning:* bound it, and offer the full backfill as an explicit button
   in the HealthKit settings view.
4. **`removeDuplicateEntries` only sweeps the last 24 hours.** Any
   duplicate older than that is never cleaned, so if the marking write is
   ever the thing that fails, duplicates accumulate out of the sweep's
   reach. Does the sweep's window need to follow the store's retention, or
   is idempotent writing enough to make it moot?
