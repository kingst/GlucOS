# AI Interface

GlucOS uses app groups to expose files to external diabetes apps,
presumably mostly AI apps.

Our file layout is:

<container>/AiInterface/
  GlucOS/
    current_insulin_dosing.json
    finalized_insulin_dosing.<UTC_DAY>.jsonl
    ai_commands_ingested.<UTC_DAY>.jsonl
    glucose.<UTC_DAY>.jsonl
  ai/
    <bundle.id>/
      meal_announcements.<UTC_DAY>.jsonl
      pump_commands.<UTC_DAY>.jsonl

All files have a single writer and that writer is responsible for
managing them and cleaning up old files. We must retain at
least 2 days of files to ensure that all components that read these
files can rebuild a complete picture of their past actions.

AID systems can run before the first unlock, so all files and
directories must have `NSFileProtectionNone`. Make sure to set this
property on all files when they are created or renamed.

## Serialization details

Three details for the on disk format that are relevant are:

* We aren't going to use versions for this first cut. Of course we'll
  want them eventually but for now while we're figuring stuff out
  let's keep things simple. A missing version implies v=1.

* All timestamps are Unix timestamps expressed in seconds since the
  epoch. This value is a floating point number to capture fractions of
  seconds.

* `smallestDeliveryUnit` is a floating point number in Units.

For file names, <UTC_DAY> is ISO YYYY-MM-DD, zero-padded, UTC days.

## Daily records

All `<UTC_DAY>.jsonl` files hold daily records for their data
type. The writers for these files append data to them and records are
not sorted. The <UTC_DAY> value is calculated at append time *not*
based on any timestamps that are contained within the records
themselves.

Since records are appended to these files, appends are not
atomic. Readers should be able to withstand partially written final
records and omit any lines without a trailing newline.

## Data written to by GlucOS

### finalized_insulin_dosing.<UTC_DAY>.jsonl

Each row contains a completed insulin delivery record. GlucOS will
retain 90 days of insulin records. Fields within each row include:

  - {id, startTime, endTime, unitsDelivered, insulinType,
    smallestDeliveryUnit, kind}

  - Since records are included in the <UTC_DAY> file based on the
    append time, the startTime and endTime might be from the previous
    day.

  - `kind` is `"basal"` or `"bolus"` and names the pump command the
    insulin came from. It is a record of the delivery mechanism, not a
    claim about intent: modern AID systems blur the distinction and use
    the two as a delivery optimization, and GlucOS's own dosing treats
    them that way. We publish it because algorithms ported from
    elsewhere -- oref, as used by Trio, is the motivating case -- carry
    the split in their model and account for bolus and basal insulin
    separately. An AI that does not care can ignore the field and sum
    `unitsDelivered` as before.

  - `kind` is two-valued on purpose. Every basal record is `"basal"`,
    whether it came from a temp basal, from the scheduled rate, or from
    a stretch of suspension -- a suspension is already legible as a
    record with 0 units, and splitting temp from scheduled would
    re-expose the delivery-optimization detail this interface is trying
    to keep out of an AI's way.

GlucOS will abstract away scheduled basal rates and pump suspension
from the AI where it will maintain records of scheduled basal rates
and include basal events with a rate of 0 for periods of
suspension. Our hope is that this data management will make it easier
for AI to make use of GlucOS data.

### current_insulin_dosing.json

JSON object that has the current basal rate and any ongoing bolus
commands. Insulin dosing objects in this file are *not* also in the
finalized_insulin_dosing file. This object has four keys, with the
following values:

  - updatedAt: the time GlucOS last wrote this file. Without it a
    reader cannot tell "GlucOS is idle" from "GlucOS is dead" or from a
    pump that fell off Bluetooth, and would keep integrating a stale
    basal rate forever. Readers should treat a `current` object that
    has not been updated recently as unreliable rather than assuming
    the basal rate it names is still running.

  - bolus: {id, startTime, programmedUnits, insulinType, smallestDeliveryUnit}

  - basal: {id, startTime, endTime, rateInUnitsPerHour, insulinType, smallestDeliveryUnit}

  - `bolus` and `basal` are omitted when there is nothing outstanding.
    Readers should treat an absent key and a null the same way. `basal`
    is absent only before the first pump sync; once GlucOS has pump data
    it is always present, with a rate of 0 while the pump is suspended.

  - lastCgmTickHandledAt -- a CGM timestamp for the most recent CGM
    reading that GlucOS ran a loop on. Stored after issuing pump
    commands if there are any to set.

  - GlucOS will update this file atomically.

### finalized and current insulin dosing interactions

All records moved from current to finalized files retain the same
ID. In rare cases there can be race conditions since these files are
updated one at a time, and the net result is that the same record will
be in both files for a short period of time, since GlucOS will
append finalized insulin doses before updating or removing them from
the current doses list. If an AI app sees duplicate records in both
the finalized and current dose files, it should treat it as finalized
and re-read the current dose later.

We record the insulin type and smallestDeliveryUnit for all insulin
delivery events. These values will be constant for a pump, but people
change pumps and use different insulins, so they can change over the
history of insulin delivery. The only constant is within each insulin
delivery event.

### ai_commands_ingested.<UTC_DAY>.jsonl

Where GlucOS acknowledges the receipt of an AI command. The records
for this file are:

  - {at, type: meal_announcement, bundleId, mealId, status, errorMessage}

  - {at, type: pump_command, bundleId, commandId, status, errorMessage}

### glucose.<UTC_DAY>.jsonl

A record of all glucose readings from the CGM. GlucOS will retain 90
days of glucose records. The records for this file are:

  - {id, measuredAt, glucoseInMgDl}

GlucOS maintains stable IDs and deduplicates readings before writing
them to this store.

Although there is more data collected from the CGM when new readings
come in, we leave this record relatively simple since AI apps can also
read the CGM directly from BLE if they choose to and need the
additional information.

Glucose `measuredAt` values come from the driver, not the CGM itself,
so AI apps that read the CGM directly might have slightly different
timestamps for the same CGM reading.

## Data written by AIs

Any data written by AIs for GlucOS is only a hint. So for AI
accounting purposes, you should always use the insulin delivery JSON
files to derive the actual insulin delivery, never assume that insulin
specified for a meal will be delivered at a particular time or at all.

* meal_announcements.<UTC_DAY>.jsonl -- a list of meal announcements
  that AIs make. This is our most simple and basic form of AI
  input. Each row is:

  - {mealId, updatedAt, startTime, mealDescription}

  - If the AI would like to revise a previous announcement, they can
    append a new record with the same `mealId` and GlucOS will accept
    the record with the most recent `updatedAt` time.

  - `mealId` only has to be unique within the app that wrote it. GlucOS
    identifies a meal by the pair (bundle id, mealId), so two apps
    picking the same string describe two different meals.

  - `mealDescription` is what the meal *is*, in the AI's own words. It
    is not a dose: GlucOS works out the insulin itself, from this
    description and its own history of it. See
    meal-announcements-from-ai-apps.md.

  - **A record with no `mealDescription` is a cancelled meal.** That is
    the whole retraction protocol -- there is no retract field and no
    version bump for one, because a meal with nothing to describe is a
    meal that is not happening. An AI takes an announcement back by
    appending a record for the same `mealId` with the field absent, and
    a description that is present but blank counts the same way.

  - There is no migration from the earlier `unitsForMeal` shape. A row
    from that era carries no description, so it reads as a cancellation
    and drops out -- which is the right end state for a hint whose
    number GlucOS would no longer use.

* pump_commands.<UTC_DAY>.jsonl -- traditional basal and bolus pump
  commands. Like meal announcements these are just hints, but using a
  language where we can create GlucOS pump drivers in existing AID
  systems, like Trio, and they can influence dosing. Each row is:

  - {commandId, startTime, kind: tempBasal, rateInUnitsPerHour, durationInSeconds}

  - {commandId, startTime, kind: bolus, insulinAmountInUnits}

## What GlucOS does with meal announcements

Copies them into a 90-day meal store, and offers the user a dose for
one when they ask for it. Nothing here is automatic: an announcement
still reaches insulin delivery only through a bolus the user chose and
confirmed on the meal announcement screen. See
meal-announcements-from-ai-apps.md for the dosing itself; this section
is the file-reading contract, and any future consumer of these files
should expect the same rules.

* **Ingestion runs at the top of every loop tick**, before dosing. That
  is the deadline this interface creates: these files retain two days,
  and the day in a name is the *append* day, so an announcement not
  copied out within that window is gone. It is also why ingestion
  cannot wait for a view to open. Ingestion is idempotent -- the same
  announcement is offered hundreds of times a day and lands once -- and
  it never fails a loop.

* It also runs **on app launch, on foreground, when the Meals view
  loads, when the meal announcement screen loads, and when a handoff
  link is resolved.** Those are about
  freshness rather than the deadline, and they are not redundant: the
  loop's caller returns early when no pump is paired and otherwise
  throttles to one run per 4.2 minutes, so the loop path alone leaves
  the Meals view minutes stale with a pump and permanently empty
  without one.

  None of it is debounced **or coalesced**, on purpose, and the two
  fail the same way. A redundant ingest is two small file reads and a
  pass of no-op upserts. Skipping one -- or joining an already-running
  one -- breaks the handoff: an AI app appends an announcement and
  opens the link immediately, so an ingest that started even a moment
  earlier read the file *before* that line existed, and a caller who
  waits on it is told the meal isn't there.

  Overlapping ingests are therefore normal and are safe by
  construction, not by exclusion. `LocalMealStorage` is an actor but
  awaits inside `ingest`, so it does not serialize itself. What holds
  is downstream: each ingest is a single transaction, GRDB serializes
  writes on the queue, and the upsert's
  `WHERE excluded.updated_at > meal.updated_at` makes a duplicate a
  no-op rather than a second row. The upsert also never writes the dose
  columns, so an ingest landing on top of a delivery cannot clear it --
  which matters because that dose is what the next instance of the meal
  adapts from.

  The meal announcement screen re-reads its meal after ingesting rather
  than trusting the copy it was constructed with. An AI can revise a
  description -- changing which past meal the dose is adapted from --
  or cancel the meal outright, between the link opening and the screen
  appearing. A cancelled meal is shown as cancelled and cannot be
  delivered.

* Revisions are collapsed before anything else, so the newest
  `updatedAt` for a `mealId` is the only row that means anything, and a
  revision can change a meal's description or cancel it after the fact.

* GlucOS reads today's and yesterday's file. Because the <UTC_DAY> in a
  name is the append day, a meal that started an hour ago can be in
  yesterday's file just after midnight UTC. An announcement written more
  than a day before the meal it describes can age out of the retained
  window before the meal happens; a revision appended nearer the meal
  would not.

* A cancellation marks the stored meal rather than deleting it, and
  keeps the description it cancelled. Cancelled meals drop out of the
  Meals view and are never used as dosing history, but a cancellation
  that arrives after the user has already dosed does not unmake the
  insulin -- the row is the only place that pairing survives.

* Revising a description never disturbs what the user dosed for that
  meal. An AI is allowed to sharpen up its wording after the fact, and
  that is not a reason to forget an injection.

* What GlucOS learns from is the dose **the user picked**, not what it
  recommended and not what the pump delivered over the window. The
  recommendation is not what happened, and the pump's total includes
  every basal adjustment the loop made for reasons that had nothing to
  do with the meal.

* Rows are untrusted input: a trailing line with no newline is dropped,
  a malformed row is skipped without affecting the rows around it, and
  GlucOS creates, modifies, and deletes nothing under `ai/`.

An AI app can hand a meal straight to the announcement screen with a
universal link:

```
https://typezero.ai/meal?bundleId=<bundle.id>&mealId=<mealId>
```

The two parameters are the same identity the files use. Nothing about
the meal travels in the link -- it is already in the file, and a link
carrying its own copy would be a second, unversioned way to announce a
meal. GlucOS ingests before resolving the link, so an app can append its
row and open the link immediately rather than waiting for the next tick.

## What GlucOS does with pump commands

Pump commands are not that interesting from an AI perspective, so we
simply run them through the traditional GlucOS dosing safety
logic. This saftey logic is to clamp insulin delivery from AI apps
given safety bounds set on the max basal rate, as described in the
GlucOS academic paper.

For the commands themselves, GlucOS will process any commands from
within the last 5 minutes and will store <bundleId, commandId> pairs
for commands that it has processed to avoid processing the same
commands twice.

GlucOS exact handling of these values is beyond the scope of this
document.

## AI apps that listen in on CGM BLE directly

Any AI apps that listen in on CGM BLE commands directly should poll
the GlucOS current_insulin_dosing.json file for 30s after the CGM BLE
command as GlucOS also listens in on CGM BLE messages and will set new
pump commands in response to these signals. Thus, to get the latest
state, AI apps need to wait for a bit to see what GlucOS does during a
loop cycle.

GlucOS will store a value in the `lastCgmTickHandledAt` after it is
done issuing its own pump commands, so AI apps can use this value to
know once an update is complete.

## Suggested IoB algorithm

This section shows how GlucOS expects AIs to calculate IoB to clarify
the semantics of the records. But AIs can use different IoB algorithms
if they want.

The key algorithm we care about is IoB. Here is how to calculate IoB
efficiently. This algorithm shows IoB calculations for a single
insulin type, but if a history contains multiple insulin types this
same calculation needs to run over all of them with the final result
summed for all insulin types.

First, we need to convert the ongoing insulin delivery events to the
same format as finalized doses to make the calculation simple. The
records in `current_insulin_dosing.json` carry no `kind` of their own
-- the key they sit under already says which they are -- so supply it
during the conversion:

```
let now = Date()
let currentBolus = FinalizedDose(
    id: id,
    startTime: startTime,
    endTime: now,
    unitsDelivered: programmedUnits, // assume all insulin delivered at once
    insulinType: insulinType,
    smallestDeliveryUnit,
    kind: .bolus
)
```

For bolus events we will overcount IoB for ongoing bolus events, but
this behavior is consistent with other AID systems currently in use
(e.g., Trio) and will self correct if the user cancels the bolus in
the middle as the finalized bolus event will have the actual insulin
delivered.

Then you do the same basic thing for the current basal command, with a
`kind` of `.basal`, but you calculate unitsDelivered by:

```
let duration = min(now - startTime, endTime - startTime)
unitsDelivered = duration * rateInUnitsPerHour.unitsPerSecond()
```

Then you have a list of insulin delivery events by creating a list of
events from `currentBolus`, `currentBasal`, and the
`finalizedInsulinDelivery` stored by GlucOS. Make sure to remove any
duplicate records from currentBasal and currentBolus that are already
finalized due to the race condition when updating files noted earlier
in this document. The algorith looks something like this:

```
let insulinDelivery = [currentBasal, currentBolus] + finalizedInsulinDelivery
```

Then we map each insulin delivery event to discretized values by using
smallestDeliveryUnit to figure out how many smallestDeliveryUnit doses
the pump delivered over the delivery duration. We can assume that
insulin delivery is constant for both bolus and basal events and use
rounding to get the number of smallestDeliveryUnit events.

Then with the discretized list of insulin delivery, bucket these into
5 minute intervals starting from `now` and working backwards. Then we
can calculate IoB for each insulin delivery type present in our set by
either using the exponential function on each of these five minute
buckets or pre-calculating a vector with the right coefficients so we
can do a simple dot product to get the result.

Although the absorption curve vector can be cached, the bucketing
algorithm depends on `now` and should be recomputed each time. The
discretization can be cached but that's probably more complexity than
is needed for a simple calculation.