# Cleanup

We are going to clean up the ios app a bit to get ready for a new
round of development. From a high level we are going to:

  - remove the EventLogger

  - set minimum iOS version to 18 and clean up all compiler warnings

  - remove exercise mode from the iOS app only, but leave it as a part
    of the watch app

## Event logger

Source: ios/BioKernel/BioKernel/Services/EventLogger.swift

The event logger is a module used to store logs on a server. I want to
rethink this feature fundamentally so for now we will remove
it. Unfortunately, that module has taken on a number of other tasks
that we want to keep including:

  - setting up push notifications

  - storing glucose and insulin records in healthkit

To work on this task, let's decompose it into a few subtasks. In
particular I want to refactor the event logger to break out the push
notification functionality and healthkit functionality into their own
modules.

For push notifications, create a new serivce called
`PushNotificationService`, use our dependency injection system, and
enable that code to get called at the right place.

For our healthkit functionality, we can extend the current
`HealthKitStorage` service to include whatever new interfaces we need
and invoke them from the appropriate places in the current code, just
like they're getting called from the current event logger.

Add some simple unit tests to test the basic functionality if it makes
sense, if it doesn't make sense explain it to me and we can come up
with a solution.

## update minimum iOS version to 18 and fix compiler warnings

I'll update the minimum version manually, your job is to compile it
and work with me to fix the issues. We can ignore all compiler
warnings outside of the BioKernel.

To build, use the workspace `MetabolicOS.xcworkspace`.

## Exercise mode

See the `remove_exercise_mode.md` spec for more details.