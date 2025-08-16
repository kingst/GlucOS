This repo is for GlucOS, and experimental iOS app for automated
insulin delivery. See @README.md for details about what is unique
about it.

Overall, I use dependency injection using a custom dependency
injection system, which you can find here
@ios/BioKernel/BioKernel/DependencyInjection This is a good place to
look because it gives an overview of all of the core services that are
included in the app.

We use a number of submodules, which you can use git to find. These
provide basic AID abstractions and drivers for CGM and pump hardware.

To interface between the submodules and the AID you can see the
@ios/BioKernel/BioKernel/LoopKitSupport directory. It includes a lot
of interface code to marshal data, commands, and events between the
submodules and the main AID.

In terms of programming, I make heavy use of Actors in iOS and
async/await patters. This started off as a research prototype, so
parts of it are a bit messy but in general the code should be data
race free.

The core abstactions are implemented in a set of services, which you
can find at @ios/BioKernel/BioKernel/Services In that directory we
have services for insulin, glucose, alerts, and others.

The most important service is the ClosedLoopService, which is where
the actual closed loop algorithm runs. It starts typically from a new
CGM reading and calculates insulin dosing.

Most of the UI views access observable objects exposed by services and
display their data without going through a viewmodel. You can find
most of the views and the few view models we do have a
@ios/BioKernel/BioKernel/Views and @ios/BioKernel/BioKernel/ViewModels

There is also a watch app but it doesn't do much other than support
workouts and display data.

Currently, I am making changes to adopt some of the ideas from Trio
and to clean things up a bit. I'm going to start using it again soon
(I've been using Trio for a while).

**IMPORTANT** Rules for gemini:

* You may use my credentials to read from github repos. Some of this
  work is being done in private repos.

* You may _never_ write to github repos. I have write access to
  critical code, so you are never allowed to push code to a remote
  repo.

* You may _never_ commit code, even on local repos. I always want to
  check your work so don't ever commit code even on local repos.

* You may _never_ use forced unwraps. I might use them every once in a
  while when I write code manually but I don't want you to ever use
  them.

* Only make changes if I ask you to explicitly. Oftentimes I'm looking
  to get help understanding the code and coming up with porting
  strategies, so if I want you to change something I will ask
  explicitly.

* I'm making changes manually as we go, always re-read files before
  modifying them. Never assume that you're the only one making
  changes.

* Don't change iOS project files, if you create a new file I will add
  it to the project manually.

* Ask questions! If something isn't clear please ask clarifying
  questions before diving in. I'm here to help.

* Don't change code in submodules. Use git to figure out which
  directories have submodules and don't change these. If you find a
  situation where it would be MUCH cleaner to change a submodule we
  can, that you need to discuss this with me first so we can go over
  the tradeoffs. Maintaining our own submodules is kind of a pain and
  I'd like to avoid it if we can.