# Meal Announcements from AI Apps

GlucOS supports meal announcements from AI apps. The underlying
mechanism is already defined in our [AI interface](ai-interface.md),
so this document focuses on the overall architecture and GlucOS-side
experiences. Historically, GlucOS didn't have a meal abstraction, so
we'll be adding one as a part of this work.

## Overview and architecture

The main components of our meal announcement system are:

  * A "Meals" view that shows the last 90 days of meals, cut into day
    sections the way ClueClue's own meal history is -- 90 days flat is a
    wall of rows with the same date restated on every one of them, so
    the day moves up into the section header and the row keeps the time.

  * A "meals details" view that shows what happened as a result of the
    meal. This view shows 30m before and 3.5h after, glucose, insulin,
    alerts, and the meal, and can borrow heavily from the ClueClue
    UI/UX.

  * A "meal announcement" view that shows the user what GlucOS would
    like to bolus for the meal, using the same reasoning as ClueClue
    does for MDI. The user can dose the bolus from this view.

And behind the scenes, there are:

  * GRDB store for meals

  * Algorithms for making run-to-run adjustments to meal bolus values

## UI/UX

In general, ClueClue has a really good first cut at most of this
UI/UX, just copy it for now. One conceptual difference is with
ClueClue we log insulin but with GlucOS we actually deliver it.

The announcement screen is a port of ClueClue's verification screen
(figure 4 of the ClueClue paper): the meal description heading the
screen at full weight, because what is on the plate is what the user
has to check before delivering insulin; a recommendation card carrying
the meal-slot eyebrow, the dose as one large number, the three tiers,
one line of reasoning, and the decision context as an IOB / last-bolus /
glucose stat row; a collapsed **Adjust** card holding the stepper and a
field for a value outside the three tiers; the reference window under
it as a chart card, an event timeline and a total-insulin card; and the
primary action pinned to the bottom.

Four deliberate departures from ClueClue's version:

  * **No mascot.** ClueClue heads her card with one. She stays out of
    GlucOS, both because GlucOS is not ClueClue and because ClueClue's
    own guidance keeps her off live dosing surfaces.

  * **Adjust offers dose only**, where ClueClue offers dose, insulin
    type and time. The pump chooses the insulin here and delivery is
    now.

  * **The timeline's third event is the run-to-run outcome**, where
    ClueClue shows a glucose-alert episode. GlucOS does not persist its
    predicted-low alerts, but `MealDosing.outcome` recomputes the same
    event from stored glucose -- and unlike a notification, it is the
    reason the next dose moves, which is what this screen is for. Basal
    is left off the timeline entirely: it runs continuously and the loop
    adjusts it for reasons unrelated to the meal, so a row per temp
    basal would bury the events that matter. The IOB curve carries it.

  * **The reference window ends in a total insulin card**, which ClueClue
    has no equivalent of because ClueClue does not deliver anything. It
    is every unit the pump gave over that window, split into the meal
    bolus and everything the loop put in on top of it whenever both
    halves are real amounts. That is the number the tiers cannot carry:
    they step off the bolus the user picked, so a 1.20u meal the loop
    then had to follow with 2u of correction came up short by far more
    than a tier. It appears only where the window does -- a first-time
    meal has no total to show.

**Automatic boluses stay off the chart's marker rail.** A closed loop can
micro-bolus every five minutes, and a row of syringe glyphs across the
top of the window buries the meal and the outcome, which are what the
picture is for. They are drawn as beads on the glucose trace instead, at
the instant they were given and in the trace's own colour, so they read
as *when the loop stepped in* against the glucose that made it. They
keep their row in the timeline below, where a list has room to say what
each one was. The user's own boluses keep their marker: those are
decisions, not the loop maintaining.

Any **other meal sharing the window** appears on both surfaces -- on the
timeline and as a chart marker -- including one in the 30-minute lead-in
before the anchor. A second plate is the usual explanation for what
glucose did next, and when it cut the analysis short, its marker is
exactly where the evidence stops. Only a *later* meal truncates; one in
the lead-in is shown because it explains carbs already on board.

The meal detail screen shows the same chart card and timeline, and
offers a **Dose this meal** button that opens the announcement screen.
It appears only when nothing has been dosed for the meal, the meal is
not cancelled, and the meal started within the last 30 minutes -- see
`StoredMeal.canDose(at:)`. Recency is measured from the meal's own start
time rather than from when the announcement was written, because what
governs whether insulin still helps is when the person ate; a meal
announced *for the future* keeps the button, which is pre-bolusing
working as intended.

For the flow itself, the logging of the meal happens in the AI app,
which switches to GlucOS for the "meal announcement". We will use a
universal link to facilitate this cross-app UX:

```
https://typezero.ai/meal?bundleId=<bundle.id>&mealId=<mealId>
```

Those two parameters are the identity from the announcement files and
nothing else travels in the link -- the meal is already in the file, and
a link carrying its own copy would be a second, unversioned way to
announce a meal. The AI app writes the announcement first and opens the
link second; GlucOS ingests before resolving it, so there is no wait
between the two.

The domain belongs to the *sending* app, not to us, and so does the
apple-app-site-association file that vouches for GlucOS -- ClueClue
serves it from its own App Engine instance
(`server/clueclue/applinks.py` in the ClueClue repo). That is the right
way round even though GlucOS is the app being opened: the sender owns
the link, and ClueClue is the side with a web host. We carry
`applinks:typezero.ai` in our entitlement to match, and it is the only
associated domain GlucOS declares -- the `betes.ai` entry the retired
settings-import link used is gone. Since the association file claims
exactly one path on one domain, link handling matches on path alone and
never on host: a host check would be a second gate that can only
disagree with the first.

Two deployment dependencies, both outside this repo:

  * `typezero.ai` has to resolve to ClueClue's App Engine instance, as
    a custom domain mapping. Being an apex domain, that needs A/AAAA
    records rather than a CNAME.

  * The association file has to be reachable at
    `https://typezero.ai/.well-known/apple-app-site-association`
    over HTTPS, with no redirect and `Content-Type: application/json`.

Until both hold, iOS opens the link in Safari rather than the app and
ClueClue's server answers with a short page saying so. Nothing is lost
when that happens -- the announcement was written to the interface file
before the link was opened, so the meal is in our Meals view either way.

The old `AI Meal X of YU delivered` banner on the main view is gone. It
existed to show what we *would* have done with an announcement; the
announcement screen now actually does it, and the Meals view holds the
history the banner could only hint at. Meals is reached from the fork
icon in the main view's toolbar.

## Dosing basics

The fundamental abstraction in our system is a meal description. If
the AI sends us the same meal description then we consider the current
meal to be the same meal from the past.

Two details about that matching, both settled during implementation:

  * Descriptions are normalized before they are compared: case folded,
    and every run of whitespace collapsed to one space. So "Eggs  and
    Toast" and "eggs and toast" are one meal with one dosing history.
    Nothing else is touched -- punctuation and word order stay
    significant, because an AI that writes a different description
    means a different plate.

  * Matching is **across apps** for this first cut: two apps that
    describe a meal the same way share its history. Each stored meal
    records the bundle id that announced it, so that can be narrowed
    later without having lost the data it would need.

An announcement with no description is a cancelled meal, per
[ai-interface.md](ai-interface.md). Cancelled meals are kept but never
used as dosing history, and a cancellation that arrives after the user
has dosed does not unmake the insulin.

If we have never seen this meal before, the dose is:

```
usual = 3h * maxHourlyBasalRate
```

So if their max basal rate is 0.6 U/h then the suggested
dose is 1.8 U.

`maxHourlyBasalRate` here means the person's **peak therapy basal
rate**: the maximum across their ML-learned basal schedule, falling
back to the pump basal rate they set as a backup when nothing has been
learned yet. That is `CodableSettings.maxBasalRate()`.

It is emphatically **not** `maxBasalRateUnitsPerHour`, the safety
guardrail `SafetyService` clamps delivery against -- that is set well
above any rate anyone actually runs. On the shipped defaults the two are
2.0 U/h and 0.3 U/h, so confusing them turns a 0.9 U cold-start dose
into 6.0 U. Spelled out because the first implementation got it wrong.

We always give the user the choice to select "less", "more", or
"usual" bolus amount. We calculate these by taking the algorithmic
recommendation as our "usual" and then:

```
insulinToMove25 = 25 / insulinSensitivity
deltaInsulin = max(insulinToMove25, 0.05).rounded(toNearest: 0.05)
less = usualBolusAmount - deltaInsulin
more = usualBolusAMount + deltaInsulin
```

## Run-to-run adaptations

The core dosing strategy focuses on meal doses, where GlucOS will:

  * If the meal is a repeat, check the dose the last time the meal was
    consumed and inspect for 3.5h after the announcement.

    - If glucose was predicted low between 0.75h and 3.5h post meal, dose
      less. Skipping the 0.75h before helps avoid low predictions that carry
      over from the previous meal.

    - If the max glucose over the 3.5h period rises by more than 80
      mg/dl from the glucose at the start, then dose more.

    - If there are multiple events (low predicted glucose and
      deltaGlucse > 80), the earliest event wins.

    - If another meal cuts short our 3.5h post meal period, cut short
      our analysis period so that it does not include the other meal.

  * To adjust dosing, use the same calculation we use for suggesting
    "less" and "more" to calculate `deltaInsulin` and then adjust the
    dose using that increment if an adaptation is needed.

Two things this leaves out that the implementation had to settle:

  * **We reason about the most recent instance only.** There is no
    averaging over a meal's history and no window of past instances --
    the reference is the last time this meal was dosed, full stop.

  * **The dose we learn from is the one the user picked** -- less,
    usual, more, or a value they typed in by hand. Not our
    recommendation, which is not what happened, and not the pump's
    delivered total over the window, which includes every correction
    the loop made for reasons that had nothing to do with the meal.

"Predicted low" means the same prediction that fires the user's low
glucose alert, replayed at each CGM tick in the window and compared
against **their own low alert level**. Nothing persists a forecast, so
this is the 15-minute least-squares extrapolation from
`PhysiologicalModels` run at a past instant; it reads only glucose, so
replaying it is exact rather than an approximation. A second threshold
of our own would mean learning from lows the user never saw, or
ignoring ones they did.

A window we cannot see is not a window that went well. No glucose at
the meal, or no readings inside the window, holds the dose steady and
says so -- distinct from "this dose worked", which holds it for the
opposite reason.
