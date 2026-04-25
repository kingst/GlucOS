# Closed Loop Refactor

This spec covers a structural refactor of `LocalClosedLoopService` and its
data types. The goal is to separate the pure dosing algorithm from the
orchestration that fetches data, programs the pump, and records state; and
to replace the current product-type-with-optionals data shapes with
purpose-built sum types.

## Motivation

`LocalClosedLoopService.closedLoopAlgorithm` is the most important ~40 lines
in the system. Today it is an actor method that awaits 6+ other actors,
mutates instance state (`lastMicroBolus`), and returns a struct with fields
marked `// remove` / `// rename`. The result types (`ClosedLoopResult`,
`ClosedLoopAlgorithmResult`, `SafetyResult`) are product types pretending
to be sum types, with factory methods that zero-fill unused branches. A
reader of our paper opening this file cannot tell at a glance which branch
of the algorithm ran on a given loop tick.

After this refactor:

  - The pure algorithm is extractable, property-testable.
  - The persisted loop record has one shape per outcome, enforced by the
    compiler via pattern matching.
  - Service responsibilities inside the closed loop are each a small,
    individually testable struct.

## Objectives

  - Introduce sum types for the dosing decision and the loop outcome.
  - Separate loop inputs, pipeline outputs, and persisted records into
    three distinct types.
  - Extract `Guardrails`, `MicroBolusPolicy`, and `DoseSelector` from
    `LocalClosedLoopService`.
  - Extract a pure `DosingPipeline` that takes `LoopInputs` and returns
    `PipelineOutputs`, with no `await` and no I/O.
  - Split `runLoop` into collect-inputs, compute, program-pump, record
    stages.
  - Drop legacy "shadow" fields from persisted records.

## Design

### Core data types (new)

```swift
enum DosingDecision: Codable {
    case tempBasal(unitsPerHour: Double)
    case microBolus(units: Double)
    case suspendForBiologicalInvariant(mgDlPerHour: Double)
}

enum LoopOutcome: Codable {
    case skipped(SkipReason)
    case dosed(LoopSnapshot)
    case pumpError(attempted: LoopSnapshot)
}

enum SkipReason: String, Codable {
    case openLoop
    case glucoseReadingStale
    case pumpReadingStale
    case noPumpManager
}

struct LoopInputs {
    let at: Date
    let settings: CodableSettings
    let cgm: GlucoseReading
    let insulinOnBoard: Double
    let dataFrame: [AddedGlucoseDataRow]
    let cgmPumpMetadata: CgmPumpMetadata
}

struct PipelineOutputs {
    let targetGlucose: Double
    let predictedGlucose: Double
    let pid: PIDTempBasalResult
    let safety: SafetyAnalysis
    let decision: DosingDecision
    let timings: StageTimings
}

struct LoopSnapshot: Codable {
    let inputs: LoopInputs       // or a flattened subset of relevant fields
    let outputs: PipelineOutputs
}

struct ClosedLoopResult: Codable {
    let at: Date
    let outcome: LoopOutcome
}

struct StageTimings: Codable {
    let pidDurationInSeconds: TimeInterval
    let mlDurationInSeconds: TimeInterval
    let safetyDurationInSeconds: TimeInterval
}
```

### Data types to delete or collapse

  - **`ClosedLoopAlgorithmResult`** — deleted. The pure pipeline returns
    `PipelineOutputs`; the runner builds `LoopSnapshot` for persistence.
    No copy-between type.
  - **`SafetyResult`** — collapsed into `SafetyAnalysis` (the numbers
    needed for audit) plus the `DosingDecision` (which case actually ran).
    The three `withTempBasal` / `withMicroBolus` /
    `withBiologicalInvariantViolation` factories disappear.
  - **Shadow fields** (`shadowTempBasal`, `shadowPredictedAddedGlucose`,
    `shadowMlAddedGlucose`, `shadowAddedGlucoseDataFrame`) — deleted from
    core types. If still needed for experiments, move into an
    `ExperimentMetrics?` sub-struct behind a debug setting.

### Data-type micro-cleanups

  - Delete hand-written inits on simple structs (e.g.
    `PIDTempBasalResult.init`); rely on Swift's memberwise init.
  - Rename `SafetyTempBasal` to `SafetyBoundedBasal` (or similar) so the
    return of `SafetyService.tempBasal` names what it actually is: a
    temp basal after safety bounding, plus the ML-insulin history used to
    bound it.
  - Fix on-disk typos via `CodingKeys` without breaking existing JSON:
    `learnedInsulinSensivityInMgDlPerUnit` → `learnedInsulinSensitivityInMgDlPerUnit`;
    `glucosDynamicISF` → `glucoseDynamicISF`.

### Service decomposition

**`Guardrails`** — struct built once per tick with `settings`, current
glucose, predicted glucose, and the pump-rounding closure. Exposes
`clamp(_ raw: Double) -> Double` and `shouldShutOff() -> Bool`. Currently
inlined in `applyGuardrails` and duplicated across physiological / ML /
safety candidates.

**`MicroBolusPolicy`** — struct that takes `LoopInputs` plus the previous
micro-bolus time and returns a micro-bolus amount. Separates throttle (4.2
minutes), glucose gate (target + 20), conversion (temp basal to units over
the correction window), and rounding into named methods.

**`DoseSelector`** — free function (or static method) taking candidate
temp basals, candidate micro-boluses, and the biological invariant,
returning a `DosingDecision`. Already pure today in `determineDose`; move
it out of the actor and have it return the enum.

**`DosingPipeline`** — the new pure composition:

```swift
struct DosingPipeline {
    let physiological: PhysiologicalModels
    let machineLearning: MachineLearning
    let safety: SafetyService
    let target: TargetGlucoseService

    func run(_ inputs: LoopInputs) async -> PipelineOutputs
}
```

Still `async` because the underlying model services are actors, but the
pipeline itself holds no mutable state and has no side effects. This is
the piece a future formal-methods effort would target.

**`LoopRunner`** — renamed orchestrator (was `LocalClosedLoopService`).
Responsible for collect-inputs, invoke pipeline, program pump, record
result, notify observers. Target shape:

```swift
func tick(at: Date) async {
    guard !isRunningLoop else { return }
    isRunningLoop = true
    defer { isRunningLoop = false }

    let outcome: LoopOutcome
    switch await collectInputs(at: at) {
    case .skip(let reason):
        outcome = .skipped(reason)
    case .ready(let inputs):
        let outputs = await pipeline.run(inputs)
        let snapshot = LoopSnapshot(inputs: inputs, outputs: outputs)
        switch await program(snapshot.outputs.decision, on: pumpManager) {
        case .ok:
            await safety.record(snapshot)
            outcome = .dosed(snapshot)
        case .error:
            outcome = .pumpError(attempted: snapshot)
        }
    }

    await record(ClosedLoopResult(at: at, outcome: outcome))
}
```

### State relocations

  - **`lastMicroBolus`** — currently an actor field lost on app restart.
    Derive from the last persisted `ClosedLoopResult` whose outcome has
    `decision == .microBolus`. Zero new mutable state; survives restart.

Note: We will save these for a future update, so I want to document
them but we don't need to make these changes.

- **`ClosedLoopChartDataUpdate` delegate** — replace with
    `AsyncStream<ClosedLoopResult>` exposed from `LoopRunner`. UI consumers
    `for await`. Idiomatic with actors; removes the mutable weak reference.
  - **Pump alert acknowledgement** (`userPodExpiration`, `podExpiring`) —
    moved out of the dosing path to a small observer on
    `DeviceDataManager`.

## Phasing

Each phase is independently shippable.

  1. **Sum types for decision and outcome.**
     Introduce `DosingDecision` and `LoopOutcome`. Refactor `determineDose`
     to return `DosingDecision`. Refactor persisted `ClosedLoopResult` to
     carry `LoopOutcome` instead of ~15 optional fields. Update all UI call
     sites to pattern-match. Delete the three `SafetyResult` factories.

  2. **Extract policy structs.**
     Pull `Guardrails` and `MicroBolusPolicy` out of
     `LocalClosedLoopService`. Move `determineDose` out of the actor as a
     free function / static. Unit-test each in isolation (property-based
     tests for guardrails).

  3. **Introduce the pure pipeline.**
     Create `DosingPipeline` and `LoopInputs` / `PipelineOutputs`. Move
     `closedLoopAlgorithm` into the pipeline. `LocalClosedLoopService`
     becomes the runner that composes input collection + pipeline +
     pump programming + recording.

  4. **Relocate state and replace delegate.**
     Derive `lastMicroBolus` from persisted results.

  5. **Rename service and collapse dead types.**
     `LocalClosedLoopService` → `LoopRunner`. Delete
     `ClosedLoopAlgorithmResult` and the shadow fields. Apply `CodingKeys`
     to fix on-disk typos.

