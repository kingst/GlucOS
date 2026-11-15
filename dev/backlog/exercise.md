# Exercise — a timed target raise

Scope for the "exercise" settings automation. Ground truth for the code
references below is `main` at fb4b947. This is the second timed target
override; it reuses everything @dev/backlog/meal-soon.md built, so this doc
records only what differs and the decisions behind it.

The requirement, as first written:

> Exercise is similar to "meal soon" except it (1) raises the glucose target
> by 50 mg/dl and the amount of time it stays on is adjustable by the user
> (the default is 2h). Note meal soon and exercise can't be both active, so
> the later setting wins. So if it is in "meal soon" mode and exercise is set,
> it goes into exercise and vice versa.

## 1. What changes, in one sentence

`TargetOverrideKind` gains `.exercise` and `TargetGlucoseSource` gains
`.exercise`, the override rule becomes `TargetOverridePolicy.status` with the
manual-bolus step gated on the kind, `TargetGlucoseService` gains
`startExercise(at:duration:settings:)` and its meal-soon-named members become
`cancelOverride` / `activeOverride`, and the Settings automation screen, the
banner, the settings home row and the chart learn the second kind. The store
schema does not change.

## 2. The rule

```swift
enum ExercisePolicy {
    static let raiseMgDl = 50.0
    static let defaultDuration: TimeInterval = 2.hoursToSeconds()
    static let durations: [TimeInterval]   // 30m, 1h, 1h30, 2h, 3h, 4h
    static func target(settingsTargetMgDl: Double) -> Double
}
```

**The clamp runs before the raise, not after** (decision 1). The service
clamps every target to [70, 140]. Meal soon clamps *after* its drop, which is
harmless because the drop moves away from the ceiling. Applying the same
order to a raise would collapse "+50" into "140" for any settings target of
90 or more. So `ExercisePolicy.target` clamps the settings target itself and
adds 50, and the service does not clamp the result again. With the settings
picker's 80...140 range the override lands in 130...190.

**Exercise does not end on a manual bolus** (decision 4). A snack bolus during
a long workout should not drop the raised target. `TargetOverrideKind
.endsOnManualBolus` is true for meal soon and false for exercise;
`TargetOverridePolicy.status` skips the bolus step for a kind that does not
end on one, and `activeOverride` does not read pump events for it at all.
Exercise ends on the clock or a cancel, nothing else.

## 3. One open row: the later setting wins

Already true of the store. `startTargetOverride` closes whatever is open as
`.cancelled` in the same transaction before inserting, regardless of kind
(@ios/BioKernel/BioKernel/Services/GRDBLoopRecordStore.swift:803). Starting
exercise while meal soon is open cancels meal soon; starting meal soon while
exercise is open cancels exercise; the log shows both. Nothing new had to be
written to get this — it is the reason the table had a `kind` column.

## 4. Duration

**Nothing is remembered between starts** (decision 2). The Settings automation
screen has a Duration picker beside the Exercise switch that shows 2 hours
every time exercise is off. Turning the switch on starts exercise for the
picker's value. No `CodableSettings` field, no `UserDefaults` key: the running
row's `expires_at` is the only place the chosen duration lives, and it is a
record of that run, not a preference.

**Changing the duration while exercise is on restarts it from now** (decision
3). The picker mirrors the running row's duration; picking a different value
calls `startExercise` again, which supersedes: the old row closes as
`.cancelled` and a fresh one runs the full new duration from the change. "Ends
at" moves accordingly. This is the same mechanism as supersession between
kinds, so there is one way a row ends early from the UI.

`TargetOverride.duration` is `expiresAt - startedAt` rounded to the second,
because both ends went through the store as epoch-second doubles and the
picker compares it against its fixed choices. If some other writer ever
stores a duration that is not one of the choices, the picker snaps to the
nearest and that snap does not restart the row.

## 5. UI

- **Settings automation** (`SettingsAutomationView`): a second section,
  "Exercise", with the switch, the Duration picker, and "Ends at HH:mm" while
  running. Its footer states the target it raises to, the duration, the
  restart-on-change rule, and that the two switches are exclusive. Both
  switches mirror the one published override, so turning one on visibly
  turns the other off.
- **Banner** (`MainViewTargetOverrideView`, renamed from
  `MainViewMealSoonView`): "Exercising, raise target to X" / "until HH:mm",
  teal, in the same slot under the summary and any alert. Tap opens the
  automation screen.
- **Settings home row**: "Meal soon" / "Exercise" / "Off".
- **Glucose chart**: a third step-line series, "Exercise", in teal, over the
  ticks whose source is `.exercise`. A meal soon superseded by an exercise
  draws as two segments.
- `AppColors.teal` is new. `TargetOverrideKind.title` and `.color` live in
  the banner's file and are what the row, the chart legend and the banner
  all use.

## 6. Safety interactions

Exercise moves the target the safe way, so every consumer gets gentler:

- **PID.** Error = glucose − target drops by 50 for the duration; the
  integrator accumulates less. No `PIDState` reset, same as meal soon.
- **Micro-bolus gate** opens at target + 20, so at 190 on the default
  settings target instead of 110. Fewer micro-boluses.
- **ML** dynamic-ISF scaling grows with glucose − target, so it scales less.
- **The shutoff does not move.** Unchanged, and now further below the target.
- **Fail directions** are the same as meal soon: no store, a failing read, or
  no open row → the settings target. A non-positive duration is rejected
  before anything is written.

## 7. Tests

- `ExercisePolicyTests` (new file, registered in the project): target at 90,
  80, 120, 140; clamp-before-raise at 200 and 60; default duration and
  choices; active before expiry, expired at it; a manual bolus does not end
  it; a closed row returns its reason; `duration` rounds; source ↔ kind.
- `MealSoonPolicyTests`: `MealSoonPolicy.status` → `TargetOverridePolicy.status`.
- `TargetGlucoseServiceTests`: exercise raises for the chosen duration and
  expires on the clock; not capped at 140; a manual bolus does not end it;
  the later of meal soon and exercise wins, both ways; starting again
  restarts from now with the new duration; cancel; non-positive duration
  throws; no store throws.
- `LoopRecordStoreTests`: an exercise row round-trips its kind and supersedes
  an open meal soon.
- `ClosedLoopTests`: the pipeline test runs a third time with `.exercise` and
  checks the PID error moves by −50 and the row records 140 / `exercise`.

## 8. Decisions

Confirmed 2026-10-25:

1. **Ceiling:** clamp the settings target to [70, 140] first, then +50. The
   service does not clamp exercise again.
2. **Duration:** chosen on every start from a picker that always shows 2h;
   nothing is remembered.
3. **Mid-run change:** restarts from now with the new duration, via
   supersession.
4. **Manual bolus:** does not end exercise.

Carried over from meal soon without change: no FaceID, no `CodableSettings`
field, state and log in `target_override`, the override tracks the current
settings target per tick, nothing on the watch.
