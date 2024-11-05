# GlucOS

![BioKernel screenshot](biokernel.jpeg)

GlucOS is a new automated insulin delivery system with a focus on
computer security. GlucOS is a simple, yet still fully featured
automated insulin delivery system. Simplicity is important for being
able to understand how the system works and anticipate changes when we
make them.

GlucOS is the first automated insulin delivery system to support
ML-based predictions safely. To read more about how we do it, you can
see our [academic
paper](https://bob.cs.ucdavis.edu/assets/dl/glucos.pdf) on the
topic. We also discuss several novel security mechanisms around
insulin pump driver security, how we model human physiology and use it
as a part of our security system, our use of formal methods, and how
we include humans as a part of the system.

## Warning: This source code is highly experimental

This source code is not meant for people to use yet. Also, the ML
model is highly personalized for one individual and not appropriate
for anyone other than that person to use.

Also, we haven't moved the `event-log` server or our formal methods
proofs to this public repo yet.

## Getting started

If you'd like to play around with the code and run it in the
simulator, you can build it like this:

```bash
$ git submodule update --init --recursive
$ open ios/MetabolicOS.xcworkspace
```

We also have a version running on TestFlight, contact Professor Sam
King from UC Davis about it if you're interested in getting added.