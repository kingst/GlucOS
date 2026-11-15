# More settings automation

The BioKernel already has two settings automations: Eating soon and
exercise. Currently these only adjust target glucose. We will add new
automations and add the ability to scale basal rates and insulin
sensitivity.

## Scaling basal rates and insulin sensitivity

We will introduce a DosingOverride to adjust basal rates and
sensitivity temporarily via our settings automations. Within the
DosingOverride there is a value called the `dosingMultiplier`, which
is used as follows:

basalRateMultiplier          = dosingMultiplier
insulinSensitivityMultiplier = 1 / dosingMultiplier

effectiveBasalRate          = basalRate * basalRateMultiplier
effectiveInsulinSensitivity = insulinSensitivity * insulinSensitivityMultiplier

So in other words, a dosingMultiplier > 1 means more insulin, and < 1
means less insulin.

## Changes to exercise automation

Our current exercise automation will become our "exercise soon"
setting. Although the name UI text should change to reflect the
expected use, it should still do the exact same thing.

## New settings

We will add a "Digestion" setting, an "Exercise" setting, and a "Post
exercise" setting.

Digestion:

  * dosingMultiplier: 1.3
  * ends: timing default 2h, up to 3h and as little as 30m

Exercise:

  * targetGlucose: therapyTargetGlucose + 50 (or whatever we use for
    the exercise adjustment currently)
  
  * dosingMultiplier: 0.6
  * ends: timing default 1h up to 3h and as little as 30m

Post Exercise:

  * dosingMultiplier: 0.8
  * ends: timing, default 30m up to 90m, 30m is min

## Decisions

Confirmed 2026-11-13. These settle what the sections above leave open.
"Meal soon" is the setting the introduction calls "Eating soon"; it is
the name the app and the code use.

Two were revised on 2026-11-14, after the first implementation was
reviewed: what the dosing multiplier applies to, and how the glucose
chart draws a target override. Both are marked where they appear.

Two more were revised on 2026-11-15: meal soon has a duration picker,
and the Settings automation screen has a status section in place of
the per-setting descriptions. Both are marked where they appear.

Later on 2026-11-15 @dev/backlog/override-mechanism.md split the
override manager from the settings. It supersedes three things here,
each marked where it appears: a manual bolus no longer ends meal soon,
what the target source of a tick is, and the dosing override flag.

### The five settings

| Setting | Kind in code | Target | `dosingMultiplier` | Default | Duration choices |
|---|---|---|---|---|---|
| Meal soon | `mealSoon` | settings target - 15, floor 75 | none | 60m | 30m to 2h, 30m steps |
| Digestion | `digestion` | unchanged | 1.3 | 2h | 30m to 3h, 30m steps |
| Exercise soon | `exerciseSoon` | settings target + 50 | none | 2h | 30m, 1h, 1h30, 2h, 3h, 4h |
| Exercise | `exercise` | settings target + 50 | 0.6 | 1h | 30m to 3h, 30m steps |
| Post exercise | `postExercise` | unchanged | 0.8 | 30m | 30m, 1h, 1h30 |

  * Meal soon and exercise soon do exactly what meal soon and exercise
    do today. Exercise soon keeps its picker, including the 4h
    maximum.
  * Revised 2026-11-15: meal soon has a duration picker like the other
    four, where it was fixed at 60m. Its default is still 60m, so a
    start that leaves the picker alone does what it did. The lowered
    target can now run for up to 2h. Where @dev/backlog/meal-soon.md
    says "60 minutes" or "an hour" as a bound, the bound is the picked
    duration; nothing else in its safety section depends on the
    duration, and a manual bolus still ends it. Superseded 2026-11-15
    by @dev/backlog/override-mechanism.md, "Ending is on the clock":
    a manual bolus no longer ends it, and meal soon runs until its
    duration is up or it is turned off.
  * The Exercise target uses the same rule exercise soon uses: clamp
    the settings target to [70, 140], then add 50
    (`ExercisePolicy.target`).
  * Exercise is the one setting that carries both a target and a
    dosing multiplier.

### One setting at a time

  * All five settings are mutually exclusive. There is one open
    override row, as today: starting any setting closes whatever is
    open as cancelled, so the later setting wins.
  * Nothing chains automatically. Meal soon ending does not start
    digestion, and exercise ending does not start post exercise. Every
    start is manual.
  * Only meal soon ends on a manual bolus. The other four end on the
    clock or on a cancel. Superseded 2026-11-15 by
    @dev/backlog/override-mechanism.md, "Ending is on the clock": all
    five end on the clock or on a cancel, and nothing ends on a bolus.

### Names and stored rows

  * In code the existing `exercise` kind becomes `exerciseSoon`, and
    the new Exercise setting takes `exercise`.
  * No migration of existing rows; keep the code simple. Rows already
    stored as `exercise` will read as the new Exercise setting, and an
    exercise override that is open at the moment of the upgrade picks
    up the 0.6 multiplier for its remaining time. Both are accepted.

### Where the dosing multiplier applies

Revised 2026-11-14. The first version also scaled the integrator input
and the biological invariant. They are back on the settings values.

The multiplier changes how much we dose. It is not treated as a
measured change in how the person responds to insulin. The adjusted
values come from AIs, so they might represent a real change, but we do
not assume they do. We use them to tweak the dosing policy, and
whatever checks glucose against the model stays on the settings.

So the multiplier scales the basal rate and insulin sensitivity that
the PID controller (`PhysiologicalModels.tempBasal`) sizes its dose
with, and nothing else:

  * the basal baseline of insulin on board,
  * the conversion of the PID output into insulin, and
  * the basal rate added back to the correction.

The ML dynamic ISF scales the PID's temp basal, so it follows without
a change of its own.

Everything else stays on the unscaled settings:

  * The integrator input and the biological invariant
    (`PhysiologicalModels.deltaGlucoseError`). "Safety interactions"
    below has what scaling them would have done.
  * The safety bound in `SafetyService`, which is computed from
    `maxBasalRate()`.
  * The guardrail clamp and the micro-bolus cap, which use
    `maxBasalRateUnitsPerHour`.
  * The meal dose recommendation, both the cold-start dose and the
    adjustment step between less, usual and more.
  * The added-glucose estimate behind the digestion gauge
    (`addedGlucosePerHour30m`). The gauge's baseline, basal rate times
    insulin sensitivity, is the same with or without the multiplier.

Because `maxBasalRate()` and `deltaGlucoseError` are computed from the
same settings, the multiplier cannot be applied by handing the
pipeline a scaled copy of the settings. It travels alongside the
settings to the PID.

### What each tick records

The existing fields always hold the values from the settings. The
values an override put in their place are recorded beside them, only
while that override is on.

| Field | Holds | `loop_result` column |
|---|---|---|
| Target | settings target, every tick | `target_mg_dl`, existing |
| Target source | `settings`, `mealSoon`, `exerciseSoon` or `exercise` | `target_source`, existing |
| Override target | the target the tick dosed toward, only while a target override is on | `override_target_mg_dl`, new |
| Basal rate | settings value, every tick | `basal_rate`, existing |
| Insulin sensitivity | settings value, every tick | `insulin_sensitivity`, existing |
| Dosing override enabled | whether a dosing override is on | `dosing_override_enabled`, new |
| `overrideBasalRate` | scaled basal rate, only while a dosing override is on | `override_basal_rate`, new |
| `overrideInsulinSensitivity` | scaled sensitivity, only while a dosing override is on | `override_insulin_sensitivity`, new |

  * "Settings target" is what the tick would have dosed toward with no
    override, so it is the value after the service's [70, 140] clamp,
    as it is on a `settings` tick today.
  * Target source stays as the variable that says whether a target
    override is on, and which one: anything other than `settings`
    means one is. The chart needs the kind to colour the segments.
    Digestion and post exercise do not move the target, so their ticks
    record `settings` as the target source. Superseded 2026-11-15 by
    @dev/backlog/override-mechanism.md, "What each tick records". The
    Target source and Dosing override enabled rows of the table above
    are no longer fields any writer sets. A tick records the policy
    identifier of the override in effect in a new column,
    `override_policy`, on a Digestion or Post exercise tick too. The
    `target_source` column keeps the values in the table, with any
    policy identifier in place of the three names, and it and
    `dosing_override_enabled` are derived from the other values when
    the row is written.
  * The new columns are added to `loop_result` the way
    `v2-target-override` added `target_mg_dl`: `ALTER TABLE ... ADD
    COLUMN`, NULL on rows written before. A NULL in
    `dosing_override_enabled` reads as off.
  * This changes what the existing target column means. Today it holds
    the target the tick dosed toward, override included. Override
    ticks written before the change keep that value and will read as
    the settings target. Accepted; we do not care about the old rows.
  * On the glucose chart the target line shows one target at a time.
    It is grey at the settings target, and while a target override is
    on the grey line stops and a coloured segment is drawn at the
    override target in its place. Revised 2026-11-14: the first
    version kept the grey line going underneath, so both were visible
    during an override. The stored row still holds both targets.

### UI

The UI follows what meal soon and exercise have today.

  * The Settings automation screen opens with a Status section that
    says what is in effect now, in four rows that are always there:
    which setting is running ("None" with nothing on), the dosing
    multiplier ("1x" with nothing scaling the dose), the target
    glucose the loop is dosing toward, and the time remaining in whole
    minutes, rounded up ("-" with nothing on).
  * Under it there is one section per setting, in this order: Meal
    soon, Digestion, Exercise soon, Exercise, Post exercise. Each has
    a switch and a Duration picker, and nothing else.
  * Revised 2026-11-15: the first version had no Status section. Each
    setting's section had a header, a footer describing what the
    setting does and an "Ends at" row while it was on, and meal soon
    had no picker.
  * The Duration pickers behave like the exercise one does today: they
    show the default whenever the setting is off, nothing is
    remembered between starts, and changing the duration while the
    setting is on restarts it from now.
  * The banner on the main view and the row on the settings home
    screen name whichever setting is on. The banner is one line, the
    setting and when it ends ("Meal happening soon, ends at 8:17 AM"),
    and tapping it opens the Settings automation screen, which has the
    details. Revised 2026-11-15: the first version was two lines and
    also gave the target and the dosing multiplier.
  * The glucose chart draws a coloured segment for the settings that
    move the target: meal soon, exercise soon and exercise. Digestion
    and post exercise do not move the target, so they have no segment.
  * Banner wording and colours for the three new settings are left to
    the implementation.

## Implementation notes

Not decisions: this is what the decisions above touch, written down so
the work can start from a cold read. Code references are to `release`
at 146c32e. @dev/backlog/meal-soon.md and @dev/backlog/exercise.md
describe the override machinery this builds on.

### How it works today

  * `TargetOverrideKind` (`mealSoon`, `exercise`) and the pure rules
    live in `DataTypes/TargetOverride.swift`. One `target_override`
    row is open at a time; `startTargetOverride` closes whatever is
    open in the same transaction (`GRDBLoopRecordStore.swift:809`).
  * `DosingPipeline.run` (`ClosedLoopDataTypes.swift:345`) reads the
    target once per tick from `TargetGlucoseService.targetGlucose` and
    hands it to the PID, the ML and the micro-bolus gate.
  * The PID and `deltaGlucoseError` read the basal rate and insulin
    sensitivity themselves, from `settings.learnedBasalRate(at:)` and
    `settings.learnedInsulinSensitivity(at:)`
    (`PhysiologicalModels.swift:174` and `:202`). `tempBasal` calls
    `deltaGlucoseError`, and the pipeline calls it again for the
    biological invariant.

### What changes, by file

  * `DataTypes/TargetOverride.swift`: the five kinds, in the UI order
    above; `DosingOverride` with `dosingMultiplier` and the two
    derived multipliers; the numbers in the table above (target rule,
    multiplier, default duration, duration choices) and
    `endsOnManualBolus`, which stays true only for meal soon.
    `TargetGlucoseSource` gains `exerciseSoon`.
  * `Services/TargetGlucoseService.swift`: starting any of the five
    kinds, and a per-tick answer that carries the dosing override with
    the target. Keep it to one read of the open row per tick, so the
    target and the multiplier always come from the same row. The fail
    directions extend the existing ones: no store, a failing read or
    no open row means the settings target and no dosing override. A
    multiplier that is not greater than zero is treated as no dosing
    override rather than divided by.
  * `Services/PhysiologicalModels.swift`: `tempBasal` takes the basal
    rate and insulin sensitivity to dose with, instead of reading the
    schedule itself, and uses them for its basal baseline, its
    conversion of the PID output into insulin and the basal rate it
    adds back. `deltaGlucoseError` does not change: it keeps reading
    the settings values, both for the integrator input inside
    `tempBasal` and for the biological invariant.
  * `DataTypes/ClosedLoopDataTypes.swift`: `DosingPipeline.run` keeps
    reading the settings values (they are what is recorded, and what
    `addedGlucosePerHour30m` uses), scales them when a dosing override
    is on, hands the scaled pair to the PID only, and fills the new
    `PipelineOutputs` fields.
    `PipelineOutputs` has a hand-written decoder so that a replay
    fixture without `targetSource` still decodes; the new fields need
    the same `decodeIfPresent` treatment.
  * `DataTypes/LoopRecord.swift` and
    `Services/GRDBLoopRecordStore.swift`: the four new fields on
    `LoopRecordSnapshot` and `LoopResultRow`, a `v3` migration beside
    `v2-target-override`, and the override target added to the
    `filteredGlucose(since:)` query. The `target_override` table does
    not change; its `kind` column is text.
  * `Services/ClosedLoopService.swift`: `FilteredGlucose` carries the
    override target for the chart.
  * `Views/SettingsAutomationView.swift`: five sections. Today it has
    one `@State` switch per kind and one duration; it needs the same
    mirroring of the published override for each of the five. The
    Status section above them reads the same published override. Its
    target is computed in the view from `MealSoonPolicy.target`,
    `ExercisePolicy.target` and the service's clamp, the way the
    service does it, and the screen re-renders on a clock so the time
    remaining counts down and a switch drops when its setting runs
    out.
  * `Views/MainViewTargetOverrideView.swift`: `TargetOverrideKind
    .title` and `.color` for the three new kinds, and the banner text.
    `SettingsHomeView` shows `kind.title` and follows.
  * `Views/GlucoseChartView.swift`: one target line, built in a single
    pass. A tick with no target override plots the settings target in
    grey, and a tick with one plots the override target in that kind's
    colour instead. Each run of one colour is carried forward to the
    first tick of the next run, so the segments meet and a one-tick
    override still draws. `chartForegroundStyleScale` lists the kinds
    that move the target.
  * `Views/AppColors.swift`: colours for the new kinds.
  * Not touched: `SafetyService`, `MealStorage` and `MealDosing`,
    `MachineLearning`, `AddedGlucoseDataFrame`, and
    `AppObservableState.digestionCalibrated`, which reads the recorded
    basal rate and insulin sensitivity and so keeps working on the
    settings values.
  * The row type and the table keep their names (`TargetOverride`,
    `target_override`) although a row can now carry a dosing override.
    Renaming them is churn and a migration for no behaviour.
  * Source files are listed explicitly in
    `BioKernel.xcodeproj/project.pbxproj` for both the app and the
    test target. A new file has to be registered there, the way
    `ExercisePolicyTests.swift` was.

### Safety interactions

With a dosing override on, the PID computes `insulinNeeded =
pidOutput / overrideInsulinSensitivity`, which is `dosingMultiplier`
times what the settings would give, and adds `overrideBasalRate` back
in. At zero correction the temp basal is the basal rate times
`dosingMultiplier`.

  * **The integrator input and the biological invariant do not
    move.** `deltaGlucoseError` reads the settings basal rate and
    insulin sensitivity and never sees the scaled pair, so both are
    the same with a dosing override on as with it off. Scaling the
    pair there would leave the basal term alone, because basal rate
    times insulin sensitivity is unchanged, and change how much
    glucose drop each unit of absorbed insulin is credited with:

        scaled error = settings error
            + absorbed insulin (U/h) * settings insulin sensitivity
              * (1 / dosingMultiplier - 1)

    At an insulin sensitivity of 45 that is +30 mg/dl per hour for
    each U/h absorbed under Exercise, +11 under Post exercise and -10
    under Digestion.
  * **What the scaled pair would do to the invariant.** Under Exercise
    it would trip later: +30 with 1 U/h absorbing, against a trip
    point of -35. With 2 U/h absorbing it is +60, which puts most
    ticks past the 40 mg/dl per hour digestion threshold, where
    `deltaGlucoseError` returns nil and the invariant is off. Under
    Digestion it would trip sooner than it does with no override, and
    staying on settings gives that up.
  * **What the scaled pair would do to the integrator.** On settings
    the integrator does not see the override's own dosing as error:
    the extra insulin predicts an extra drop and produces one, and the
    two cancel. It moves only when glucose departs from the settings
    model, as it does with no override. The two choices differ like
    this:

    | Integrator input on | Response to insulin really shifted | Response still what the settings say |
    |---|---|---|
    | the scaled pair | neutral | winds against the override |
    | the settings | winds further the override's way | neutral |

    We do not assume the shift is real, so the right-hand column is
    the one to design for. There the scaled pair winds toward more
    insulin under Exercise (+15 a tick with 0.5 U/h absorbing, which
    reaches the 240 clamp in about 80 minutes), and what it
    accumulated outlasts the override. On settings an override's
    effect is the multiplier, for as long as the override is on.
  * **What staying on settings costs under Digestion.** If the
    Digestion claim is wrong the integrator does not push back on it.
    The proportional term, the shutoff, the guardrail clamp and the
    invariant are what resist, and the exposure is basal and
    corrections up 30% for at most 3 hours. If the claim is right the
    integrator stacks on top of the boost, bounded by its clamp: 240
    at the default gain of 0.055 is 13.2 mg/dl of error, which is
    0.29 U at an insulin sensitivity of 45 and 0.38 U under Digestion.
  * **Starting Exercise or Post exercise.** The basal baseline of
    insulin on board is computed from the scaled basal rate, so it
    drops at once while the insulin actually on board still reflects
    the old rate. The PID sees net insulin and doses below the scaled
    basal rate until it decays. That is the safe side.
  * **Starting Digestion.** The baseline rises above the insulin on
    board. Net insulin is `max(insulinOnBoard -
    basalBaselineInsulinOnBoard, 0)`, so it clamps at zero and there
    is no catch-up dose for the gap. The same clamp covers Exercise
    ending.
  * **Digestion ending.** The baseline drops back, the extra insulin
    on board counts as net insulin, and dosing is reduced.
  * **The integrator is not reset** when a setting starts or ends, the
    same as the target overrides. Its input is on the settings values
    throughout, so what it has accumulated means the same thing on
    both sides of a start or an end.
  * **Bounds do not move.** The PID's temp basal is bounded by the
    guardrail clamp at `maxBasalRateUnitsPerHour`, as today, so
    Digestion raises it by the multiplier inside that clamp. The ML's
    budget over the PID comes from `maxBasalRate()` on the unscaled
    schedule. The micro-bolus is sized from the temp basal and capped
    by `maxBasalRateUnitsPerHour`. The shutoff does not move.
  * **`pid_basal_rate_iob` follows the scaled basal rate**, because it
    is the PID's own baseline. The diagnostic chart plots it beside
    the recorded basal rate, which is the settings value.

### Tests

  * Policy tests: the dosing multiplier arithmetic (basal rate times
    it, insulin sensitivity divided by it, their product unchanged);
    target, multiplier, default duration and choices for each kind;
    only meal soon ends on a manual bolus. `ExercisePolicyTests` and
    `MealSoonPolicyTests` hold the existing ones.
  * `TargetGlucoseServiceTests`: each of the five kinds starts,
    reports its target and its dosing override, and expires on the
    clock; starting any kind supersedes any other; the fail directions
    return the settings target with no dosing override. The existing
    exercise tests become exercise soon tests. Meal soon runs for the
    picked duration and still ends on a manual bolus. The target the
    Status section shows is the target the service returns, for every
    kind and for settings targets on both sides of the clamp.
  * `PhysiologicalModelsTests`: the PID with scaled inputs gives the
    scaled basal rate at zero correction; `deltaGlucoseError` follows
    the settings values; with scaled inputs the integrator still
    accumulates the settings error.
  * `ClosedLoopTests`: `anOverrideTargetShiftsThePidErrorAndIsRecorded`
    now expects the settings target in the target field and the
    override target beside it. Add a dosing override run: the recorded
    basal rate and insulin sensitivity are the settings values, the
    override pair is the scaled values, and the flag is on. Add a run
    with a data frame that trips the biological invariant on the
    settings values: it trips under every dosing override, with the
    same integrator input as with none.
  * `LoopRecordStoreTests`: the four new columns round-trip, are NULL
    on a tick with no override, and `filteredGlucose` carries the
    override target; the new kinds round-trip through
    `target_override`.
  * `LoopOutcomeCodableTests`: the new `PipelineOutputs` fields
    default when absent, beside
    `targetSourceDefaultsToSettingsWhenAbsent`.
  * Mocks and fixtures to update: `MockPhysiologicalModels` and
    `MockTargetGlucose` in `Utils/MockClasses.swift`,
    `Utils/ClosedLoopTestSupport.swift`, and
    `Utils/LoopRecordFixtures.swift`.
