# Remove Exercise Mode from iOS App and Control Loop

The goal of this task is to completely decouple "Exercise Mode" from
the iOS application and the Automated Insulin Delivery (AID)
algorithm, while maintaining the workout tracking functionality as a
standalone feature on the Apple Watch.

## Objectives

  - Remove all UI elements related to workouts and exercise from the iOS app.

  - Remove the `adjustTargetGlucoseDuringExercise` user setting.

  - Clean up the AID control loop so it no longer bails or adjusts targets based on exercise state.

  - Decouple the Watch app's `WorkoutManager` from the iOS app's communication channels.

## Open questions

  - will this change modify any of our serialized data structures in a way that will cause an issue when we try to read them back in? I don't think so since we're just removing properties, but I wanted to check

## Verification Plan
  - [ ] **Compilation**: Verify both `BioKernel` (iOS) and `BioKernelWatch Watch App` (watchOS) targets build successfully.

  - [ ] **Unit Tests**: Run `ClosedLoopTests` and `ClosedLoopSafetyTests` to ensure the algorithm still doses correctly without the exercise parameter.

  - [ ] **UI Audit**: Ensure the "Adjust target glucose during exercise" toggle is gone from Settings and no workout badges appear on the Home view.

  - [ ] **Watch Independence**: Start a workout on the Watch and verify no logs appear on the iOS side indicating a received message.
