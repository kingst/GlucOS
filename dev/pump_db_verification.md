# Verifying the pump database

What to look for after downloading the phase 1 parallel-run databases off a
device, and what each number means. Companion to
@dev/backlog/insulin-storage-grdb.md; section references below are to that
document.

The short version: run

    ./dev/tools/verify_pump_db.py path/to/downloaded/container

and read the **VERDICT** block at the bottom. It exits non-zero if the cutover
gate does not pass. Everything else in this document is about interpreting what
you see above that block, because the gate answers *may we cut over* and the run
was also supposed to answer three questions we would otherwise be guessing at.

## 1. Two files, and why they are separate

| file | what it is |
|---|---|
| `Documents/InsulinRecordStore/pump_events.sqlite` | The store under test. What the pump reported, and nothing derived (I1). |
| `Documents/InsulinVerifier/verifier.sqlite` | The evidence. Two tables: the residual time series, and discrete observations. |

They are separate files on purpose (§7.3.1). The store is what is on trial for a
week; recording the verdict inside it means a storage bug can corrupt its own
audit trail, and the failure mode of that is *silent agreement*. So if the
verifier database is missing or empty, that is a finding, not a convenience
problem.

Both live in their own directory so the WAL/SHM sidecars and SQLite's temp files
inherit `NSFileProtectionNone` — the app is woken by CGM Bluetooth before first
unlock, and a protected database fails to open exactly when the loop needs it
(§8).

## 2. Getting them off the device

**Both, the easy way.** Settings → Data export → "Share verifier and store
databases". You get `verifier.export.sqlite` and `pump_events.export.sqlite`;
drop them in a directory and point the script at it.

Both are `VACUUM INTO` snapshots rather than the live files, and the reason is
the same in both cases: the share sheet copies whenever it likes, and a database
copied mid-write is one that opens and then lies. For the store that is the
sharper risk — `DatabaseQueue` uses a rollback journal rather than WAL, so the
main file copied mid-transaction needs its `-journal` sidecar to open
consistently, and a share sheet hands over one file. They carry `.export.` names
because they land in the store's and verifier's own directories, which is how
they inherit `NSFileProtectionNone` (§8), and that means they cannot reuse the
live names.

Share both even when you only care about the gate. The gate is three queries
against the verifier, but every question in §7 — did this run actually see a pod
change, a suspend, an outage — is a query against the store, and the script
skips its whole coverage section without it. It also cannot separate warm-up `C`
from steady-state `C` without `store_state.created_at`.

**Or via Xcode.** Window → Devices and Simulators → your device → select
BioKernel → the gear menu → Download Container. You get a `.xcappdata` bundle;
the live databases are under `AppData/Documents/`. Point the script at the bundle
and it will find both.

Download the whole directory, not just the `.sqlite` file — the `-journal`
sidecar again.

## 3. The cutover gate — three numbers

§7.3.1 makes the cutover decision three queries rather than a judgment. The
script runs them; here they are so you can run them by hand.

```sql
SELECT MAX(ABS(residual)) FROM comparison;                       -- must be ~0
SELECT COUNT(*) FROM comparison WHERE verdict != 'pass';         -- must be 0
SELECT COUNT(*) FROM observation WHERE kind = 'reappearance';    -- must be 0
```

**Tolerance is 1e-6 U** — loose enough to absorb summing a few hundred doses in
binary floating point, and four orders of magnitude below one pulse (0.05 U), so
it cannot absorb a real difference.

A residual is *not* a difference between the two paths. The paths differ on
purpose, in five places we predict exactly:

```
old − new  ==  P + C + R + Q + T
residual   ==  (old − new) − (P + C + R + Q + T)
```

So a nonzero residual means a difference nobody predicted — which is the whole
point. It does not tell you which path is wrong, only that the model of their
difference is incomplete.

**Reappearance is a stop-ship on its own** (decision 9). A correct revocation
means the driver has abandoned the dose for good, so a revoked dose coming back
at all says the revocation was wrong. Global revocation (§5.1.1) rests on every
path into `OmniPumpManager.store(doses:)` passing the complete pending set, and
there are five of them; this check is the reason we measure that instead of
proving it by reading the driver. It is the highest-risk unknown in the plan.

## 4. The five terms — what to actually read

The gate is the residual. **The terms are the result.** Three of them answer
questions we would otherwise be guessing at.

### P — insulin the old path fabricated

`SELECT SUM(p), MAX(p) FROM comparison WHERE metric = 'delivered';`

How much insulin this bug was inventing on a real device. Expected nonzero; that
is the finding.

**Two things about P are easy to get wrong.**

First, **P is measured on the old path, not the new one.** The new path avoids
the fabrication because the database still holds the real events, so there is no
gap to fill — not because a clamp caught it. If you look for the phantom in C you
will conclude, wrongly, that there was never a bug.

Second, **P is narrowed to the retained suspend/resume marker.** §7.3 says to tag
all the ids `getMostRecentStatefulOldEvents` returned. That over-counts, and the
residual comes out at exactly minus the difference. Of the three markers it
retains:

- The retained **temp basal** is a real dose that really ended when it says. The
  store holds it too, and both paths use it as the same left edge. Nothing is
  fabricated.
- The retained **alarm** carries no dose and can bound nothing.
- The retained **`resume`** is the fossil. It says "the pump is running", not "a
  dose ended here". Using it as a left edge is what invents insulin.
- The retained **`suspend`** is **not** a fossil, and this is the half that is
  easy to lose. `getMostRecentStatefulOldEvents` keeps one slot for both, so the
  marker is a suspend whenever the pump was still suspended when the transition
  aged past the cutoff. That suspend is load-bearing: it is the evidence that
  suppresses delivery across the suspension, and removing it from the
  counterfactual does not remove a fabrication, it *adds* inferred basal across a
  stretch the pump delivered nothing. The tell is the sign — `P` comes out
  negative, and the residual comes out at exactly minus it. See run 2 in
  @dev/interpreting_verification_results.md §4.

So P is computed as a counterfactual: the old path's total, minus the old path
recomputed with the fossil removed. "What the old path gains from having retained
it." Only a `resume` may be tagged; a retained `suspend` must leave `P` at zero.

**A consequence worth internalising: P will be zero on a device that never lost
its temp basal history.** In steady state the retained temp basal sits about five
minutes before the retention cutoff, so the span the fossil could bound is
outside the comparison window entirely. P becomes large when the log's only
pre-cutoff event is the resume — which is what happened on the device that
produced the 40.4-hour, 16.164 U record. If P is zero across the run, that means
this device did not reproduce the condition, **not** that the bug isn't real.
Check the §11.1 coverage section before drawing any conclusion from a zero P.

### C — what the clamp withheld (I4)

Expected ~0 after the first day. The script separates warm-up C from steady-state
C, and it is only the second that means anything:

```sql
-- replace 1770000000 with created_at + 86400 from store_state
SELECT COUNT(*), SUM(c) FROM comparison
 WHERE metric = 'delivered' AND c != 0 AND at >= 1770000000;
```

Until `history_complete_since` predates the comparison window — roughly the
store's first 24 hours — the clamp legitimately withholds nearly everything.
That explains a large C. It does **not** excuse a nonzero residual, because C is
a term in the identity.

C nonzero *after* warm-up means the store holds rows below
`history_complete_since`. Legitimate causes: retention started pruning, or a
batch arrived stamped earlier than the clamp had already reached (the clamp is
monotonic and retention is not). Anything else is worth understanding first.

### R — how often the driver orphans a mutable dose

Decision 9's other half. Expected small.

Like P, this is a counterfactual rather than a sum of units, and for a reason
worth knowing: revoking a dose does not merely subtract its units, it opens a gap
that inference then fills at the scheduled rate. R is `derive(with the revoked
rows restored) − derive(...)`, so it is the *net* of those two. Summing the
revoked units alone leaves the difference between them as an unexplained
residual.

Cross-check R against two observation kinds:

```sql
SELECT COUNT(*) FROM observation WHERE kind = 'revocation';
SELECT COUNT(*) FROM observation WHERE kind = 'revocation' AND detail LIKE '%=false%';
```

The second **must be zero**. A revocation on a `replacePendingEvents == false`
call is a regression (§5.1), and the pod-change pseudo-event is the case that
exercises it — a store that treats the purge as always-on deletes every in-flight
dose the moment a pod change fires.

### Q — pulse quantization

Expected around 6% of inferred basal. Single-signed by construction, because
truncation only ever removes.

### T — overlapping temp basals

**The one whose expected value is the finding.** It should be about zero, because
`InsulinTimeline` asserts the pump driver truncates a superseded temp basal's
`endDate` when it goes immutable, so overlaps never survive deduplication. That
is currently taken on faith.

A materially nonzero T means the assumption is wrong and GlucOS has been
double-counting overlapping basal all along — a second bug, found for free. Look
at *when*:

```sql
SELECT at, t FROM comparison WHERE metric = 'delivered' AND ABS(t) > 0.01 ORDER BY t DESC LIMIT 20;
```

## 5. Decision 2: is truncation the right model?

For a pump-*reported* temp basal we hold both the reported units and what `rate ×
duration` predicts, so the model can be confirmed from data rather than from the
argument in §11.

```sql
SELECT units, detail FROM observation WHERE kind = 'quantization_sample';
```

`units` is what the pump reported; `detail` carries `raw=` (rate × duration),
`truncated=`, and `pulse=`. The script classifies each sample. What you want is
**reported == truncated** dominating. If "neither" dominates, decision 2 reopens
— that is a finding about the pump, and it changes what inferred segments should
carry.

## 6. Observations — three kinds must be empty

```sql
SELECT kind, COUNT(*) FROM observation GROUP BY kind ORDER BY 2 DESC;
```

| kind | expected | if not |
|---|---|---|
| `write_mismatch` | **0** | The store disagrees with the JSON log about a row it holds, or is missing one from inside the span it vouches for. The `detail` says which. This is the check that the dual write actually wrote. |
| `pre_store_event` | falling | Per tick, how many JSON events predate `history_complete_since` and are therefore exempt from the check above. §6.1 below. |
| `ingest_error` | **0** | The store's transaction threw. Phase 1 swallows these deliberately — authority is the JSON log — so this is the only place they surface. |
| `synthetic_dose_identifier` | **0** | A dose arrived with no driver `syncIdentifier`. The JSON path drops such doses outright and the store keeps them, so this explains a residual that would otherwise look unaccounted. |
| `reappearance` | **0** | Stop-ship. §3 above. |
| `revocation` | small | Every one should say `replacePendingEvents=true`. |
| `stale_mutable` | ideally 0 | One row per distinct dose that stayed mutable past an hour. |
| `stale_mutable_count` | trending to 0 | The per-tick count. §5.3 says this should trend to zero; if it does not, either the driver is orphaning doses more often than expected — which is R telling us something real — or finalization is broken. |

A comms outage longer than an hour legitimately trips `stale_mutable`, because
the last mutable temp basal stays un-re-asserted. That is information, not noise:
an outage is one of the two conditions §5.3 exists to surface.

### 6.1 The store's first day, and why `write_mismatch` is exempted below the clamp

The store starts empty. It only ever receives what arrives in an
`addPumpEvents` call, so for its first day the JSON log carries up to 24 hours of
history the store has no rows for. Every one of those would otherwise report as
`write_mismatch` — which is what a fresh install looks like:

```
17:26:14    332 mismatches    332 distinct ids   "in the JSON log with no row in the store"
17:43:15    327 mismatches    327 distinct ids
```

Worse, it never fully drains. `getMostRecentStatefulOldEvents` retains three
events from before the cutoff, and only one of them heals:

- The **temp basal** marker advances with the cutoff, so a few hours after the
  24-hour mark it becomes an event the store has.
- The **suspend/resume** and **alarm** markers only advance when a *new* one
  occurs. A three-week-old `resume` predates the store forever.

So the raw check would sit at one or two for the entire parallel run. A
must-be-zero check you have learned to explain away is worse than no check, so
events dated before `history_complete_since` are exempt — the clamp is already the
store's own statement of which span it vouches for (I5), and an event before it
cannot be expected to have a row.

The exemption is **counted, not silent**: `pre_store_event` records how many were
skipped on each tick. That count is the warm-up progress indicator. It should
walk down from a few hundred to a handful. A count still in the hundreds means the
store has been running less than a day, and the residual will not close until it
has.

**What warm-up looks like, and why it is not C.** §7.3 describes warm-up as the
clamp withholding nearly everything, which implies a large `C`. That is not what
you will see. `C` is the inference the clamp suppressed, and suppression needs a
*gap* whose left edge is below the clamp — which needs a dose below the clamp.
With no rows down there at all, no gaps open, so `C` is structurally zero and the
whole difference lands in the residual:

```
old=16.2500  new=0.1500   P=0  C=0  R=0  Q=0  T=0   residual=+16.10
```

Every term zero with a large residual is the signature of a row-set difference
rather than a derivation difference. During the store's first day that is expected
and self-correcting. After it, it is a bug.

Two checkable predictions while you wait, both worth confirming rather than
assuming:

- The **`iob` residual closes at about 12 hours**, because that window is 12 hours
  wide.
- The **`delivered` residual closes at about 22 hours**, because its window is
  `[now − 22h, now]` and it closes when `now − 22h` passes the store's creation
  instant — not at 24.

If either plateaus short of zero instead of walking down to it, that is a real
difference and worth stopping for.

## 7. Did the run actually see what it needed to?

**A gate that passes because nothing interesting happened is not a gate that
passed.** §11.1 is explicit that a week is shorter than the natural arrival rate
of two of the three events phase 1 needs, so they have to be forced rather than
waited for. The script's §11.1 section reports each:

| event | expected | how |
|---|---|---|
| Pod changes | ~2 in a week | Arrive on their own. Also the only way a `replacePendingEvents == false` call fires. |
| Suspend/resume | ≥ 2 | **Will not happen unless you force it.** Deliberately suspend delivery, once with a resume and once leaving the pump suspended across a sync. This is the event that exercises the stale-marker path that caused the bug. |
| A comms outage > 24h | ≥ 1 | **Will not happen reliably.** Walk out of range or turn Bluetooth off long enough to exceed the JSON log's retention window. The only way to exercise the one case §1.2 identifies as currently dosing-relevant. |

The script measures an outage from the gap in *delivery* — the longest stretch
with no basal dose — not from the gap in ingests. Any single event that does get
through (a pod change, a suspend) splits a `recorded_at` gap in two and would
hide a 30-hour outage as two shorter ones.

One limitation to be honest about: we only record `replacePendingEvents` on
revocation observations, so there is no direct log of a `false` call having
happened. The presence of `replaceComponent` rows is the proxy — that is when the
driver passes false.

## 8. Reading the store itself

Beyond the gate, the store answers questions the JSON log could not.

```sql
-- where the two edges of I5 sit
SELECT created_at, history_complete_since, last_reconciliation FROM store_state;

-- how much history we now hold, and how much of it is revoked
SELECT SUM(deleted_at IS NULL), SUM(deleted_at IS NOT NULL) FROM pump_event;
SELECT MIN(date), MAX(date) FROM pump_event;

-- what is still in flight, and how old
SELECT sync_identifier, dose_start, COALESCE(delivered_units, programmed_units)
  FROM pump_event WHERE deleted_at IS NULL AND is_mutable = 1 ORDER BY dose_start;

-- pods and insulins across the history: these are per row, not global
SELECT DISTINCT pump_plugin_identifier, insulin_type, smallest_delivery_unit FROM pump_event;

-- how late doses arrive
SELECT MAX(recorded_at - date) FROM pump_event WHERE dose_start IS NOT NULL;
```

The script also checks the invariants a snapshot can check — that no dose ends
before it starts, that no immutable row was revoked (I2), that nothing survives
past retention except the two exempt state markers. Those exemptions are
deliberate: retention keeps the newest suspend/resume and the newest
alarm/alarmClear however old they are, because a state answer has to stay
available past the deletion boundary. That is safe now for the reason it was not
before — I3 keeps those rows out of the array gap-filling walks, so a retained
marker informs the starting state without becoming a delivery boundary.

The **basal coverage gaps** section is worth a look on its own. It is the list of
stretches inference has to fill, and P and C only matter in proportion to it. A
device with no gaps longer than five minutes has almost nothing for inference to
get wrong.

## 9. If the gate does not pass

By kind, in rough order of how alarming it is:

- **`reappearance` nonzero.** Stop. Global revocation is unsound on this driver,
  and §5.1.1's argument needs revisiting before anything else matters.
- **`bolus-mismatch` or `temp-basal-mismatch` verdicts.** A pump-reported amount
  differs between the paths. Neither is ever inferred, trimmed, or quantized, so
  the only legitimate cause is revocation, which the verdict already accounts
  for. This is a store bug.
- **`new-basal-exceeds-old`.** Every term takes insulin *out* of the new path, so
  this direction has no explanation at all.
- **`residual` alone, small and constant.** Likely a sixth systematic difference
  nobody modelled. The ten-worst-residuals table the script prints shows all five
  terms alongside, which is usually enough to see which one is short.
- **`residual` alone, occasional and large.** Correlate `at` against the store's
  event log around that instant. A pod change, a suspend, and an outage are the
  three moments where the paths have the most room to disagree.
- **`write_mismatch` nonzero.** Read the `detail` — it names the field and both
  values. This one is usually the easiest to fix, because it is a write bug
  rather than a derivation bug.
