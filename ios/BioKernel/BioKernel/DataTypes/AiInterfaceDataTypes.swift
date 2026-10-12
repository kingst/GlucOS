//
//  AiInterfaceDataTypes.swift
//  BioKernel
//
//  Created by Sam King on 8/1/26.
//
//  The wire format GlucOS publishes into the shared app-group container for AI
//  apps to read. See dev/ai-interface.md for the requirements and
//  dev/backlog/ai-interface-prompt.md §5 for the field mapping.
//
//  Two rules readers depend on:
//    - There is no `version` key. A missing version implies v=1.
//    - An id is stable when a record moves from `current` to `finalized`.
//

import Foundation
import LoopKit

// MARK: - Insulin type

/// LoopKit's `InsulinType` is `enum InsulinType: Int, Codable`, so its
/// synthesized `Codable` puts `0...5` on the wire and silently changes meaning
/// if LoopKit ever reorders its cases. Readers get a name instead.
///
/// The `init` switch is exhaustive on purpose: a new LoopKit case should fail
/// the build here rather than fall through to a default and mislabel insulin.
enum AiInsulinType: String, Codable, Equatable, CaseIterable {
    case novolog
    case humalog
    case apidra
    case fiasp
    case lyumjev
    case afrezza

    init(_ insulinType: InsulinType) {
        switch insulinType {
        case .novolog: self = .novolog
        case .humalog: self = .humalog
        case .apidra: self = .apidra
        case .fiasp: self = .fiasp
        case .lyumjev: self = .lyumjev
        case .afrezza: self = .afrezza
        }
    }

    var insulinType: InsulinType {
        switch self {
        case .novolog: return .novolog
        case .humalog: return .humalog
        case .apidra: return .apidra
        case .fiasp: return .fiasp
        case .lyumjev: return .lyumjev
        case .afrezza: return .afrezza
        }
    }
}

// MARK: - finalized_insulin_dosing.<UTC_DAY>.jsonl

/// Which pump command delivered the insulin.
///
/// A record of the delivery mechanism, not of intent — modern AID systems use
/// bolus and basal as a delivery optimization, and GlucOS's own dosing treats
/// them that way. It is published because algorithms ported from elsewhere
/// (oref, as used by Trio) carry the split in their model and account for the
/// two separately.
///
/// Deliberately two-valued: a temp basal, the scheduled rate, and a stretch of
/// suspension are all `.basal`. Suspension is already legible as a record with 0
/// units, and splitting temp from scheduled would re-expose exactly the
/// delivery-optimization detail this interface keeps out of an AI's way.
enum AiDoseKind: String, Codable, Equatable, CaseIterable {
    case basal
    case bolus
}

/// One completed insulin delivery.
struct FinalizedDoseRecord: Codable, Equatable {
    let id: String
    let startTime: Date
    let endTime: Date
    let unitsDelivered: Double
    let insulinType: AiInsulinType
    let smallestDeliveryUnit: Double
    let kind: AiDoseKind
}

// MARK: - current_insulin_dosing.json

struct CurrentBolus: Codable, Equatable {
    let id: String
    let startTime: Date
    let programmedUnits: Double
    let insulinType: AiInsulinType
    let smallestDeliveryUnit: Double
}

struct CurrentBasal: Codable, Equatable {
    let id: String
    let startTime: Date
    let endTime: Date
    let rateInUnitsPerHour: Double
    let insulinType: AiInsulinType
    let smallestDeliveryUnit: Double
}

struct CurrentInsulinDosing: Codable, Equatable {
    /// When GlucOS last rewrote this file. Without it a reader can't tell
    /// "GlucOS is idle" from "GlucOS is dead" or "the pump fell off Bluetooth",
    /// and would keep integrating a stale basal rate forever.
    let updatedAt: Double
    let bolus: CurrentBolus?
    let basal: CurrentBasal?
    /// The CGM timestamp of the most recent reading GlucOS ran a loop on, stored
    /// once that loop had finished issuing its pump commands.
    ///
    /// For AI apps that listen in on CGM Bluetooth themselves: they see a
    /// reading at the same time we do, and GlucOS may be about to change the
    /// basal rate in response to it, so anything they read out of this file
    /// before we are done describes the *previous* tick. Once this field reaches
    /// the timestamp of the reading they saw, the rest of the object is GlucOS's
    /// answer to that reading.
    ///
    /// Absent until the first loop that dosed. Comes from the same driver
    /// timestamp as `measuredAt` in `glucose.<UTC_DAY>.jsonl`, so the two join.
    let lastCgmTickHandledAt: Date?
}

// MARK: - glucose.<UTC_DAY>.jsonl

/// One CGM reading.
///
/// Deliberately thinner than what the CGM reports — trend, condition, and the
/// reporting device are all held in GlucOS's own store and none of them are
/// here. An AI app that needs them can read the CGM over Bluetooth directly,
/// where it also gets them sooner than a file we write after the fact.
struct GlucoseRecord: Codable, Equatable {
    /// The CGM's own `syncIdentifier`, which is also the key GlucOS's glucose
    /// store dedupes on, so a reading has one identity everywhere it appears.
    let id: String
    /// When the reading was measured, as reported by the CGM driver rather than
    /// by the sensor, so an AI app reading the same sensor over Bluetooth can
    /// have a slightly different timestamp for this reading.
    let measuredAt: Date
    /// Unrounded, which is what GlucOS's own dosing reads, so a reader
    /// reconstructing a decision sees the number that produced it.
    let glucoseInMgDl: Double
}

// MARK: - meal_announcements.<UTC_DAY>.jsonl
//
// The one file in the container GlucOS reads rather than writes. An AI app owns
// it, so every row is untrusted input: rows can be malformed, half written, or
// contradict an earlier row for the same meal.
//
// What an AI announces is a *description*, not a number. The dose is ours to
// work out — see `MealDosing` — which is the whole reason the description is
// the payload: it is the identity we accumulate dosing history against, and a
// number would have been an answer we can't learn from.

struct MealAnnouncementRecord: Codable, Equatable {
    /// Stable across revisions of the same meal, but only within the app that
    /// wrote it — two apps can pick the same string for two different meals.
    let mealId: String
    /// When the AI wrote this revision. The row with the newest `updatedAt`
    /// wins; this is bookkeeping, not the time of the meal.
    let updatedAt: Date
    /// When the meal starts.
    let startTime: Date
    /// What the AI says the meal is. Also the dosing key: two announcements
    /// carrying the same description, once normalized, are the same meal as far
    /// as run-to-run adaptation is concerned.
    ///
    /// Absent on a **cancellation**. There is no separate retract field and no
    /// version bump for one: a meal with nothing to describe is a meal that
    /// isn't happening, which is exactly what an AI needs to be able to say
    /// after it has already announced. Nothing migrates the older `unitsForMeal`
    /// shape — a row from that era decodes with no description, so it reads as a
    /// cancellation and drops out, which is the right end state for a hint whose
    /// number we would no longer use.
    let mealDescription: String?
}

// MARK: - Pump metadata

/// The pump-derived values that have to be stamped onto every record at write
/// time. People change pumps and insulins over a history, so the record is the
/// only place a given pairing is preserved — we can't recover it later from
/// current pump state.
///
/// `InsulinStorage` has no pump handle, so these are plumbed down from
/// `MosPumpManagerDelegate` alongside the insulin type (stage 2) and persisted
/// as "last known" so they survive a restart with no pump connected.
/// `public` only because it appears in the `InsulinStorage` protocol, which is.
public struct PumpMetadata: Codable, Equatable {
    /// Namespaces `syncIdentifier`, which the pump driver only guarantees to be
    /// unique within one pod's history.
    let pluginIdentifier: String
    /// Smallest positive value of `pumpManager.supportedBolusVolumes`.
    let smallestDeliveryUnit: Double
    /// Fallback for doses that carry no insulin type of their own — notably
    /// `.suspend`, which LoopKit emits without one.
    let insulinType: AiInsulinType

    static let smallestDeliveryUnitDefault = 0.05

    // There is deliberately no `.unknown` placeholder. Published ids are
    // namespaced by `pluginIdentifier`, so a stand-in value mints ids that the
    // real pump metadata later contradicts, and every dose gets published twice
    // under two namespaces. The exporter waits for real metadata instead.
}
