# Diagnostic View

We would like to have a view that shows diagnostic information. This
view is invoked from the main view when the user clicks on the
"wrench.and.screwdriver" button. We will separate this view into these
subviews using a button selector at the top to pick between them:

  - History, insulin, PID, ML

## Architecture

In terms of data flow, the ClosedLoopService maintains the state for
this feature. Use a ViewModel to do the conversion from raw
ClosedLoopResult objects to something that we can display using our
views.

The ViewModel will be an observable object that is created when the
DiagnosticDataView is created. We need to add a new atomic function to
the ClosedLoopService that returns the current data and registers a
delegate that is invoked when new ClosedLoopResults arrive over the
lifetime of the ViewModel.

We will use an EnvironmentObject to share the ViewModel among the
diagnostic subviews. This means the main DiagnosticDataView will
instantiate the ViewModel as an @StateObject and inject it into the
environment, allowing subviews to access it via @EnvironmentObject.

## History

History is a list sorted in reverse chronological order that shows
four items for each entry in the ClosedLoopChartData:
  - Time (at)
  - glucose
  - temp basal (0 if none)
  - micro bolus (0 if none)

## Insulin

Insulin shows a chart with the standard 2, 4, 6, 12 hour time ranges
(similar to GlucoseChartView) that displays two line charts. One for
glucose and another for IoB with the "at" value serving as the X point
for both.

## PID

Here we want to show two charts stacked vertically, again using the
standard 2, 4, 6, 12 hour time ranges. In the first chart we want:
  - proportionalContribution: Kp * error
  - derivativeContribution: Kd * derivative
  - integratorContribution: Ki * accumulatedError
  - totalPidContribution: Sum total of all of them

In the second chart we want:
  - deltaGlucoseError

For both charts the `at` value is the X value for the point and if
there are any `none` values assume that they are 0.

## ML

Here we will show one chart with the following lines:
  - mlInsulin
  - physiologicalInsulin
  - actualInsulin

And another chart that shows:
  - machineLearningInsulinLastThreeHours

For mlInsulin this is calculated as:
  - mlInsulin = machineLearningTempBasal / 12 + machineLearningMicroBolus
  - physiologicalInsulin = physiologicalTempBasal / 12 + physiologicalMicroBolus
  - actualInsulin = actualTempBasal / 12 + actualMicroBolus

## Data structures and protocols
```swift
// Data structure that the view will consume
struct ClosedLoopChartData {
    let at: Date
    let glucose: Double
    let insulinOnBoard: Double
    let poportionalContribution: Double
    let derivativeContribution: Double
    let integratorContribution: Double
    let totalPidContribution: Double
    let deltaGlucoseError: Double
    let mlInsulin: Double
    let physiologicalInsulin: Double
    let actualInsulin: Double
    let machineLearningInsulinLastThreeHours: Double
}

// The protocol / delegate for the ClosedLoopService
protocol ClosedLoopChartDataUpdate {
    func update(result: ClosedLoopResult)
}

// new method for the ClosedLoopService
// atomically returns the current closed loop result set and registers
// the delegate for future updates
func registerClosedLoopChartDataDelegate(delegate: ClosedLoopChartDataUpdate) -> [ClosedLoopResult]
```
