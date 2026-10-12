# AI Interface — implementation scope

Companion to @dev/ai-interface.md, which is the requirements doc. This
doc is the "how" — what exists today, what has to be built, and where
it plugs into the current code. The open questions in §10 all carry a
recommendation, so this is implementable as written.

Ground truth for the code references below is branch `ai-interface` at
commit 9b3a951.

## 1. What we're building

**The GlucOS writer half only.** GlucOS publishes its insulin delivery
history into an app-group container as `current_insulin_dosing.json`
plus daily `finalized_insulin_dosing.<UTC_DAY>.jsonl` files, with
scheduled basal and pump suspension already normalized into explicit
basal records.

Ingesting `meal_announcements.<UTC_DAY>.jsonl` from AI apps is
deferred to a later spec, and nothing here depends on it. The file
layout below still shows the `ai/` subtree because the container is
shared, but GlucOS does not write it in this phase.

Update: a display-only reader has since been built on top of this work
— `MealAnnouncementStorage` plus the `MainViewMealBannerView` banner,
described in @dev/ai-interface.md. It reads `ai/<bundle.id>/` and shows
what an AI announced next to what the pump actually delivered. It
changes nothing about the writer half below, and the deferred spec is
still deferred: nothing it reads reaches `ClosedLoopService`,
`SafetyService`, or the pump.

"Reader" throughout this doc means an AI app consuming what we
publish — the audience we're writing the format for, not GlucOS.

## 2. What exists today

- `LocalInsulinStorage` (@ios/BioKernel/BioKernel/Services/InsulinStorage.swift)
  is the source of truth for insulin. It stores a raw `[NewPumpEvent]`
  log in `pump_events.v2.json` and derives everything on demand:
  - `deduplicatedDoses(events:at:)` (line 261) collapses the log by
    `syncIdentifier`, preferring immutable doses over mutable ones.
  - `inferBasalDoses(doses:at:)` (line 286) synthesizes scheduled-basal
    `DoseEntry`s for the gaps between temp basals, skipping gaps that
    follow a `.suspend`. This is exactly the abstraction the AI
    interface needs — but it is computed per query and never persisted.
  - `createBasalDose` (line 342) uses
    `settings.pumpBasalRateUnitsPerHour` for the inferred rate.
  - The event log is **trimmed to 24 hours** on every write
    (`logRetentionTimeInterval`, line 93; `syncDataToDisk`, line 221).
    Nothing in GlucOS retains 90 days of anything today.
- `DiagnosticViewModel` (@ios/BioKernel/BioKernel/ViewModels/DiagnosticViewModel.swift:90)
  already reconstructs a bolus/basal/suspend/resume timeline from the
  same event stream for the Pump view. The writer needs a strictly
  more careful version of this logic; the two should share code rather
  than drift.
- `InsulinStorage.registerForPumpEntryUpdates(delegate:)` supports
  **exactly one** observer (`weak var updateDelegate`, line 97), and
  `DiagnosticViewModel` already claims it. Adding the exporter as a
  second observer requires changing that to a list.
- File protection is already handled the way this feature needs:
  `StoredJsonObject.write` uses `[.atomic, .noFileProtection]`
  (@ios/BioKernel/BioKernel/ExtensionsAndUtils/StoredJsonObject.swift:87),
  and `AppComposition.migrateExistingFilesToNoFileProtection()`
  (@ios/BioKernel/BioKernel/DependencyInjection/AppComposition.swift:187)
  downgrades leftovers. Neither covers directories or the app-group
  container.
- **There is no app group.** `BioKernel.entitlements` has HealthKit,
  push, and associated domains only. Bundle id is
  `com.getgrowthmetrics.BioKernel`, team `L4TQ6C2R74`.

## 3. App group — done

`BioKernel.entitlements` now carries:

```
com.apple.security.application-groups = [ group.com.getgrowthmetrics.BioKernel.AiInterface ]
```

So the container is `FileManager.default.containerURL(
forSecurityApplicationGroupIdentifier: "group.com.getgrowthmetrics.BioKernel.AiInterface")`.
That call returns `Optional` and comes back `nil` whenever the group
isn't in the signed profile, so the exporter must log once and no-op
rather than trap — a signing regression must never take insulin
delivery down with it. The identifier lives in exactly one Swift
constant next to a comment pointing at the entitlement.

Remaining non-blocking caveat: app group identifiers are registered to
one developer team, and the entitlement only validates against that
team's provisioning profile, so **two apps signed by different teams
cannot share this container.** A genuinely third-party AI app therefore
either ships under team `L4TQ6C2R74` or the user self-builds both apps
under their own team and edits the identifier in the two places above.
That's a distribution question, not an implementation one — the writer
is identical either way.

## 4. New code

New files get added to `project.pbxproj` as part of this work (Sam
lifted the usual house rule for this task). Note that only
`LauncherWidget` and the watch app use `PBXFileSystemSynchronizedRootGroup`
— the `BioKernel` and `BioKernelTests` targets still use explicit file
references, so every new file needs four hunks: a `PBXFileReference`, a
`PBXBuildFile`, an entry in its `PBXGroup` children (`Services` at
project.pbxproj:584, `BioKernelTests` at :667), and an entry in the
target's `Sources` phase. Fresh 24-hex object ids, and keep the
new-file count low to keep that surgery small.

The suggested layout:

| File | Contents |
|---|---|
| `ExtensionsAndUtils/AiInterfaceContainer.swift` | Container/path resolution, directory creation with `.protectionKey = .none`, atomic write, append, day-file enumeration, retention pruning. Root URL injectable for tests. |
| `DataTypes/AiInterfaceDataTypes.swift` | The wire structs (`FinalizedDoseRecord`, `CurrentInsulinDosing`, `CurrentBolus`, `CurrentBasal`) with explicit `CodingKeys`. |
| `Services/AiInterfaceStorage.swift` | Protocol + `actor LocalAiInterfaceStorage`: the export state machine. One method for now — `func exportInsulinDosing(at: Date) async`. |
| `Services/InsulinTimeline.swift` (or an extension on InsulinStorage) | The shared, pure dose-timeline reconstruction extracted from `LocalInsulinStorage`/`DiagnosticViewModel`. |
| `BioKernelTests/AiInterfaceTests.swift` | See §8. |

Modified:

- `InsulinStorage.swift` — multi-delegate support, and expose the
  reconciled timeline (§6).
- `DeviceDataManager+Pump.swift` — pass `smallestDeliveryUnit` through
  alongside `insulinType` (§5.3).
- `AppComposition.swift` — construct and wire the new service.

### 4.1 Build and test

The submodules are initialized (`git submodule update --init
--recursive`, done). Build the **workspace**, not the bare project:

```bash
cd ios
xcodebuild build -workspace MetabolicOS.xcworkspace -scheme BioKernel \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO

xcodebuild test -workspace MetabolicOS.xcworkspace -scheme BioKernel \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGNING_ALLOWED=NO
```

SourceKit can't resolve `LoopKit` until the workspace has been built
once, so ignore live-editor "No such module" noise and trust
`xcodebuild`.

## 5. Wire format

All timestamps are `Double` epoch seconds. Use a `JSONEncoder` with
`dateEncodingStrategy = .secondsSince1970` (matching
`StoredJsonObject`) or plain `Double` fields; do not emit ISO strings.
No `version` key (spec §"Serialization details").

### 5.1 finalized_insulin_dosing.\<UTC_DAY\>.jsonl

One JSON object per line, `\n`-terminated, appended in whatever order
records finalize:

```
{"id":"…","startTime":1754006400.0,"endTime":1754008200.0,
 "unitsDelivered":0.15,"insulinType":"humalog","smallestDeliveryUnit":0.05}
```

### 5.2 current_insulin_dosing.json

```
{"bolus":{"id":"…","startTime":…,"programmedUnits":1.5,
          "insulinType":"humalog","smallestDeliveryUnit":0.05},
 "basal":{"id":"…","startTime":…,"endTime":…,"rateInUnitsPerHour":0.3,
          "insulinType":"humalog","smallestDeliveryUnit":0.05}}
```

`bolus` is `null` when no bolus is outstanding. `basal` should always
be present once we have pump data (rate `0` while suspended); it is
`null` only before the first pump sync.

### 5.3 Field mapping from LoopKit

| Field | Source |
|---|---|
| `id` | `dose.syncIdentifier`, namespaced (§7.4). Synthetic for inferred segments. |
| `startTime` / `endTime` | `dose.startDate` / `dose.endDate` |
| `unitsDelivered` | `dose.deliveredUnits ?? dose.programmedUnits` (same fallback `insulinDeliveredForSegment` uses, InsulinStorage.swift:506) |
| `programmedUnits` | `dose.programmedUnits` |
| `rateInUnitsPerHour` | `dose.unitsPerHour` |
| `insulinType` | **Do not use LoopKit's `Codable`** — `InsulinType` is `enum InsulinType: Int, Codable`, so it encodes as `0…5`. Write our own exhaustive `String` mapping (`novolog`, `humalog`, `apidra`, `fiasp`, `lyumjev`, `afrezza`). |
| `smallestDeliveryUnit` | Smallest positive value of `pumpManager.supportedBolusVolumes` (0.05 U on Omnipod), defaulting to 0.05 when unknown. |

`InsulinStorage` has no pump handle, so `smallestDeliveryUnit` has to
be plumbed the same way `insulinType` already is: read it in
`MosPumpManagerDelegate.pumpManager(_:hasNewPumpEvents:…)`
(@ios/BioKernel/BioKernel/LoopKitSupport/DeviceDataManager+Pump.swift:28)
and pass it down. It must be captured **per record at write time** and
persisted as "last known" so the value survives a restart with no pump
connected — pumps and insulins change over a history, and the record is
the only place that pairing is preserved.

## 6. The hard part: building the finalized timeline

Everything else is plumbing. This is the piece to get right.

### 6.1 Reconstruct

Per export pass, at time `now`:

1. Reconcile the event log by `syncIdentifier`, immutable winning over
   mutable — `deduplicatedDoses` (InsulinStorage.swift:261) already
   does this.
2. Split into boluses, temp basals, and suspend/resume events.
3. Build a **gapless basal timeline** over the exported window:
   - a temp basal covers `[startDate, endDate)` at `dose.unitsPerHour`;
   - a suspension covers `[suspend, resume)` at **rate 0** — this is
     the "abstract away suspension" requirement, and it is the one
     place the exporter must do *more* than `inferBasalDoses`, which
     today just emits nothing for suspended stretches
     (InsulinStorage.swift:286-305);
   - every remaining gap is scheduled basal at the rate in effect at
     the gap's start.

**Use `settings.pumpBasalRateUnitsPerHour` for the scheduled rate**, to
match `createBasalDose` (InsulinStorage.swift:349), so exported records
sum to the same IoB GlucOS computes internally. Note the existing
inconsistency: the dosing algorithm uses
`settings.learnedBasalRate(at:)` (ClosedLoopDataTypes.swift:314) while
IoB inference uses the flat pump rate. Don't fix that here; just
document which one the export follows.

### 6.2 Finalize

A record may be appended to a daily file **only when it can never
change again**:

- **Bolus** — finalize when the dose is immutable (`!dose.isMutable`).
  A mutable/running bolus stays in `current.bolus`. A bolus that has
  finished but hasn't gone immutable yet also stays in `current.bolus`
  — the reader's algorithm treats a current bolus as fully delivered at
  `startTime`, which is the conservative direction.
- **Basal segment** — finalize only when *both* boundaries are fixed:
  the dose (or suspend/resume event) that starts it and the one that
  ends it are immutable, and the segment's end is in the past. A
  segment bounded on the right by a still-mutable temp basal must wait,
  because when that temp basal finalizes its `endDate` can move and the
  inferred segment before it would silently change.
- The **last** segment of the timeline (always covering `now`, since we
  infer scheduled basal up to `now`) is `current.basal`, never
  finalized.
- If more than one unfinalized bolus somehow exists, finalize the older
  ones with `deliveredUnits ?? programmedUnits` and log it.

### 6.3 Idempotency

The daily files are append-only and the app restarts, so the exporter
needs its own private state in the documents directory (not the shared
container) — e.g. `ai_export_state.json`:

```swift
struct AiExportState: Codable {
    let exportedIds: [String: Double]   // id -> epoch seconds appended
    let lastSmallestDeliveryUnit: Double?
    let lastInsulinType: String?
}
```

Prune `exportedIds` at ~7 days — comfortably past the 24-hour pump-event
log, so a pruned id can never come back. Nothing is ever appended twice
because appends are gated on this set.

Known gap to document, not solve: if the app is dead for more than 24
hours, pump events age out of `pump_events.v2.json` before they can be
exported. On relaunch the pump manager only backfills 24 hours
(`startDateToFilterNewPumpEvents`, DeviceDataManager+Pump.swift:184).
Those doses will never reach a finalized file.

### 6.4 Write order

Per pass: **append the newly finalized records first, then rewrite
`current_insulin_dosing.json`.** A reader landing between the two sees
a record in both files; the spec guarantees the id is stable across the
move, so a reader that unions and dedupes by id is unaffected, and one
that doesn't will over-count IoB for a few milliseconds — the safe
direction. Doing it the other way round can under-count, which makes an
AI dose more.

### 6.5 When to export

- On every `addPumpEvents` (InsulinStorage.swift:135) — i.e. every pump
  sync and after every enact, roughly every 5 minutes.
- Once at launch after the first `readFromDisk`.
- On UTC day rollover, to run retention (§7.3). Piggy-backing on the
  next export pass and comparing the current day string is enough; no
  timer needed.

No timer is needed to keep `current_insulin_dosing.json` fresh: it
carries `endTime`, and readers clamp with `min(now, endTime)`.

## 7. File-system mechanics

### 7.1 Layout

```
<group container>/AiInterface/
  GlucOS/
    current_insulin_dosing.json
    finalized_insulin_dosing.<UTC_DAY>.jsonl
  ai/<bundle.id>/                             <- not this phase
    meal_announcements.<UTC_DAY>.jsonl
```

GlucOS owns `AiInterface/GlucOS/` and touches nothing else.

`<UTC_DAY>` is `YYYY-MM-DD` from a `DateFormatter` pinned to
`TimeZone(identifier: "UTC")` and `Locale(identifier: "en_US_POSIX")`,
computed **at append time**, never from the record's own timestamps.

### 7.2 Protection

Everything is `NSFileProtectionNone` — the app runs before first unlock
on CGM/pump wake.

- Directories: `FileManager.createDirectory(at:withIntermediateDirectories:attributes:
  [.protectionKey: FileProtectionType.none])`, applied to
  `AiInterface/` and `AiInterface/GlucOS/`.
- `current_insulin_dosing.json`: `data.write(to:options:[.atomic, .noFileProtection])`.
  `.atomic` writes a temp file and renames; the protection option is
  applied before the rename, which is the "set it on rename" case the
  spec calls out. This is the same pattern `StoredJsonObject` uses.
- Daily files: create with
  `FileManager.createFile(atPath:contents:attributes:[.protectionKey: FileProtectionType.none])`,
  then append via `FileHandle.seekToEnd` + a **single** `write` of the
  complete `line + "\n"`, to keep torn writes as unlikely as possible.
- Belt and braces: re-assert `.protectionKey` on the container tree at
  launch, the way `migrateExistingFilesToNoFileProtection` does for the
  documents directory.

### 7.3 Retention

- GlucOS deletes its own `finalized_insulin_dosing.*.jsonl` older than
  90 UTC days. Parse the day out of the filename; don't stat.
- GlucOS **never** deletes or rewrites anything outside
  `AiInterface/GlucOS/` — single-writer rule.
- Run pruning at most once per day (§6.5).

### 7.4 IDs

`syncIdentifier` is assigned by the pump driver and is only guaranteed
unique within a pod's history, so prefix it to be safe:
`"<pluginIdentifier>:<syncIdentifier>"`. Inferred segments have no
`syncIdentifier`; synthesize a deterministic one such as
`"glucos:basal:<startTime as integer milliseconds>"` so a re-derived
timeline produces the same id and the `exportedIds` set stays
meaningful. Ids must never be regenerated randomly.

## 8. Testing

The exporter's root URL must be injectable — unit tests can't get a
real app-group container — so `AiInterfaceContainer` takes a base URL
and tests point it at a temp directory.

- Timeline: temp basals, gaps → scheduled basal, suspend → rate-0
  record, resume, back-to-back temp basals, a temp basal that ends
  early, mutable→immutable transitions.
- Finalization: nothing finalizes while a boundary dose is mutable;
  running bolus appears in `current` and moves to finalized with the
  same id; canceled bolus finalizes with actual `deliveredUnits`.
- Idempotency: run the exporter twice over the same log, and across a
  simulated relaunch (reload the state file) — zero duplicate lines.
- Day rollover: records appended after midnight UTC land in the new
  file even when their `startTime` is in the previous day; 91-day-old
  files are deleted and 89-day-old ones are not.
- Protection: assert `.protectionKey == .none` on every created file
  and directory.
- Every appended line ends in `\n` and parses standalone; a file
  truncated mid-line still yields every complete record before it.
- **Parity test (the valuable one):** run the reader-side IoB algorithm
  from @dev/ai-interface.md §"Suggested IoB algorithm" over the
  exported records and compare against
  `insulinStorage.insulinOnBoard(at:)` for the replay logs in
  `BioKernelTests/Resources/`. If those two disagree, the export is
  wrong. Expect a tolerance: GlucOS quantizes into 5-minute buckets
  (`insulinDeliveryQuantized`, InsulinStorage.swift:445) while the
  suggested algorithm discretizes by `smallestDeliveryUnit`.

## 9. Phasing and effort

| Phase | Work | Rough size |
|---|---|---|
| 0 | App group entitlement. **Done** (§3). Sam still needs to confirm the profile/Xcode Cloud signs with the new entitlement on a real build. | done |
| 1 | `AiInterfaceContainer` + wire structs + timeline extraction + exporter + state file + tests. | the bulk — 1–2 days |
| 2 | Multi-delegate `InsulinStorage`, `AppComposition` wiring, launch/rollover triggers. | ~half a day |
| 3 | A diagnostic view showing what we published (mirrors `PumpHistoryView`), plus the IoB parity test. | ~half a day |

Meal-announcement ingestion and anything that feeds AI input into
dosing is a separate spec, written after this ships.

### 9.1 Definition of done

- `xcodebuild build` and `xcodebuild test` both green (§4.1), with the
  pre-existing tests still passing — the timeline extraction touches
  the IoB path, so `InsulinOnBoardTests` / `InsulinStorageTests` /
  `LoopFunctionTests` are the regression net.
- New tests from §8 present and passing, including the IoB parity test.
- No forced unwraps anywhere in the new code.
- A missing/`nil` group container, a full disk, or a `FileHandle`
  failure degrades to a logged no-op; nothing in the export path can
  throw into or block the loop.
- Every file and directory GlucOS creates in the container reports
  `.protectionKey == .none`.
- Nothing outside `AiInterface/GlucOS/` is created, written, or deleted.
- No commits — Sam reviews the working tree (standing house rule).

## 10. Open questions

Each has a recommendation attached; implementation follows the
recommendation unless Sam says otherwise, so none of these block a
start.

1. **Scheduled basal rate source** (§6.1). The export can follow
   `pumpBasalRateUnitsPerHour` (what `createBasalDose` uses for IoB,
   InsulinStorage.swift:349) or `learnedBasalRate(at:)` (what the
   dosing algorithm uses, ClosedLoopDataTypes.swift:314). These already
   disagree with each other in the shipping code.
   *Recommendation: `pumpBasalRateUnitsPerHour`, so an AI's IoB
   reconciles with GlucOS's own.*

Definitely use `pumpBasalRateUnitsPerHour` we're recording insulin
records and this is what's running on the pump when we don't have temp
basal records

2. **Staleness signal** (§5.2). The format has no "written at" field,
   so a reader can't tell "GlucOS is idle" from "GlucOS is dead" or a
   pump that fell off Bluetooth.
   *Recommendation: add one top-level `updatedAt` to
   `current_insulin_dosing.json`. One key, no versioning, and it's the
   difference between an AI trusting stale basal data and knowing not
   to.*

Do it. Update the interface spec also please

3. **`smallestDeliveryUnit` derivation** (§5.3). Smallest positive
   entry of `supportedBolusVolumes`, or a separate increment for basal
   from `supportedBasalRates`? Both are 0.05 on Omnipod, so nothing
   observable changes today.
   *Recommendation: smallest positive `supportedBolusVolumes`, 0.05
   fallback, one value per record.*

Yes

4. **User-facing switch.** A settings toggle for publishing, or always
   on once shipped?
   *Recommendation: always on. The container is team-scoped so there's
   no third-party exposure to gate, and a toggle adds a settings
   migration plus a "why is my AI app blind" support path. Easy to add
   later if third-party distribution ever happens.*

Yes, always on

5. **The >24h-downtime gap** (§6.3). Pump events age out of
   `pump_events.v2.json` after 24 hours and the pump only backfills 24
   hours, so doses delivered while the app was dead longer than that
   never reach a finalized file.
   *Recommendation: accept and document it. Backfilling from HealthKit
   would mean a second, differently-shaped source of truth for
   delivered insulin, which is a bigger change than this feature.*

Yes, accept and document

6. **Retention of the export ledger vs. the daily files.** GlucOS keeps
   90 days of `finalized_insulin_dosing.*`, but `exportedIds` only
   needs ~7 days (§6.3). Confirm you're happy with the asymmetry — it
   means a hand-deleted daily file will never be regenerated.
   *Recommendation: yes, keep the ledger small. The files are the
   published artifact; the ledger is just dedup state.*

Yes this is fine

## 11. Out of scope

- **Meal announcements** — anything that lets AI input reach dosing.
  Later spec. Note when we get there: nothing in the loop models carbs
  or meals today, so `unitsForMeal` has no existing path into
  `ClosedLoopService`, and giving it one changes the safety story.
  (Reading `ai/<bundle.id>/meal_announcements.*` was out of scope here
  too, and has since been built as a display-only banner — see §1.)
- Any change to the dosing algorithm, `SafetyService`, or the loop.
- Glucose, settings, or device-status export. The requirements doc
  covers insulin only on the GlucOS side.
- Versioning of the on-disk format (spec: missing version implies v=1).
- Reader-side helper libraries or sample AI apps.
- Watch app and `LauncherWidget` — neither needs the group.
