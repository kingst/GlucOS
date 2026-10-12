//
//  MealAnnouncementStorage.swift
//  BioKernel
//
//  Created by Sam King on 8/1/26.
//
//  The read half of the AI interface: the meal announcements AI apps publish
//  into `AiInterface/ai/<bundle.id>/`. See dev/ai-interface.md, "Data written
//  by AIs".
//
//  This file is only the *parser*. It answers "what have the AI apps said
//  lately", over the two days of files the spec guarantees are retained, and
//  nothing more — `MealStorage` is what copies those answers into the 90-day
//  store, and `MealDosing` is what turns one into a dose. The split matters
//  because these files are a window, not a history: an announcement we don't
//  copy out within two days is gone.
//
//  We are not the writer here, so every row is untrusted: the last line of a
//  file can be half written, a row can be malformed, and a later row can revise
//  an earlier one. All three are normal and are handled rather than reported.
//

import Foundation

/// A meal an AI app announced, after revisions have been collapsed.
struct MealAnnouncement: Equatable {
    /// Part of the meal's identity, not decoration: `mealId` is only unique
    /// within the app that wrote it.
    let bundleIdentifier: String
    let mealId: String
    let updatedAt: Date
    let startTime: Date
    /// Nil when the AI is taking the meal back. See `MealAnnouncementRecord`.
    let mealDescription: String?
}

extension MealAnnouncement {
    /// Whether this revision says the meal isn't happening.
    ///
    /// A description that is present but blank counts: an empty string is
    /// nothing to describe and nothing to dose against, and treating it as a
    /// real meal would mint a dosing key that every other blank announcement
    /// then shares.
    var isCancellation: Bool {
        guard let mealDescription else { return true }
        return mealDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

protocol MealAnnouncementStorage: Sendable {
    /// Every announcement in the retained file window, revisions collapsed,
    /// cancellations included.
    ///
    /// Cancellations are *in* the result on purpose. This is the input to
    /// ingestion, and a cancellation is the only way the store learns that a
    /// meal it already copied is off — dropping them here would leave the
    /// retracted meal standing.
    func announcements(at: Date) async -> [MealAnnouncement]
}

actor LocalMealAnnouncementStorage: MealAnnouncementStorage {
    private let aiDirectoryURL: URL?
    private let log = DiagnosticLog(category: "MealAnnouncementStorage")
    private var hasLoggedMissingContainer = false

    /// - Parameter aiDirectoryURL: nil when the app group isn't in the signed
    ///   profile, which makes every read an empty result.
    init(aiDirectoryURL: URL?) {
        self.aiDirectoryURL = aiDirectoryURL
    }

    func announcements(at: Date) async -> [MealAnnouncement] {
        guard let aiDirectoryURL else {
            if !hasLoggedMissingContainer {
                hasLoggedMissingContainer = true
                log.error("no app group container; not reading meal announcements")
            }
            return []
        }

        let rows = Self.readAnnouncements(inAiDirectory: aiDirectoryURL, at: at, log: log)
        return Self.collapseRevisions(announcements: rows)
    }

    // MARK: - Reading

    /// Every announcement from every AI app in the retained file window at `at`.
    ///
    /// Today and yesterday, in UTC. The day in a file name is the day the row
    /// was appended rather than the day the meal starts, so a meal that began
    /// an hour ago can be in yesterday's file if the clock has just crossed
    /// midnight UTC. Two days is also all the spec guarantees is retained, so
    /// an AI that announces a meal more than a day before it starts can have
    /// its original row age out from under us; the revision that would be
    /// appended when the meal is served would not.
    static func readAnnouncements(inAiDirectory aiURL: URL, at: Date, log: DiagnosticLog? = nil) -> [MealAnnouncement] {
        let days = Set([at, at - 1.0.daysToSeconds()].map { AiInterfaceContainer.utcDay(for: $0) })

        return AiInterfaceContainer.mealAnnouncementFiles(inAiDirectory: aiURL, utcDays: days).flatMap { file -> [MealAnnouncement] in
            guard let data = try? Data(contentsOf: file.url) else {
                // Someone else's file: it can vanish between the directory
                // listing and the read, or still be protected if the app that
                // wrote it didn't mark it NSFileProtectionNone and we're before
                // first unlock. Neither is ours to fix.
                log?.error("could not read %{public}@", file.url.lastPathComponent)
                return []
            }
            return announcements(fromJsonl: data, bundleIdentifier: file.bundleIdentifier, log: log)
        }
    }

    /// Pure, so the parsing rules are testable without a file system.
    static func announcements(fromJsonl data: Data, bundleIdentifier: String, log: DiagnosticLog? = nil) -> [MealAnnouncement] {
        let decoder = JSONDecoder()
        // The wire format is epoch seconds. A default decoder reads the same
        // numbers as seconds since 2001 and lands 31 years off without ever
        // erroring, which would silently empty the window.
        decoder.dateDecodingStrategy = .secondsSince1970

        // Appends are not atomic, so the final line may be half written.
        // Splitting without omitting empty subsequences makes the last element
        // either the empty remainder after a trailing newline or a partial
        // record, and dropping it is right in both cases.
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast()

        return lines.compactMap { line -> MealAnnouncement? in
            guard !line.isEmpty else { return nil }
            guard let record = try? decoder.decode(MealAnnouncementRecord.self, from: Data(line)) else {
                // One bad row must not cost us the rows around it.
                log?.error("skipping a malformed meal announcement from %{public}@", bundleIdentifier)
                return nil
            }
            return MealAnnouncement(
                bundleIdentifier: bundleIdentifier,
                mealId: record.mealId,
                updatedAt: record.updatedAt,
                startTime: record.startTime,
                mealDescription: record.mealDescription
            )
        }
    }

    // MARK: - Collapsing revisions

    /// One row per `(bundleIdentifier, mealId)`: the revision with the newest
    /// `updatedAt`.
    ///
    /// Returned in a stable order — start time, then the identity — because the
    /// caller writes these to a store and a nondeterministic order makes a
    /// same-instant tie land differently from one ingest to the next.
    static func collapseRevisions(announcements: [MealAnnouncement]) -> [MealAnnouncement] {
        var revised: [MealKey: MealAnnouncement] = [:]
        for announcement in announcements {
            let key = MealKey(bundleIdentifier: announcement.bundleIdentifier, mealId: announcement.mealId)
            // `>=` keeps the earlier row when two revisions claim the same
            // `updatedAt`. The spec doesn't break that tie, so we take the one
            // that was appended first and stay put rather than flip-flopping.
            if let existing = revised[key], existing.updatedAt >= announcement.updatedAt { continue }
            revised[key] = announcement
        }

        return revised.values.sorted { sortKey($0) < sortKey($1) }
    }

    private struct MealKey: Hashable {
        let bundleIdentifier: String
        let mealId: String
    }

    /// A total order, because dictionary iteration order isn't stable.
    private static func sortKey(_ announcement: MealAnnouncement) -> (Double, Double, String, String) {
        return (
            announcement.startTime.timeIntervalSince1970,
            announcement.updatedAt.timeIntervalSince1970,
            announcement.bundleIdentifier,
            announcement.mealId
        )
    }
}
