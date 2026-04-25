# Code Cleanup Issues

Here are a few code cleanups we'd like to do before MobiSys.

## Logging and observability

### 1. `print()` is the primary log mechanism
96 `print` calls across 21 files in `ios/BioKernel/BioKernel/`.
`DiagnosticLog` exists in `LoopKitSupport/` but isn't used consistently. For
an AID, structured persisted logs (severity, timestamp, category) are
essential for postmortems. Consolidating on `DiagnosticLog` (or `os_log`
with a category per service) is mechanical but high-value.

### 2. Inline `DateFormatter` in `AIDosing.log`
**File:** `ios/BioKernel/BioKernel/Services/MachineLearning.swift:50-57`

`DateFormatter` init per call is expensive. Move to a static or
potentially remove the AIDosing.log

### 3. Have a plan for storing more than 24 hours of data. In the
current algorithm we use JSON files to store the most recent 24 hours
of data. This data is the data needed to run the algorithm, so we want
to keep the storage stack as simple as possible. However, it might be
useful to have a mechanism to store more data, like 90 days
worth. Loop uses HealthKit for this, Trio uses CoreData, we should
decide if BioKernel should do that too and how (currently there is the
ability to optionally write glucose and insulin data to HealthKit but
that's it).

## Algorithm readability

### 4. Magic numbers in dosing logic
Magic numbers scattered through the dosing code. Promote each to a named
constant at the top of its service. Paper reviewers will ask "why this
value?".

- `-35` biological invariant threshold — `ClosedLoopService.swift:272`
- `0.025` microbolus floor — `ClosedLoopService.swift:168, 276`
- `+20` microbolus glucose threshold above target — `ClosedLoopService.swift:94`
- `-45` / `digestionThreshold = 40.0` — `PhysiologicalModels.swift:93`
- `0.5` `maxInsulinScalingIncrease` and `150.0` `glucoseRangeForScaling` — `MachineLearning.swift:81-82`

### 5. `runLoop` is long and does four things
**File:** `ios/BioKernel/BioKernel/Services/ClosedLoopService.swift:124-205`

Fetch+validate, compute, program pump, record safety state. Splitting into
private helpers would make the happy path obvious and each piece testable.
The current function is ~80 lines with early returns interleaved with side
effects.

### 6. `acknowledgeAlert` calls in the closed loop
**File:** `ios/BioKernel/BioKernel/Services/ClosedLoopService.swift:194-202`

The existing `FIXME` already notes this is out of place. Move to a
pump-manager observer and remove from the dosing path.

## Small but noticeable

### 7. Typos preserved as on-disk JSON keys
- `learnedInsulinSensivityInMgDlPerUnit` (Sensivity) — `SettingsDataTypes.swift:64`
- `glucosDynamicISF` (missing `e`) — `MachineLearning.swift:70, 78`

A `CodingKeys` enum fixes the Swift-side name without breaking existing
on-disk JSON.

### 8. FIXMEs in critical paths
Triage before publication: fix, downgrade to a note with rationale, or file
issues and remove from code.

- `ios/BioKernel/BioKernel/Services/InsulinStorage.swift:151, 191, 197, 200, 420`
- `ios/BioKernel/BioKernel/Services/ClosedLoopService.swift:145, 194`
- `ios/BioKernel/BioKernel/Services/AlertStorage.swift:59`
- `ios/BioKernel/BioKernel/LoopKitSupport/DeviceDataManager.swift:402`
- `ios/BioKernel/BioKernel/LoopKitSupport/DeviceDataManager+Pump.swift:180`
- `ios/BioKernel/BioKernel/LoopKitSupport/DeviceDataManager+CGM.swift:31`
- `ios/BioKernel/BioKernel/Views/MainViewAlertView.swift:24`
- `ios/BioKernel/BioKernel/ViewModels/SettingsViewModel.swift:124`

## Documentation

### 9. No dev doc walking through `closedLoopAlgorithm`
A `dev/algorithm.md` matching the paper's dataflow figure (PID → ML →
safety → guardrails → micro-bolus decision → biological invariant) would
help anyone coming from the paper to the code. `dev/` already has the
infrastructure.
