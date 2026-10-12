# Phase 3 — retire the JSON path and the verifier

A build prompt for the last step of the insulin-storage port. §7.5 of
@dev/backlog/insulin-storage-grdb.md is the one-paragraph version; this is the
inventory, the traps, and how to know it worked.

**Phase 3 is a deletion, not a migration.** The record store has been
authoritative since 2026-08-10 (§"Which phase the phone is in" in
@dev/interpreting_verification_results.md). Nothing new gets built here. If a
step needs a design decision, it is out of scope — see the last section.

## State going in

Six verification runs, gate green on the last two.
@dev/interpreting_verification_results.md §4 run 6 is the current record. The
findings the parallel run produced are all closed or structurally explained, and
the ones that were only ever covered by a verifier term now have unit tests —
see "What the tests already cover" below.

## Delete

| what | where |
|---|---|
| the verifier | `Services/InsulinStoreVerifier.swift`, `Services/InsulinVerifierDatabase.swift` (whole files) |
| its tests | `BioKernelTests/InsulinStoreVerifierTests.swift` (whole file) |
| its wiring | `AppComposition.swift` — `insulinVerifierDatabase` (:43, :239), `makeInsulinVerifierDatabase` (:298), `makeInsulinStoreVerifier` (:314), the `verifier:` argument (:162) |
| the offline reader | `dev/tools/verify_pump_db.py` |
| the JSON log | `InsulinStorage.swift` — `eventLog` (:213), `removeOldEvents` (:560), `logRetentionTimeInterval`, `getMostRecentStatefulOldEvents`, `removeStaleMutableDoses`, its own `syncDataToDisk`, `readFromDisk`'s `PumpEventStorage`/`pump_events.json` fallback (:490-502) |
| the cutover toggle | `InsulinStorage.swift` — `useRecordStoreForDosing`, `isRecordStoreAuthoritative`, `setRecordStoreAuthoritative`; `DataExportView.swift` — the Cutover section and `cutoverBinding`; `MockClasses.swift` — the mock's `isRecordStoreAuthoritative` |
| the verifier UI | `DataExportView.swift` — `verifierSnapshot`, `verifierSummary`, `reloadVerifier`, the "Insulin store verifier" section (:105-:145, :174) |
| the measurement halves | `InsulinRecordTimeline.swift` — `Derivation.suppressedSegments`, `unquantizedInferredSegments`, `unreconciledDoses` and the four `unquantized*`/`unreconciled*` sums; the `overridingScheduledRate` parameter and the `if let overridingRate` branch in `subdivide` |

Once the toggle is gone, every read in `InsulinStorage` derives from the store
unconditionally and a failed read is an error rather than a fallback. §8 of the
backlog doc already requires the batch to fail on a write error; that behaviour
stays exactly as it is.

## Four things that are not simple deletions

**`InsulinTimeline` cannot be deleted, and this is the important one.** It has
two consumers that are not the old dosing path:

- **`AiInterfaceStorage.buildExport` (:324) calls
  `InsulinTimeline.basalSegments`.** That is the exporter the original
  16.164 U phantom was *found* in — the `glucos:basal:` row in
  `finalized_insulin_dosing.2026-08-03.jsonl`, per @stateful-issue.md. Deleting
  the JSON log while leaving this pointed at `InsulinTimeline` keeps the
  fabrication alive in the published record, which would make phase 3 a
  regression rather than a cleanup. Repoint it at `InsulinRecordTimeline`.
  Note it currently takes a **scalar** `scheduledBasalRateUnitsPerHour`, which
  is the present-tense-rate defect `S` measured — so repointing fixes that in
  the export too, and `@dev/backlog/scheduled-basal-history.md` is the reference
  for what replaces the scalar.
- **`DiagnosticViewModel.swift:125` calls
  `InsulinTimeline.deduplicatedDoses`** over raw entries for a diagnostic view.
  Lower stakes, but it still needs somewhere to go.
- **`InsulinTimeline.minimumInferredSegmentDuration` is used by
  `InsulinRecordTimeline`** in four places. Move the constant before deleting
  anything around it.

**`AlertStorage.syncDataToDisk` is a different method that happens to share a
name.** Do not touch `Services/AlertStorage.swift`.

**`getMostRecentStatefulOldEvents` and `removeStaleMutableDoses` appear in
`GRDBInsulinRecordStore.swift` and `InsulinRecordStoreTests.swift` as
comments** explaining what the store's own machinery replaced. Those are the
record of why the store is shaped the way it is — keep them, and reword only if
a dangling reference reads badly once the symbol is gone.

**`C` had a known basis defect that dies with the verifier.**
`suppressedSegments` is built with `truncateToWholePulses` and had no
unquantized twin, which run 4 flagged as "worth fixing when someone is next in
the file". Deleting `suppressedSegments` closes it. Strike the note in run 4 of
@dev/interpreting_verification_results.md rather than leaving a to-do pointing
at deleted code.

## What the tests already cover

Do not re-derive this. `InsulinRecordTimelineTests` and
`InsulinRecordStoreTests` now carry the cases that were only ever covered by a
verifier term or that the runs never reached:
`anOutageStillOpenAtNowInfersUnboundedScheduledBasal`,
`anOutageBehindASuspendInfersNothingAtAll`,
`anInferredSegmentBelowOnePulseDeliversNothing`,
`aGapOpeningAtTheAcknowledgingResumeRunsEntirelyAtTheNewRate`,
`revokingAMutableDoseOpensAGapInferenceThenRefills`,
`anEmptyAssertionRevokesEveryLiveMutableRow`.

`reappearance` — decision 9's stop-ship — is covered store-side by
`aRevokedIdTheDriverReAssertsComesBackIntact`, so deleting
`aReappearanceIsRecorded` loses the detection and not the behaviour.

Tests that go with the code they test: the JSON-path halves of
`InsulinStorageTests` (`anIngestFailureIsSwallowedWhileJsonIsAuthoritative`,
`aFailedStoreReadFallsBackToJsonRatherThanReturningZero`,
`theCutoverReportsOffWithNoRecordStore`,
`recentPumpEventsReachesPastTheJsonLogOnceAuthoritative`) and
`InsulinPersistentStorageTests`. Check `AiInterfaceParityTests` — if it asserts
the two paths agree, it needs rewriting rather than deleting once there is one
path.

## One exposure to carry forward, not to fix here

`anOutageStillOpenAtNowInfersUnboundedScheduledBasal` pins current behaviour
rather than guarding a regression. `derive` appends `(lastBoundary.end, at)`
with no cap, so a long comms outage with no suspend infers scheduled basal for
its whole duration — ~15.8 U over 39.5 hours — and unlike the fossil it
replaced, that segment ends at `at` and is therefore inside DIA and
dosing-relevant. The clamp does not catch it: I4 withholds gaps whose left edge
is below `historyCompleteSince`, and a live outage's left edge is a real dose.

No run ever reached it — "delivery gaps longer than 24.0h: 0" was the last
`[warn]` standing after 7.1 days — and after phase 3 nothing measures it on a
device. @stateful-issue.md's open question ("the intended defense is the
`updatedAt` staleness check, and it looks like it holds... worth confirming
deliberately rather than by inspection") is still open. **Leave the behaviour
alone in phase 3** and keep the test as documentation. Capping inference or
verifying the staleness check is its own change, with its own decision about
what the right answer is when the pod may or may not still be running.

## Done when

    cd ios
    xcodebuild test -workspace MetabolicOS.xcworkspace -scheme BioKernel \
      -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
      CODE_SIGNING_ALLOWED=NO

Green, with no `InsulinStoreVerifier`, `InsulinVerifierDatabase`, `eventLog`, or
`useRecordStoreForDosing` left in `ios/BioKernel/BioKernel/`. Then:

- Add a closing note to @dev/interpreting_verification_results.md saying the
  verifier is gone and the document is history rather than an operational
  guide — it is the only record of what the six runs established, so it should
  not be deleted with the code.
- Mark §7.5 done in @dev/backlog/insulin-storage-grdb.md.

## Out of scope

§7.5 lists the things phase 3 *enables* — a single derivation for
`AddedGlucoseDataFrame`, wide-window queries, total daily dose. Those are
features that want the store authoritative, not part of the deletion. Same for
the trailing-segment cap above. Land the deletion first, on its own.
