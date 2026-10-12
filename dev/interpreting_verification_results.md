# Interpreting verification results

> **The verifier is gone, and this document is history rather than an
> operational guide.** Phase 3 landed on 2026-08-11: `InsulinStoreVerifier`,
> `InsulinVerifierDatabase`, `dev/tools/verify_pump_db.py`, the JSON pump event
> log, and the cutover toggle were all deleted, and the record store is the only
> source of insulin history. Nothing produces a run any more, so §1's
> instructions for getting one, §6's watermark, and §7's instructions for adding
> to this file no longer describe anything that exists.
>
> It is kept because it is the only record of what the six runs established —
> that `P` closed and stayed closed, that `T` and `R` were structurally zero
> across 2,838 comparisons, that `Q` behaves and is single-signed, that `S`
> measured the present-tense-rate defect exactly as predicted. Read it as
> evidence for why the store is shaped the way it is; do not read it as a
> procedure. The findings that were only ever covered by a verifier term now
> have unit tests in `InsulinRecordTimelineTests` and `InsulinRecordStoreTests`.

The operational companion to @dev/pump_db_verification.md. That document explains
what each number *means*; this one is about what to do with a run in front of
you — how to get one, what order to read it in, what we have actually seen, and
what the next run should look like.

Keep the split in mind when editing: term-by-term theory belongs there, observed
results and forward expectations belong here. Section references below are to
that document unless stated otherwise.

## Which phase the phone is in

**This changes what a failure means, so establish it before reading anything
below.** Phase 2 — the cutover, §7.4 of @dev/backlog/insulin-storage-grdb.md —
landed in code on 2026-08-10 behind a toggle in Settings → Data export, and
**was turned on the same day**. The JSON log is still written and the verifier
still runs, so an export looks exactly as it did through run 5; what changed is
which path the loop believes.

**Nothing in either database records which path the phone was believing.** An
export taken in phase 2 is identical in shape to one taken in phase 1, so the
only record is this table. Keep it current the way §6's watermark is kept
current — a run interpreted against the wrong phase is worse than a run not
interpreted at all.

| the phone was believing | from | build |
|---|---|---|
| the JSON log (phase 1) | 2026-08-03, first parallel run | — |
| the record store (phase 2) | 2026-08-10 ~11:51, mid-run-6 | `ac8ea97` |
| **the record store, and only it (phase 3)** | **2026-08-11** | this branch |

Run 6 straddles the phase-2 switch, and its last 468 comparisons are the only
phase-2 evidence there is.

Phase 3 ends the table. There is no longer a JSON log to believe instead, so the
question the table answered no longer has two answers — and §5's read-failure
blind spot is now closed by a different mechanism than a fallback: a store read
that throws makes `lastPumpSync()` report nil, which trips
`ClosedLoopService`'s freshness guard and skips the tick. Refusing to dose
replaced preferring the second opinion.

## 1. Running it

Pull both databases off the device (§2 — Settings → Data export → "Share
verifier and store databases"), drop them in a directory, and:

    ./dev/tools/verify_pump_db.py path/to/directory

Or name them directly, which is what you want when they are sitting in the repo
root after an AirDrop:

    ./dev/tools/verify_pump_db.py --store pump_events.export.sqlite \
                                 --verifier verifier.export.sqlite

**Right now you also want `--since`**, because the verifier database still holds
four dead builds' history and it fails the gate on its own:

    ./dev/tools/verify_pump_db.py --store pump_events.export.sqlite \
                                 --verifier verifier.export.sqlite \
                                 --since '2026-08-08 09:11:00'

§6 is where that watermark comes from and what it is quarantining. Run it both
ways the first time: unfiltered tells you the database has not changed shape
underneath you, filtered tells you about today's build.

Every connection is opened read-only — `--since` included, which shadows the two
tables with temp views rather than deleting anything. The script exits non-zero
when the cutover gate fails, so it can be run from a hook without reading the
output, and `--since` moves that exit code with it so the hook and a human agree.

**Always pass both files.** With only the verifier you lose the entire coverage
section and the script cannot separate warm-up `C` from steady-state `C`, because
that needs `store_state.created_at`. With only the store there is no gate at all.

The output is long. It is meant to be read top to bottom once, and thereafter
triaged in the order below.

## 2. Reading a run, in order

**1. The VERDICT block.** If it passes, skip to step 5 — a gate that passed
because nothing interesting happened is not a gate that passed.

**2. The failing verdicts, grouped by day.** This is the single most useful
query the script does not print, and it separates warm-up from signal in one
look:

```sql
SELECT date(at,'unixepoch','localtime') AS day, verdict, COUNT(*),
       MIN(at), MAX(at), MAX(ABS(residual))
FROM comparison WHERE verdict != 'pass'
GROUP BY day, verdict ORDER BY day;
```

Warm-up failures cluster in the store's first day and stop. Anything after that
is a different animal and deserves the rest of this list.

**3. The terms on the failing rows.** Four shapes, and they mean different
things:

- **Every term zero, large residual** — a *row-set* difference, the two paths
  looking at different events. During the store's first day that is warm-up
  (§6.1).
- **Every term zero, small residual** — a derivation difference, and the
  interesting case: the paths agree on the rows and disagree on what they mean.
- **One term nonzero and the residual equal to minus it** — the paths agree and
  the term is wrong. Check `old − new` against the *other* terms first: if it
  lands exactly on `Q`, nothing differed except quantization and the failure is
  in the instrumentation. Run 2 is this shape.
- **One term nonzero but too small, the residual making up the difference** —
  the same lesson as above and easier to miss, because a term that moved looks
  like a term that worked. Add the residual back to the suspect term and see
  whether the sum is a number you can derive from the store; if it is, the term
  is short and the paths are fine. Run 4 is this shape, and adding the two gave
  the post-fix value to eleven decimal places.

**4. Whether the residual moves with the window.** Pull the neighbouring
comparisons:

```sql
SELECT at, window_start, old_value, new_value, q, residual, verdict
FROM comparison WHERE metric='delivered'
  AND at BETWEEN <failing_at>-900 AND <failing_at>+900 ORDER BY at;
```

`window_start` advances in roughly five-minute steps, not continuously, so
consecutive ticks share one. A residual that appears on exactly the ticks sharing
one `window_start` and vanishes on both sides is a **window-edge** effect, not a
dose that went wrong — look at what sits at that edge in the store.

**5. The coverage section, always.** §7's checks say whether the run saw the
things it needed to see. Zero delivery gaps longer than 24 hours means `P` was
never given a chance to be nonzero, and `P` is the finding the whole exercise
exists to produce.

**6. `Σ T`.** The one term whose expected value *is* the finding.

## 3. Four questions to ask before believing a failure

**Is it warm-up?** Compare against `store_state.created_at`. The `delivered`
residual closes when `now − 22h` passes the creation instant; `iob` closes
earlier than its 12-hour window suggests, because the window is wider than the
insulin action duration. If it walks down to zero, it was warm-up.

**Is it a build that no longer exists?** The verifier database accumulates across
reinstalls. It has no notion of which build wrote a row, so a defect fixed weeks
ago keeps failing the gate forever. Check whether the observations stop at some
instant and never recur — that shape means a build changeover, not a data
problem. This has bitten four times now — §6's table names all four — and §6
holds the watermark that answers it, which `--since` applies.

**Is the difference on the paths, or on the term that explains it?** The residual
is `(old − new) − (P+C+R+Q+T+S)`, so a wrong *term* fails the gate exactly as
loudly as a wrong path — and a term is code too. Before reading a failure as "the
paths disagree", check that they actually do. If `old − new` is explained by the
terms you can account for and the residual is the size of the one you cannot, the
suspect is the term. Runs 2 and 4 are both worked examples. The tally so far, as
a prior worth holding onto:

| finding | what it turned out to be |
|---|---|
| run 1, 12,820 `write_mismatch` | instrumentation — a missing exemption |
| run 1, the 5.3e-05 pair | **a real defect, in the new path** (`inferenceStart`) |
| run 2, Σ `P` = −1694 U | instrumentation — a sign, from tagging a suspend |
| run 4, the 6.06e-03 residual | instrumentation — `S` on the wrong basis |

Three of four were the instrument rather than the paths, so a wrong term is the
way to bet. But the fourth is why "check the term first" is a *first* step and not
a conclusion — and note that when the paths did genuinely disagree, the old path
was the one that was right. The gate firing does not mean the old path is at
fault, or even that either path is.

**Is it bigger than one pulse?** 0.05 U is the smallest thing a pod can deliver.
A residual four orders of magnitude below that is real — the tolerance is 1e-6
and the observed floating-point floor is 7.5e-11 across the 3,290 clean
comparisons above the current watermark (3.0e-11 on the 1,645 `delivered` rows,
7.5e-11 on `iob`), so there is no noise band anywhere near the tolerance — but it
is a *correctness* finding rather than a dosing one, and it should be triaged
accordingly.

`delivered` was *exactly* 0 through run 5 and picked up a floor of its own in run
6, which is worth knowing only so nobody reads the change as a signal: an
unweighted sum of a different set of segments rounds differently. Both numbers
are floors. What matters is that neither is within four orders of the tolerance.

**And check the rows that *passed*, if any sit near the tolerance.** The floor
above is what a clean build looks like. A *passing* residual between 1e-9 and
1e-6 is four orders of magnitude off that floor and is not noise — on the only
six occasions it has happened it was the **decay tail of a defect that was still
active**, small enough to slip under the gate rather than gone. Run 5 §4 has both
cases. The tell is the same one-term signature as above, so the query is:

```sql
SELECT at, metric, p, c, r, q, t, s, residual FROM comparison
WHERE verdict = 'pass' AND ABS(residual) > 1e-9 ORDER BY ABS(residual) DESC;
```

Empty is the expected answer. Anything in it means the gate is passing on size
rather than on correctness, and the term that is nonzero names the defect.

## 4. What we have seen

### Run 1 — 2026-08-03 to 2026-08-06, 3.1 days

First parallel run. Omnipod, lyumjev, 0.05 U pulse. Store created 2026-08-03
17:23:55; 1,127 live rows; 2,043 ticks × 2 metrics = 4,086 comparisons at roughly
one tick every 2.2 minutes, which is the pod's sync cadence rather than the loop
interval.

**Gate: did not pass.** `max |residual|` 1.610e+01 U, 759 non-pass verdicts, 0
reappearances. All seven snapshot invariants clean, `ingest_error` 0,
`synthetic_dose_identifier` 0, `stale_mutable` 0 on every one of 2,043 ticks.

Three findings, in descending order of how much they matter:

**757 of the 759 failures were warm-up, and closed on schedule.** The signature
was `P=C=R=Q=T=0` with a large residual, which §6.1 predicts verbatim — down to
the printed example line, `old=16.2500 new=0.1500 ... residual=+16.10`. Both of
its checkable predictions held:

| metric | predicted close | actual last failure |
|---|---|---|
| `iob` | ~12 h | 5.8 h (2026-08-03 23:13) |
| `delivered` | ~22 h | 21.8 h (2026-08-04 15:11) |

`iob` closing early is correct rather than suspicious: the 12-hour window is
wider than lyumjev's action duration, so pre-store doses stop contributing before
the window drops them. Nothing to do.

**12,820 `write_mismatch`, all from a build that no longer exists.** Every one
falls between 2026-08-03 17:26:14 and 18:48:14 — one 82-minute block on day one —
being 332 distinct identifiers re-reported across ~39 ticks, all for events dated
before the clamp. At 18:51:16 they stop and `pre_store_event` begins, at 310.

That handover is the tell. The exemption at `InsulinStoreVerifier.swift:525`
emits a `pre_store_event` row on *every* tick where it fires, and there are none
before 18:51 — so the build running that evening did not have it. It was
committed the following morning (588b525). Zero write mismatches in the three
days since.

Nothing to fix in the code. But the count is now permanent in that database, and
the script will keep reporting it as a hard FAIL, which is the argument for
resetting the verifier before the next run (§6).

**Two comparisons at 5.343e-05 U — a real defect, since fixed.** Both carried
`window_start` 2026-08-04 07:23:15.591; it is one window reported on two
consecutive ticks, not two independent events.

Root cause: the derivation's left edge was inconsistent. Doses over-fetch back to
the anchor (decision 3), so an inferred gap can open before `windowStart`, but
suspension evidence was cut off *at* `windowStart`. A completed suspend/resume
pair landing between the anchor's end and the window's start was therefore
dropped, and the gap kept the anchor's end as its left edge instead of the
resume — 481 ms earlier, across a stretch the pump had been suspended for.

The error mostly hid, because a gap is only mis-anchored in windows where the
mis-anchored part falls *outside* the window. What leaked was the five-minute
chunk grid: `insulinDeliveryQuantized` anchors chunks at a dose's own
`startDate`, so moving a segment's left edge re-aligns every chunk in it, and a
windowed sum moves by up to one chunk.

Worth recording because it inverts the usual assumption: **on this residual the
old path was right and the new path was wrong.** The new path was the one
inferring delivery across a suspension. It does not rehabilitate the old path —
`P`, the fossil-resume fabrication, is still an old-path bug — but "the residual
fired, therefore the old path is at fault" is not a safe inference.

Fixed 2026-08-07 by giving `PumpDoseTimeline` an `inferenceStart` (the anchor
dose's `endDate`) and keying the transition query, the suspension state query,
and the `suspendedIntervals` clamp off it, so suspension evidence spans exactly
what dose evidence spans.

### What run 1 established, and what it did not

| term | value | reading |
|---|---|---|
| `T` | 0 across 2,043 comparisons | **A real finding.** The driver does truncate superseded temp basals, so GlucOS has not been double-counting overlapping basal. |
| `Q` | Σ 45.84 U, max 0.058 U | Behaves. Decision 2 confirmed empirically: 862/862 samples match truncate-to-pulse, 0 match raw. |
| `C` | 0 always | Structurally zero, not a bug — §6.1 explains why warm-up does not show up here. |
| `P` | 0 always | **Untested, not confirmed.** `P` needs a delivery gap longer than the JSON log's 24-hour retention and there were none. The `[warn]` on "delivery gaps longer than 24.0h: 0" and `P = 0` are the same fact stated twice. |
| `R` | 0 always | **Untested.** Zero revoked rows in three days, so `replacePendingEvents` never orphaned a mutable dose. |

`reappearance = 0` passing is therefore vacuous: with no revocations, there was
nothing that could come back. Decision 9's stop-ship has not been exercised, and
§5.1.1 calls global revocation the highest-risk unknown in the plan.

Coverage otherwise: 1 pod change, 5 suspends, 1 suspension spanning a sync, 5
basal gaps over five minutes totalling 52 minutes, longest 24.3 minutes.

### One thing run 1 taught us about the pump

Two of the four completed suspend/resume pairs were **sub-second, and minted by
settings changes** rather than by a manual suspend. That matters for triage: any
defect whose trigger is "a completed suspension" is far more common than "how
often do I suspend the pump" would suggest.

### Run 2 — 2026-08-03 to 2026-08-08, 4.5 days

Same store and same verifier database as run 1, carried forward rather than
reset: 4,620 comparisons, of which 534 are new. One MDI day in the middle, with
the pod off from 2026-08-06 20:32:39 to 2026-08-07 19:55:22 — 23.4 hours, marked
as a pump suspension, which is correct because MDI accounting happens outside
BioKernel entirely.

**Gate: did not pass.** Run with `--since '2026-08-05 05:30:00'` it is 409
failures, all one class, all after the MDI return.

**`P` went nonzero for the first time — and it is the verifier's own bug, not the
old path's.** Σ −1694.87 U over 247 comparisons, worst 8.5181 U. The sign is the
tell. `P` is `old − withoutFossil` (`InsulinStoreVerifier.swift:296`), so a
*negative* `P` says removing the fossil made the old path compute **more**, which
is the opposite of fabrication.

On every failing row `old − new` is exactly `Q`, so the two paths agree and the
residual is nothing but the bogus `P`:

```
2026-08-07 20:37:03  delivered  old=4.0114  new=4.0000  P=-8.5181  Q=0.0114  residual=+8.518106
```

Root cause is `InsulinStorage.swift:391`, which tags the retained marker when it
is `.suspend || .resume`. §4's `P` in @dev/pump_db_verification.md says only a
**resume** is a fossil, and it is right: a resume claims "a dose ended here" and
inventing a left edge from it invents insulin, whereas a suspend is the evidence
that *suppresses* delivery. Deleting a suspend from the counterfactual does not
remove a fabrication, it removes the proof that 21.3 hours delivered nothing, and
the counterfactual fills the hole with scheduled basal. The arithmetic confirms
it exactly: `P` walks from −8.5181 to −5.1848 while `window_start` advances
8.333 h, which is 0.400 U/h — the scheduled rate, to three decimals.

It fired on the very first post-MDI tick and could not have done otherwise. The
suspend crossed the 24-hour retention cutoff at 2026-08-07 20:32:39; the first
tick after the pod reconnected was 20:37:03, 4.4 minutes later. There was no
window in which it could have passed.

**Fix:** narrow line 391 to `.last { $0.type == .resume }`. `mostRecentOldEvents`
holds at most one suspend-or-resume, so a retained suspend correctly yields `nil`
and `P` goes to zero. Applied and confirmed on device mid-run-3; see below.

**What the MDI day did prove.** Over a 22-hour window that was 21.3 hours
suspended, both paths report 4.0 U — the replacement pod's 4.0 U prime bolus at
19:58:19 and nothing else. The old path got a 23.4-hour suspension right
*because* `getMostRecentStatefulOldEvents` retained the suspend past the cutoff.
That machinery works, and the AID accounting is self-consistent across an MDI
period on both paths.

**What it did not prove.** Coverage still reads `delivery gaps longer than
24.0h: 0` — 23.4 hours, 36 minutes short. And a suspension is not the §1.2 case
anyway: the dosing-relevant fabrication needs a gap with *no* evidence, still
open at `now`. A clean suspend is evidence.

| term | value | reading |
|---|---|---|
| `T` | 0 across 2,310 comparisons | Run 1's finding, now with 4.5 days behind it. |
| `Q` | Σ 48.86 U unfiltered, 15.66 U since the watermark | Behaves. Decision 2 now 969/969 (100%) truncate-to-pulse. |
| `C` | 0 always | Still structurally zero. |
| `P` | Σ −1694.87 U | **Instrumentation, not a finding.** See above. |
| `R` | 0 always | **Still untested.** 0 revoked rows in 4.5 days. |

**The `inferenceStart` fix is not yet confirmed.** `5e96340` landed 2026-08-07
11:39, and the pod was off from 08-06 20:32 to 08-07 19:55, so there are no ticks
between those instants. The 2,520-comparison clean stretch (08-04 22:28 → 08-06
20:32, worst residual 2.4e-11) is entirely *pre*-fix: it shows the 5.3e-05 defect
did not recur over 2.6 more days of the old build, not that the fix works. The
fix has about eight hours of device time behind it and all 534 of those
comparisons are contaminated by the `P` bug. It becomes testable on run 3.

### Run 3 — 2026-08-08, +78 comparisons

A short deliberate-coverage run rather than a soak: 4,698 comparisons of which 78
are new, store at 1,311 live rows, last tick 06:32:04. Two things were forced —
a cancelled bolus and three settings changes — to try to reach `R` and
`reappearance`. Neither worked, and *why* is the finding.

**Gate: did not pass, but nothing the current build wrote fails.** 443 failures
with the run-2 watermark, and every one of them is at or before 06:22:30. Zero
after.

**The line 391 fix landed mid-run and `P` went to zero on the tick.** The two
adjacent comparisons that straddle the install:

```
06:22:30  old=15.1614  new=15.15  P=-4.6181  Q=0.0114  residual=+4.618106  regression:residual
06:25:33  old=15.1614  new=15.15  P= 0.0000  Q=0.0114  residual= 0.000000  pass
```

Same `old`, same `new`, same `Q`. Only the term moved, which is the signature of
an instrumentation change and cannot be produced by data. Ten ticks since: `P`
nonzero on 0 of them, max |residual| 1.32e-11, no failures. Run 2's `P` finding
is closed, and its Σ is now dead history.

**A cancelled bolus does not orphan a dose — it revises one.** This is why the
attempt to reach `R` failed, and it is worth knowing before anyone tries again.
The store row carries its programmed amount in the identifier and its delivered
amount in the column:

```
sync_identifier   "bolus 1.5 2026-08-08T13:28:18Z"
delivered_units    1.4
```

Visible in the series too: `delivered` jumps +1.5 U at 06:28:18 when the bolus is
reported, then drops 0.1 U at 06:29:15 when the finalized report lands. Both
paths tracked the revision identically. The driver re-asserts the same
`syncIdentifier` with a corrected amount, so the row is upserted, never orphaned.
Revocation needs the driver to *stop mentioning* a mutable dose, which cancelling
is not.

**The `inferenceStart` fix is still unconfirmed, but the setup finally exists.**
The three settings changes minted three completed sub-second suspend/resume pairs
(06:29:43, 06:30:42, 06:31:58) inside a real 2.3-minute inferred gap — the temp
basal ends at 06:29:43, the next begins at 06:32:03. That is the geometry the
5.3e-05 defect needs. It is not tested yet, because the defect is a *left-edge*
effect: the pair has to sit between the anchor dose's end and `windowStart`, and
these pairs are currently mid-window. They reach the edge at roughly 18:30 the
same day for `iob` (12-hour window) and 04:30 the next morning for `delivered`
(22-hour window). The clean 1.32e-11 at 06:32:04 is necessary, not sufficient.

| term | value | reading |
|---|---|---|
| `T` | 0 across 2,349 comparisons | Unchanged across three runs. |
| `Q` | Σ 49.32 U unfiltered, 16.12 U since the watermark | Behaves. Decision 2 now 987/987 (100%). |
| `C` | 0 always | Still structurally zero. |
| `P` | 0 on every post-fix tick | **Closed.** The Σ in the report is pre-fix history. |
| `R` | 0 always | **Structurally expected, not untested.** See below. |

### Cutover decision — `R` and `reappearance` on this driver

Run 2 said that if these were still zero after run 3 it was worth naming
explicitly rather than reading as a pass. They are, so here is the naming.

`R` measures a live mutable row that a `replacePendingEvents: true` batch failed
to assert. Reading the driver rather than waiting for one:

**Exactly one call site passes the flag true** — `OmniPumpManager.swift:3132`,
inside `store(doses:)`. Nine callers reach it.

**Eight of the nine pass `dosesToStore`**, which is defined at
`PodState.swift:96` as `finalizedDoses + [unfinalizedBolus,
unfinalizedTempBasal].compactMap { $0 }`. That re-asserts every unfinalized dose
*by construction*. Those eight cannot orphan anything: the in-flight bolus and
temp basal are in every batch while they exist, and they stop existing only
because `finalizeAllDoses` moved them to `finalizedDoses`, where they go out once
more as immutable.

**Pod changes cannot orphan either.** `forgetPod` (`OmniPumpManager.swift:1067`)
calls `podComms.forgetPod()` — which runs `finalizeAllDoses()`
(`PodComms.swift:111`) — *before* `store(doses:)`. Everything therefore arrives
immutable, and revocation only targets `is_mutable = true`. Two pod changes
across the three runs, zero revocations, and that is the expected result rather
than a miss.

**The ninth path is the one to keep.** `OmniPumpManager.swift:1205`, in the pod
prime sequence, passes `state.unstoredDoses` — a *retry buffer*, populated only
at `:1078` when a previous store failed. In the normal case it is empty, so the
call sends `[]` with `replacePendingEvents: true`, which the store reads as "I
have no pending doses" and which would revoke every live mutable row. It is
harmless whenever nothing mutable is live, and it is the one place in the driver
where the flag's assertion is not actually an assertion about pending doses.

So the orphan condition is narrow and specific: **a mutable row still live in the
store when a new pod primes**, which requires the old pod to have gone away
without `forgetPod` finalizing — an app kill mid-deactivation, or a fault where
deactivation never completes.

**The decision.** Record `R = 0` and `reappearance = 0` as *structurally
expected* for this driver, not as checks that passed. The store-side machinery is
covered by `rIsNonZeroWhenTheDriverOrphansAMutableDose` and
`aReappearanceIsRecorded`, both passing, so what the parallel run could not prove
is only whether the driver ever produces the condition — and the read above says
it does so through one path with a narrow precondition. That is a better answer
than five more days of watching, and it narrows §5.1.1's highest-risk unknown
from "five paths into `store(doses:)`, unproven" to "one path, and here is its
shape."

**If an empirical data point is still wanted,** the safe way is the mock pump.
The app already embeds `MockKit`/`MockKitUI`, and `MockPumpManager.swift:403`
passes `replacePendingEvents: true` with a settable `pendingPumpEvents`, so the
orphan can be constructed exactly — which is the right place to exercise a path
whose failure mode is under-counted IOB and therefore over-delivery.

### Run 4 — 2026-08-08, +128 comparisons

The run that finally moved `S`. 4,826 comparisons of which 128 are new, store at
1,344 live rows and 0 revoked, last tick 09:15:08. Nothing was forced; the finding
arrived because a basal rate was changed for ordinary reasons.

**Gate: did not pass, and again nothing the current build wrote fails.** 459
failures with the run-2 watermark, of which 443 are run 3's and 16 are new. All 16
sit between 08:52:03 and 09:10:07, and the four comparisons after that are clean.

**`S` fired for the first time, on the first real rate change.** The pod was
programmed from 0.4 to 0.5 U/h and the resume at 08:49:45 acknowledged it, which
is the mechanism §2 of @dev/backlog/scheduled-basal-history.md rests on. The store
shows it working end to end: `scheduled_basal` holds nine `backfilled` rows at 0.4
and two `acknowledged` ones — 0.4 at 08:49:05, then 0.5 at 08:49:45 — and both
`scheduled_basal_program` rows were consumed rather than abandoned. §8 predicted
exactly zero until a rate actually changed, and that held for three runs.

**But `S` was measured on the wrong basis, and the shortfall landed in the
residual.** The first failing tick:

```
08:52:03  delivered  old=17.128622  new=16.979167  Q=0.093393  S=0.050000  residual=+0.00606214
08:52:03  iob         old=0.801403  new=0.682550   Q=0.069620  S=0.048819  residual=+0.00041411
```

`S` came out at 0.05 U — exactly one pulse, which is the tell. Both `Q` and `S`
were defined against the quantized `new`:

```swift
let q = unquantizedTotals(derivation) - new     // unq(hist) − quant(hist)
let s = newTotals(atCurrentRate) - new          // quant(cur) − quant(hist)
```

so the pair subtracts `quant(hist)` twice and never telescopes to
`unq(cur) − new`, which is what the old path computes — it prices inferred basal
at one rate and never truncates to pulses. What leaks is
`Q(current) − Q(history)`: the two rate bases lose different amounts to
truncation, and the difference has nowhere to go but the residual.

The paths themselves agreed exactly. `old − new − Q` is 0.0560621 U; summing the
running inferred gaps in the window before 08:49:45 gives 2018.9 s = 0.56082 h,
which at the 0.1 U/h rate difference is 0.056082 U. The whole discrepancy was the
rate change, correctly derived on both sides and mispriced by one term.

**Fix:** measure `S` unquantized on both sides —
`unquantizedTotals(atCurrentRate) - unquantizedTotals(derivation)` at
`InsulinStoreVerifier.swift:327`. It is the only term measured that way, and it
has to be, for the reason above.

**It was applied mid-run and confirmed to eleven decimal places.** The two
`delivered` comparisons that straddle the install:

```
09:10:07  Q=0.0933929369118509  S=0.0500000000000007  residual=+0.00606214459405763  regression
09:12:05  Q=0.0933929369118509  S=0.0560621445775027  residual= 0.0                   pass
```

`S + residual` before the fix was 0.0560621445940583; `S` alone after it is
0.0560621445775027. Those agree to 1.7e-11 — the floating-point floor, not a
tolerance — so the post-fix value was predicted from the pre-fix residual before
the build was installed. `Q` is byte-identical across the boundary, so nothing but
the wrong term moved. Same signature as run 3's `P` fix, and data cannot produce
it.

| term | value | reading |
|---|---|---|
| `T` | 0 across 2,838 comparisons | Unchanged across four runs. |
| `Q` | Σ 51.91 U unfiltered, 18.71 U since the watermark | Behaves. Decision 2 now 1,012/1,012 (100%). |
| `C` | 0 always | Structurally zero — and now known to be unreachable. See below. |
| `P` | 0 on every post-fix tick | Still closed. |
| `R` | 0 always | Structurally expected, per run 3. |
| `S` | 0.0560621 U, correct after the fix | **Working.** The first term to be confirmed against a prediction rather than against zero. |

**Two things the `S` investigation turned up on the side.**

`C` carries the same basis defect and cannot fire. `suppressedSegments` are built
with `truncateToWholePulses` (`InsulinRecordTimeline.swift:308`) and there is no
unquantized parallel list, so `C` at `InsulinStoreVerifier.swift:323` prices in
pulses against an unquantized old path. It is unreachable rather than latent-risky:
`C` needs a gap whose left edge is below `history_complete_since` *and* that gap
inside the comparison window, and the clamp has sat at 2026-08-03 21:27:11 since
the store's first hours while the `delivered` window is 22 hours wide. Only
retention pruning advances the clamp, and that is ~90 days out.

**Closed by phase 3 rather than fixed.** `suppressedSegments` was a measurement
half and was deleted with the verifier, so there is no longer a mis-based term to
correct. The *behaviour* it measured is unchanged and is now asserted directly:
the derivation withholds a gap opening below the clamp and emits nothing for it,
which `InsulinRecordTimelineTests` pins by absence rather than by pricing the
counterfactual.

The script was blind to `S`. `verify_pump_db.py` selected `p, c, r, q, t` and
stopped, so the sixth term appeared in neither the ten-worst-residuals table nor
the FINDINGS block — the one situation §3 leans on that table to resolve. `S` was
found by reading the schema. Both places now print it.

### Run 5 — 2026-08-08 to 2026-08-10, +2,686 comparisons

**The first run that passes.** A two-day soak with nothing forced. 7,512
comparisons of which 2,686 are new, store at 2,097 live rows and 0 revoked,
6.7 days of record, last tick 2026-08-10 09:42:10.

**Gate: passes, at the run-4 watermark that §6 had not yet moved.** With
`--since '2026-08-08 09:11:00'`: 2,690 comparisons, max |residual| 7.518e-11,
0 non-pass verdicts, 0 reappearances. At the *old* `2026-08-05 05:30:00`
watermark it is still exactly 459 failures — the same 443 + 16 run 4 saw, not one
more. The last failing tick anywhere in the database is 2026-08-08 09:10:07.

**And it is no longer the vacuous pass §6 was worried about.** That is the whole
reason the watermark was left in place: moving it after run 4 would have left 4
comparisons above the line. It now leaves 2,690 across two days, one of them
carrying a real rate-change sweep. The watermark moves in this edit; see §6.

**`S` confirmed by prediction, on both metrics.** §5 predicted the 08:49:45 rate
change would leave the 22-hour `delivered` window "around 06:50 the next
morning." Last nonzero `S` on `delivered`: **2026-08-09 06:50:09**, and zero on
every one of the ~1,000 comparisons since.

| metric | predicted sweep-out | actual last nonzero `S` |
|---|---|---|
| `delivered` | ~06:50 on 08-09 | 06:50:09 on 08-09 |
| `iob` | ~20:50 on 08-08 | 14:57:24 on 08-08, decayed to 2.6e-09 |

`iob` closing ~6.1 h after the change rather than at its 12-hour edge is the same
action-duration effect as run 1's warm-up (5.8 h against the same window), not a
discrepancy: `iob` weights by insulin remaining, so a correction stops mattering
before the window drops it. `delivered` is an unweighted sum and therefore does
fall off exactly at the edge, which is why it is the one that lands to the
minute. `S` is now the only term confirmed against a prediction twice — its
magnitude in run 4, its sweep-out here.

**The `inferenceStart` fix has its device integration point at last.** Run 3
built the geometry and run 4 could not reach it. Both window left edges have now
swept the three sub-second suspend/resume pairs:

```
iob        at 08-08 18:30:13  ws 08-08 06:30:13  residual -6.31e-12  pass
iob        at 08-08 18:32:16  ws 08-08 06:32:16  residual -7.06e-12  pass
delivered  at 08-09 04:32:05  ws 08-08 06:32:05  residual  0.0       pass
```

That is the run-1 5.3e-05 geometry, at the left edge, on the real driver. §5 said
to look for the floor on those ticks and to hold nothing on it; it is there. The
unit tests remain the stronger evidence — this is the integration case they could
not cover.

**`P` closed with two more days behind it.** 448 nonzero rows in the whole
database, every one between 2026-08-07 20:37:03 and 2026-08-08 06:22:30, and zero
across all 2,690 post-fix comparisons. Σ `P` reads −1861.59 U rather than run 2's
−1694.87 only because run 3 captured 34 more pre-fix ticks before the fix landed;
it has not moved since. Dead history, as recorded.

**The one new thing: near-tolerance residuals that *passed*.** Six rows sit above
1e-9 while carrying a `pass` verdict, worst **4.91e-07** — only 2× under the gate
and four orders of magnitude above the 1e-11 floor. Both causes are known and
both are below the new watermark, but the shape is worth keeping:

- **Five** (08-08 01:57:04 → 02:02:05, `iob`) carry nonzero `P` with `residual`
  exactly `−P`. They are the `P` bug's *decay tail*: as the fossil suspend aged
  out of the insulin action curve its contribution fell from 8.5 U to ~5e-07 and
  the residual with it. The defect was fully active on these ticks. They passed
  because it had become small, not because it had stopped.
- **One** (08-03 23:16:16, `iob`, 1.57e-07) is the warm-up close caught
  mid-decay, three minutes after the last warm-up *failure* at 23:13.

This does not contradict §3's "no noise band near the tolerance" — it sharpens
it. The floor is real on a clean build; what lives in the 1e-9…1e-6 band is a
defect on its way out, and a gate that passes on magnitude rather than on
correctness. §3 now carries the query.

| term | value | reading |
|---|---|---|
| `T` | 0 across 2,690 comparisons | Unchanged across five runs. |
| `Q` | Σ 103.28 U unfiltered, 51.55 U since the watermark | Behaves. Decision 2 now 1,574/1,574 (100%). |
| `C` | 0 always | Structurally zero, and still unreachable — the clamp has not moved off 2026-08-03 21:27:11. |
| `P` | 0 on every post-fix tick, 2 more days | Still closed. |
| `R` | 0 always, 0 revoked rows in 6.7 days | Structurally expected, per run 3. |
| `S` | swept to 0 on schedule, both metrics | **Confirmed.** Magnitude *and* sweep-out now predicted. |

**Coverage grew but the two known holes did not close.** 11 suspends (from 6), 2
pod changes, 2 suspensions spanning a sync. `delivery gaps longer than 24.0h` is
still 0 and still the only `[warn]` — `P`'s dosing-relevant case remains
unreached, and needs a comms outage rather than a suspension. `R` is still 0,
which run 3 established is the expected result rather than a miss.

**One caveat on the cut.** `65885a5` (pump record retention anchored on resume
events) was committed 2026-08-08 09:46:20, inside the stretch above the new
watermark, so ~28 of the 2,690 comparisons were written before it. The exact
install instant is *not* observable here: unlike the `P` and `S` fixes, the
retention change moves no verifier term, so there is no signature to locate it
by — the ticks either side of 09:46 read 0.0 identically. This does not weaken
the watermark, which is a claim about the rows *below* the line; it only means
the rows above it are two builds rather than one, both green.

### Run 6 — 2026-08-10, +600 comparisons, and the cutover

**The run the cutover happened in.** 8,112 comparisons of which 600 are new,
store at 2,260 live rows and 0 revoked, 7.1 days of record, last tick
2026-08-10 20:45:47. `ac8ea97` installed and the toggle went on at ~11:51:45, so
the run splits: ~132 comparisons of phase 1, then **468 of phase 2**.

**Gate: passes, and — read this first — the hidden set did not grow.** At
`--since '2026-08-08 09:11:00'`: 3,290 comparisons, max |residual| 7.518e-11, 0
non-pass, 0 reappearances. Unfiltered it is still exactly **1,218** failures, not
one more than run 5 counted, and the last failing tick anywhere in the database
is still 2026-08-08 09:10:07. That is the check worth running before any other:
it says the watermark is still a claim about builds that no longer exist rather
than a lid resting on something live. §6's split table is unchanged except for
the count above the line.

**The phase-2 stretch is clean on its own.** 468 comparisons from 11:52:09 to
20:45:47, 0 failing, worst 4.16e-11 — and `delivered` is exactly 0.0 on all 234
of them. `ingest_error` is 0, which means something here it did not mean before:
in phase 2 a failed ingest fails the batch (§5), so zero is the driver never
having had to re-deliver.

**What this run cannot tell you, and it is the part that matters.** §5's
read-failure blind spot is now live. `ac8ea97` carries four `catch` sites that
log `"record store read failed … falling back to the JSON log"` —
`lastReconciliation`, `recentPumpEvents`, `currentInsulinType`, `pumpAlarm` — and
none of them touch the verifier, because the verifier derives both paths itself.
A phone that fell back on every single tick would produce precisely the export
above. **So the green 468 does not establish that the store carried the loop for
those nine hours; only the device log does.** Check it before treating run 6 as
phase-2 validation. This is the first run where a green gate and a working
cutover are separate claims, and the databases can only speak to the first.

**A real rate change produced `S` = 0, and §5's rule reads one way only.** The
pod went 0.5 → 0.45 U/h, acknowledged by the resume at 2026-08-10 10:08:07 —
a third clean pass through run 4's mechanism, with `scheduled_basal_program` row
3 consumed rather than abandoned and the counts reading `acknowledged=3
backfilled=9 changes=2 pending=0 abandoned=0 resumesWithNoRecord=0`. `changes=2`
against three acknowledged rows is correct: the first acknowledged 0.4 matched
the backfill, so only 0.4→0.5 and 0.5→0.45 are changes.

`S` then stayed at exactly 0.0 on every tick after it, and that is right. `S`
prices *inferred* basal at the current rate against its historical rate, and the
only inferred gap anywhere in the window opens **at the resume that acknowledged
the new rate** — so historical and current are the same number and the correction
is zero by construction. There were no gaps at all between the 08-08 08:49:45
change and this one, so `S` had nothing to price in between either. Σ `S` = 32.63
U above the watermark is still entirely the 08-08 sweep, last nonzero
2026-08-09 06:50:09.

The lesson to keep: **a nonzero `S` needs a rate change *and* an inferred gap
priced at the superseded rate.** A settings-change suspend/resume mints the gap
and acknowledges the rate in the same instant, which is exactly the case that
yields zero. §5 says a nonzero `S` with no acknowledging row is a finding; the
converse — a rate change, therefore expect `S` — is not true, and this run is why.

**`Q` corroborated the geometry to sub-second precision, and showed its own
boundary case.** `Q` went nonzero on the same tick that recorded the change:

| tick | `Q` | implied gap | actual |
|---|---|---|---|
| 10:11:09 | 0.02277115 | 182.17 s | 182 s — gap trimmed at `at` |
| 10:12:09 → end | 0.0302118991 | 241.70 s | 241.7 s — whole gap in window |

The gap is resume 10:08:07 → tempBasal 10:12:09, and 241.7 s at 0.45 U/h is
0.0302 U — **below one 0.05 U pulse.** Truncation therefore takes the whole
segment to zero, and `Q` is 100% of the inferred amount rather than the "~6% of
inferred basal" that §4 of @dev/pump_db_verification.md expects. Worth knowing
before someone reads a large-fraction `Q` as a defect: 6% is the figure over many
segments, and 100% is the figure over one sub-pulse segment. `Q` is also what
located this gap in the first place — two basal-chain gaps totalling 242 s are
easy to miss in a 7-day store, and the term found them.

| term | value | reading |
|---|---|---|
| `T` | 0 across 3,290 comparisons | Unchanged across six runs. |
| `Q` | Σ 60.31 U since the watermark, max 0.0934 | Behaves. Decision 2 now 1,701/1,701 (100%). |
| `C` | 0 always | Structurally zero, still unreachable — the clamp has not moved off 2026-08-03 21:27:11. |
| `P` | 0 on every post-fix tick | Still closed. |
| `R` | 0 always, 0 revoked rows in 7.1 days | Structurally expected, per run 3. |
| `S` | 0 across a real rate change | **Correct, for the reason above.** |

The §3 near-tolerance query returns the same six rows as run 5, all still below
the watermark. No new ones, which is what a clean build should do.

**Coverage: 13 suspends (from 11), and the one hole still open.** 2 pod changes, 2
suspensions spanning a sync, `delivery gaps longer than 24.0h` still 0 and still
the only `[warn]`. `P`'s dosing-relevant case is unreached after 7.1 days.

**The run ends mid-pod-deactivation, in phase 2.** The last events are a 1.0 U
bolus at 20:42:03, a zero temp to 20:45:46, and a **suspend at 20:45:46 that
never resumes**, one second before the final ingest — a pod change in progress at
export time, which is why `replaceComponent:pump` still reads 2 rather than 3.
Two things follow. It is the first pod change with the store authoritative, and
run 3's read of the driver holds: `forgetPod` finalizes before reporting, so
there are 0 live mutable doses and `R` is 0. And if delivery stayed stopped, the
next export may finally carry a `delivery gap longer than 24.0h` — but it is
bounded on the left by a **suspend**, which is evidence, so it still is not `P`'s
case (§5).

## 5. What to expect next

**The gate is green, so the posture has changed.** Through run 4 the question was
"which of these failures is dead history?" From run 5 on it is "did anything
fail?" — because at the current watermark nothing does. A failure in the next
export is a finding about *today's* build by default, not a build-changeover to be
triaged away. Resist reaching for `--since` to make a new failure go away; §6's
two rules exist for exactly that temptation.

**Expect a green gate, and read the coverage section anyway.** A pass over a run
that saw nothing is §2's vacuous pass. The two boxes still unticked are below.

**Phase 2 is on, so a failing gate is an alarm rather than a veto.** Before
cutover the question the gate answered was "may we believe the store". Now the
loop already does, and `old` is the fallback rather than the authority. A new
failure means *consider reverting* — which is what the toggle is for, and why it
does not need a build. Three things change about reading a run, none of them
arithmetic, and all three are in force as of run 6:

- **`new` is what dosed.** A residual stops being the difference between what we
  dose on and what we might dose on, and becomes the difference between what we
  dose on and what we used to. Same number, different question.
- **A store *read* failure is invisible to the gate.** When `timeline()` throws,
  the app logs loudly and falls back to the JSON log for that tick — but the
  verifier derives both paths independently and still records a clean comparison.
  So a phone that is nominally cut over and effectively is not produces a
  perfectly green export. Only the device log shows it: look for "record store
  read failed", at any of the four `catch` sites `ac8ea97` added
  (`lastReconciliation`, `recentPumpEvents`, `currentInsulinType`, `pumpAlarm`).
  This is the one failure mode the databases cannot surface. **Run 6's green 468
  phase-2 comparisons are subject to it and it has not been checked** — do that
  before citing them as cutover evidence.
- **A failed *ingest* now fails the batch**, so the driver re-delivers (§8). That
  is the intended behavior and not a finding in itself; a burst of them is.

**Neither database knows about the toggle, and it has stopped being a
nice-to-have.** Phase 2 is running now, and run 6 had to establish its own phase
from a commit timestamp and a memory. The next export will be entirely phase 2
with nothing in it saying so. Write the cutover state into the verifier database
once per tick — cheap, next to the existing per-tick observations — so an export
is self-describing and the table at the top of this document stops being the only
record. Still not done.

**`S` should be zero, and a nonzero one is a finding unless a rate changed —
but not the other way round.** Both the 08-08 and 08-10 changes have swept
(§4, runs 5 and 6). If you see a nonzero `S` with no `scheduled_basal` row
acknowledging a change inside the window, that is the finding.

The converse does **not** hold, which run 6 is the worked example of: a rate
change does not imply a nonzero `S`. `S` needs a rate change *and* an inferred
gap priced at the superseded rate. When the change is acknowledged by a
settings-change resume, that resume both mints the gap and carries the new rate,
so the gap is priced at today's rate and `S` is legitimately zero — as it was
across the whole 0.5 → 0.45 change. Confirm a rate change landed by reading
`scheduled_basal` and the `scheduled_basal_counts` observation, not by watching
`S`. Do not read run 4's or run 5's Σ `S` as a baseline either — run 4's carries
eight pre-fix 0.05s, and run 5's is one sweep-out, not a rate.

**A `Q` that is a large fraction of inferred basal is not automatically wrong.**
The "~6%" in §4 of @dev/pump_db_verification.md is the figure over many segments.
A single inferred segment shorter than one pulse's worth of delivery truncates to
zero, so `Q` is 100% of it — run 6's 0.0302 U over a 242-second gap. Check the
segment length before reading a high-fraction `Q` as a defect; the residual is the
thing that would tell you.

**The `inferenceStart` fix is confirmed in test and now on device too.**
`aCompletedSuspensionBelowTheWindowStillBoundsTheGap`
(`InsulinRecordTimelineTests.swift:574`) reproduces the run-1 geometry down to the
481 ms spacing, with three sibling tests around the other edges; run 3 established
that the real driver produces the shape; run 5 swept it through both window left
edges clean. Nothing further to watch for. If the 5.3e-05 signature ever returns,
it is a regression rather than an open question.

**`P` should stay at zero, and a nonzero one now means something.** After the
line 391 fix a nonzero `P` says the log's only pre-cutoff marker was a *resume* —
the real fossil, and the finding the term exists to produce. Do not read run 2's
Σ `P` as a baseline; it measured nothing about the old path.

**`P`'s dosing-relevant case is still unreached.** It needs a delivery gap longer
than 24 hours, recorded retroactively once the pump syncs again. The MDI day came
36 minutes short and was the wrong shape besides. If you want it deliberately,
what produces it is a comms outage with no suspend event — not a suspension.

**`R` and `reappearance` will stay zero, and that is now the expected result.**
Run 3 settled this by reading the driver rather than waiting: eight of the nine
paths into `store(doses:)` re-assert every unfinalized dose by construction, and
pod changes finalize before reporting. Expect zero, and treat a *nonzero* `R` as
the surprise worth chasing — it would mean the pod primed while a mutable row was
still live, which is the `OmniPumpManager.swift:1205` path.

**Warm-up recurs only if the store is recreated.** A store that survives a
reinstall carries its history and its clamp, so the first day's residuals do not
come back.

## 6. Housekeeping between runs

**Draw a watermark under superseded history; do not reset the verifier.** The
database has no build stamp, so a defect fixed weeks ago fails the gate forever.
Resetting fixes that and destroys the evidence this document is built on.
`--since` does the same job by hiding rows rather than deleting them, and it
moves the exit code with the report so a hook and a human agree.

**The watermark is `2026-08-08 09:11:00` (epoch 1786205460), moved there in run
5.** It splits exactly:

| | comparisons | failing |
|---|---|---|
| at or before | 4,822 | **1,218** |
| after (as of run 6) | 3,290 | **0** |

Run 6 grew the sample above the line from 2,690 to 3,290 and left the hidden side
untouched at 4,822 / 1,218 — the same counts run 5 recorded, down to the row. A
watermark whose hidden side stops growing is one that has retired a finite set of
dead builds rather than one that is absorbing new failures.

Everything below the line was written by a build that no longer exists, in three
generations:

| failures | span | class | build that wrote them |
|---|---|---|---|
| 757 | up to 2026-08-04 15:11:15 | warm-up (§6.1), plus 12,820 `write_mismatch` and 707 `pre_store_event` | pre-588b525 (run 1) |
| 2 | 2026-08-05 05:23:16 → 05:26:18 | the mis-anchored 5.3e-05 pair | pre-5e96340 (run 1) |
| 443 | 2026-08-07 20:37:03 → 2026-08-08 06:22:30 | the `P` sign bug (run 2) | pre-line-391-fix |
| 16 | 2026-08-08 08:52:03 → 09:10:07 | the `S` basis bug (run 4) | pre-`InsulinStoreVerifier.swift:327` fix |

**Why it moved, and why now.** The cut retires the last two classes at once. The
`S` fix installed between the 09:10:07 and 09:12:05 ticks — there is nothing
between them, so the cut is unambiguous — and the line 391 fix that killed the
older class installed hours earlier. Both are gone from today's build for reasons
recorded in §4: `P` under run 3, `S` under run 4, each confirmed by a term moving
across a build boundary while `old`, `new` and `Q` held byte-identical, which data
cannot produce.

It was deliberately *not* moved after run 4, because doing so would have left 4
comparisons above the line — the vacuous pass §2 warns about. Run 5 is what made
it honest: **2,690 comparisons over two days, 0 failing**, including a rate-change
sweep and the `inferenceStart` geometry crossing both window edges. That is a real
sample behind the line, which was the stated condition for moving it.

Note that the rows above the line are two builds, not one: `65885a5` (retention
anchored on resume events) was committed 2026-08-08 09:46:20 and the ~28
comparisons before it are on the prior build. That is fine — a watermark makes a
claim about what is *hidden* — but it is the reason not to describe the green
stretch as a single build's record.

**There is no next watermark, and that is the point.** Do not pre-stage one. Move
it again only when a failure class has been fixed *and* a run has accumulated a
real sample on the fixed build, in that order.

**Run 6 did not move it, and the reason is the rule above.** No failure class was
fixed between runs 5 and 6 — there was nothing to fix — so the first condition was
never met and the question of a sample never arose. A watermark does not advance
just because time passed and the gate stayed green; it advances to retire dead
failures, and there were none to retire.

Two things to know before trusting it:

- **The cut is exclusive and ticks carry sub-second times.** Naming a tick's own
  second keeps it: `--since '2026-08-05 05:26:18'` retains the row at
  05:26:18.197, which is the one you were trying to hide. Aim into the quiet
  stretch between ticks instead — the current `09:11:00` sits in the two-minute
  gap between 09:10:07 and 09:12:05, and the previous `05:30:00` sat between
  05:26:18 and 05:46:19, for the same reason.
- **Move the watermark forward only with a reason recorded here.** It is a claim
  that a build no longer exists, and it is only as good as that claim. A failure
  class that today's build can still produce must not be hidden behind it.

Do **not** reset the store to clear a verifier problem. That restarts warm-up,
throws away the history the clamp depends on, and costs a day before the residual
can close again.

## 7. If you are adding to this document

Record a run when it teaches something: a finding and its resolution, a term that
moved, a coverage box that finally got ticked. Runs that pass cleanly and see
nothing new do not need an entry — but a run that passes cleanly *and* finally
exercises `R`, or produces a nonzero `P`, is exactly the entry worth having.

Keep resolutions attached to findings. The most expensive minutes in run 1 were
spent re-deriving that a 12,820-row failure was a dead build, which is a fact
that fits in one line once someone has written it down.

**And keep §6's watermark current.** It is the only record of which rows are
dead, and `--since` is worth nothing without it. When you move it, say in the
same edit which build the rows below it came from and why that build is gone —
a watermark with no reason attached is indistinguishable from hiding a failure.
