//
//  MealAnnouncementTests.swift
//  BioKernelTests
//
//  Created by Sam King on 8/1/26.
//
//  The read half of the AI interface. Everything here is somebody else's file,
//  so most of these tests are about surviving input we don't control: half
//  written lines, malformed rows, revisions, and two apps that picked the same
//  `mealId`.
//

import Testing
import Foundation

@testable import BioKernel

struct MealAnnouncementTests {

    // MARK: - Fixtures

    /// A fresh temp directory standing in for `AiInterface/ai/`.
    func makeAiDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("ai", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes rows the way an AI app would: one JSON object per line, epoch
    /// seconds, newline terminated.
    @discardableResult
    func write(
        _ rows: [String],
        bundleIdentifier: String,
        day: String,
        in aiURL: URL,
        newlineTerminated: Bool = true
    ) throws -> URL {
        let appURL = aiURL.appendingPathComponent(bundleIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let url = appURL.appendingPathComponent(AiInterfaceContainer.mealAnnouncementFileName(forUtcDay: day))
        var text = rows.joined(separator: "\n")
        if newlineTerminated {
            text += "\n"
        }
        try Data(text.utf8).write(to: url)
        return url
    }

    func row(mealId: String, updatedAt: Date, startTime: Date, mealDescription: String?) -> String {
        let base = "{\"mealId\":\"\(mealId)\",\"updatedAt\":\(updatedAt.timeIntervalSince1970),\"startTime\":\(startTime.timeIntervalSince1970)"
        guard let mealDescription else {
            // A cancellation: the field is absent, not null and not empty.
            return base + "}"
        }
        return base + ",\"mealDescription\":\"\(mealDescription)\"}"
    }

    func announcement(
        _ mealId: String,
        bundleIdentifier: String = "com.example.coach",
        updatedAt: Date,
        startTime: Date,
        mealDescription: String? = "eggs and toast"
    ) -> MealAnnouncement {
        return MealAnnouncement(
            bundleIdentifier: bundleIdentifier,
            mealId: mealId,
            updatedAt: updatedAt,
            startTime: startTime,
            mealDescription: mealDescription
        )
    }

    let coach = "com.example.coach"
    let other = "com.example.other"

    // MARK: - Parsing

    @Test func aWellFormedFileParsesEveryRow() throws {
        let now = Date.f("2026-03-14 12:00:00 +0000")
        let data = Data(([
            row(mealId: "m1", updatedAt: now, startTime: now, mealDescription: "eggs and toast"),
            row(mealId: "m2", updatedAt: now, startTime: now + 60, mealDescription: "burrito")
        ].joined(separator: "\n") + "\n").utf8)

        let parsed = LocalMealAnnouncementStorage.announcements(fromJsonl: data, bundleIdentifier: coach)

        #expect(parsed.count == 2)
        #expect(parsed.map { $0.mealId } == ["m1", "m2"])
        #expect(parsed.map { $0.bundleIdentifier } == [coach, coach])
        #expect(parsed.first?.mealDescription == "eggs and toast")
        // Epoch seconds, not seconds since 2001: a default decoder would land
        // this row 31 years off without erroring.
        #expect(parsed.first?.startTime == now)
    }

    @Test func aRowWithNoDescriptionIsACancellation() throws {
        let now = Date.f("2026-03-14 12:00:00 +0000")
        let data = Data((row(mealId: "m1", updatedAt: now, startTime: now, mealDescription: nil) + "\n").utf8)

        let parsed = LocalMealAnnouncementStorage.announcements(fromJsonl: data, bundleIdentifier: coach)

        // It parses — the field is optional, so this is a valid record rather
        // than a malformed one — and it reads as taking the meal back.
        #expect(parsed.count == 1)
        #expect(parsed.first?.isCancellation == true)
    }

    @Test func aBlankDescriptionIsAlsoACancellation() throws {
        let now = Date.f("2026-03-14 12:00:00 +0000")
        // Nothing to describe and nothing to dose against. Treated as a
        // cancellation rather than a meal, so it can't mint a dosing key that
        // every other blank announcement then shares.
        #expect(announcement("m1", updatedAt: now, startTime: now, mealDescription: "").isCancellation)
        #expect(announcement("m2", updatedAt: now, startTime: now, mealDescription: "   \n").isCancellation)
        #expect(!announcement("m3", updatedAt: now, startTime: now, mealDescription: "toast").isCancellation)
    }

    @Test func aTrailingLineWithNoNewlineIsDropped() throws {
        let now = Date.f("2026-03-14 12:00:00 +0000")
        let complete = row(mealId: "m1", updatedAt: now, startTime: now, mealDescription: "eggs")
        // The writer was interrupted mid-append.
        let partial = String(row(mealId: "m2", updatedAt: now, startTime: now, mealDescription: "burrito").dropLast(12))
        let data = Data((complete + "\n" + partial).utf8)

        let parsed = LocalMealAnnouncementStorage.announcements(fromJsonl: data, bundleIdentifier: coach)

        #expect(parsed.map { $0.mealId } == ["m1"])
    }

    @Test func aMalformedRowDoesNotCostUsTheRowsAroundIt() throws {
        let now = Date.f("2026-03-14 12:00:00 +0000")
        let data = Data(([
            row(mealId: "m1", updatedAt: now, startTime: now, mealDescription: "eggs"),
            "{\"mealId\":\"m2\"}",                                    // no updatedAt, no startTime
            "not json at all",
            "",                                                       // a stray blank line
            row(mealId: "m3", updatedAt: now, startTime: now, mealDescription: "burrito")
        ].joined(separator: "\n") + "\n").utf8)

        let parsed = LocalMealAnnouncementStorage.announcements(fromJsonl: data, bundleIdentifier: coach)

        #expect(parsed.map { $0.mealId } == ["m1", "m3"])
    }

    @Test func anEmptyFileParsesToNothing() throws {
        let parsed = LocalMealAnnouncementStorage.announcements(fromJsonl: Data(), bundleIdentifier: coach)
        #expect(parsed.isEmpty)
    }

    // MARK: - Collapsing revisions

    @Test func theNewestRevisionOfAMealWins() throws {
        let now = Date.f("2026-03-14 12:00:00 +0000")
        let original = announcement("m1", updatedAt: now, startTime: now, mealDescription: "eggs")
        let revised = announcement("m1", updatedAt: now + 300, startTime: now, mealDescription: "eggs and toast")

        // Order in the file must not matter — rows are appended, not sorted.
        for input in [[original, revised], [revised, original]] {
            let collapsed = LocalMealAnnouncementStorage.collapseRevisions(announcements: input)
            #expect(collapsed.count == 1)
            #expect(collapsed.first?.mealDescription == "eggs and toast")
        }
    }

    @Test func aCancellationIsKeptRatherThanDropped() throws {
        let now = Date.f("2026-03-14 12:00:00 +0000")
        let announced = announcement("m1", updatedAt: now, startTime: now, mealDescription: "eggs")
        let cancelled = announcement("m1", updatedAt: now + 300, startTime: now, mealDescription: nil)

        let collapsed = LocalMealAnnouncementStorage.collapseRevisions(announcements: [announced, cancelled])

        // Ingestion is the caller, and a cancellation is the only way the store
        // learns that a meal it already copied is off. Filtering it out here
        // would leave the retracted meal standing.
        #expect(collapsed.count == 1)
        #expect(collapsed.first?.isCancellation == true)
    }

    @Test func twoAppsCanUseTheSameMealIdForDifferentMeals() throws {
        let now = Date.f("2026-03-14 12:00:00 +0000")
        // `mealId` is only unique within an app, so these are two meals rather
        // than one revising the other.
        let theirs = announcement("m1", bundleIdentifier: other, updatedAt: now, startTime: now, mealDescription: "burrito")
        let ours = announcement("m1", bundleIdentifier: coach, updatedAt: now, startTime: now, mealDescription: "eggs")

        let collapsed = LocalMealAnnouncementStorage.collapseRevisions(announcements: [ours, theirs])

        #expect(collapsed.count == 2)
    }

    @Test func theCollapsedOrderIsTotal() throws {
        let now = Date.f("2026-03-14 12:00:00 +0000")
        let a = announcement("m1", bundleIdentifier: coach, updatedAt: now, startTime: now)
        let b = announcement("m1", bundleIdentifier: other, updatedAt: now, startTime: now)

        // Dictionary iteration order isn't stable, so without a total order two
        // meals sharing a start time would land in the store in a different
        // order from one ingest to the next.
        let expected = LocalMealAnnouncementStorage.collapseRevisions(announcements: [a, b])
        for _ in 0..<20 {
            #expect(LocalMealAnnouncementStorage.collapseRevisions(announcements: [b, a]) == expected)
        }
    }

    @Test func revisionsThatTieOnUpdatedAtKeepTheFirstRow() throws {
        let now = Date.f("2026-03-14 12:00:00 +0000")
        let first = announcement("m1", updatedAt: now, startTime: now, mealDescription: "eggs")
        let second = announcement("m1", updatedAt: now, startTime: now, mealDescription: "burrito")

        // The spec doesn't break this tie, so we stay put on the row that was
        // appended first rather than flip-flopping between polls.
        let collapsed = LocalMealAnnouncementStorage.collapseRevisions(announcements: [first, second])
        #expect(collapsed.first?.mealDescription == "eggs")
    }

    // MARK: - Reading the container

    @Test func announcementsAreReadFromEveryAiApp() async throws {
        let aiURL = try makeAiDirectory()
        let now = Date.f("2026-03-14 12:00:00 +0000")
        let day = AiInterfaceContainer.utcDay(for: now)

        try write([row(mealId: "m1", updatedAt: now - 3600, startTime: now - 3600, mealDescription: "eggs")],
                  bundleIdentifier: coach, day: day, in: aiURL)
        try write([row(mealId: "m1", updatedAt: now - 600, startTime: now - 600, mealDescription: "burrito")],
                  bundleIdentifier: other, day: day, in: aiURL)

        let storage = LocalMealAnnouncementStorage(aiDirectoryURL: aiURL)
        let read = await storage.announcements(at: now)

        #expect(Set(read.map { $0.bundleIdentifier }) == Set([coach, other]))
        #expect(Set(read.compactMap { $0.mealDescription }) == Set(["eggs", "burrito"]))
    }

    @Test func yesterdaysFileIsReadTooBecauseTheDayIsPickedAtAppendTime() async throws {
        let aiURL = try makeAiDirectory()
        // Just past midnight UTC. A meal an hour ago was announced yesterday, so
        // its row is in yesterday's file.
        let now = Date.f("2026-03-15 00:30:00 +0000")
        let start = now - 1.0.hoursToSeconds()
        try write([row(mealId: "m1", updatedAt: start, startTime: start, mealDescription: "eggs")],
                  bundleIdentifier: coach, day: AiInterfaceContainer.utcDay(for: start), in: aiURL)

        let storage = LocalMealAnnouncementStorage(aiDirectoryURL: aiURL)
        let read = await storage.announcements(at: now)

        #expect(read.map { $0.mealId } == ["m1"])
        #expect(read.first?.startTime == start)
    }

    @Test func aRevisionAppendedAfterMidnightWinsOverYesterdaysRow() async throws {
        let aiURL = try makeAiDirectory()
        let now = Date.f("2026-03-15 00:30:00 +0000")
        let start = now - 1.0.hoursToSeconds()

        try write([row(mealId: "m1", updatedAt: start, startTime: start, mealDescription: "eggs")],
                  bundleIdentifier: coach, day: AiInterfaceContainer.utcDay(for: start), in: aiURL)
        try write([row(mealId: "m1", updatedAt: now, startTime: start, mealDescription: "eggs and toast")],
                  bundleIdentifier: coach, day: AiInterfaceContainer.utcDay(for: now), in: aiURL)

        let storage = LocalMealAnnouncementStorage(aiDirectoryURL: aiURL)
        let read = await storage.announcements(at: now)

        #expect(read.count == 1)
        #expect(read.first?.mealDescription == "eggs and toast")
    }

    @Test func olderDayFilesAreLeftUnread() async throws {
        let aiURL = try makeAiDirectory()
        let now = Date.f("2026-03-14 12:00:00 +0000")
        let old = now - 3.0.daysToSeconds()
        try write([row(mealId: "m1", updatedAt: old, startTime: now - 600, mealDescription: "eggs")],
                  bundleIdentifier: coach, day: AiInterfaceContainer.utcDay(for: old), in: aiURL)

        let storage = LocalMealAnnouncementStorage(aiDirectoryURL: aiURL)
        #expect(await storage.announcements(at: now).isEmpty)
    }

    @Test func filesThatArentMealAnnouncementsAreIgnored() async throws {
        let aiURL = try makeAiDirectory()
        let now = Date.f("2026-03-14 12:00:00 +0000")
        let day = AiInterfaceContainer.utcDay(for: now)
        let appURL = aiURL.appendingPathComponent(coach, isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)

        // An AI app's own scratch files, and a day stamp that isn't a day.
        let valid = row(mealId: "m1", updatedAt: now, startTime: now - 600, mealDescription: "eggs") + "\n"
        for name in ["notes.json", "meal_announcements.latest.jsonl", "meal_announcements.2026-13-45.jsonl"] {
            try Data(valid.utf8).write(to: appURL.appendingPathComponent(name))
        }

        let storage = LocalMealAnnouncementStorage(aiDirectoryURL: aiURL)
        #expect(await storage.announcements(at: now).isEmpty)

        // The same row under a name we recognize does come through, so the test
        // above is about the name and not about the row.
        try write([row(mealId: "m1", updatedAt: now, startTime: now - 600, mealDescription: "eggs")],
                  bundleIdentifier: coach, day: day, in: aiURL)
        #expect(!(await storage.announcements(at: now).isEmpty))
    }

    @Test func anEmptyOrMissingAiDirectoryIsNotAnError() async throws {
        let now = Date.f("2026-03-14 12:00:00 +0000")

        // No AI app has ever run: the directory doesn't exist.
        let missing = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("ai", isDirectory: true)
        #expect(await LocalMealAnnouncementStorage(aiDirectoryURL: missing).announcements(at: now).isEmpty)

        // It exists but is empty.
        #expect(await LocalMealAnnouncementStorage(aiDirectoryURL: try makeAiDirectory()).announcements(at: now).isEmpty)

        // A signing regression took the app group away.
        #expect(await LocalMealAnnouncementStorage(aiDirectoryURL: nil).announcements(at: now).isEmpty)
    }

    @Test func weCreateNothingInTheAiSubtree() async throws {
        let aiURL = try makeAiDirectory()
        let now = Date.f("2026-03-14 12:00:00 +0000")
        try write([row(mealId: "m1", updatedAt: now, startTime: now - 600, mealDescription: "eggs")],
                  bundleIdentifier: coach, day: AiInterfaceContainer.utcDay(for: now), in: aiURL)

        let before = try FileManager.default.contentsOfDirectory(atPath: aiURL.appendingPathComponent(coach).path)
        let storage = LocalMealAnnouncementStorage(aiDirectoryURL: aiURL)
        _ = await storage.announcements(at: now)
        let after = try FileManager.default.contentsOfDirectory(atPath: aiURL.appendingPathComponent(coach).path)

        #expect(Set(before) == Set(after))
        #expect(try FileManager.default.contentsOfDirectory(atPath: aiURL.path) == [coach])
    }

    // MARK: - The universal link

    @Test func aMealLinkRoundTrips() throws {
        let url = try #require(MealAnnouncementLink.url(bundleIdentifier: coach, mealId: "m1"))
        let parsed = try #require(MealAnnouncementLink.parse(url))

        // The domain has to match the entitlement and the association file
        // ClueClue's server publishes, or iOS never routes the link here.
        #expect(url.host() == "typezero.ai")
        #expect(parsed.bundleIdentifier == coach)
        #expect(parsed.mealId == "m1")
    }

    @Test func theHostIsNotWhatGatesAMealLink() throws {
        // Only the path is matched. The association file on typezero.ai is what
        // decides which hosts can deliver a link here at all, so re-checking
        // the host would be a second gate that can only disagree with it.
        //
        // The foreign host below documents that: it parses, and the only reason
        // such a URL never arrives is that nothing claims `/meal` there.
        for host in ["typezero.ai", "example.com"] {
            let url = try #require(URL(string: "https://\(host)/meal?bundleId=a&mealId=b"))
            #expect(MealAnnouncementLink.parse(url) != nil, "\(host) should parse")
        }
    }

    @Test func aMealLinkSurvivesIdsThatNeedEscaping() throws {
        // Both halves are opaque strings an AI app chose, which is why they are
        // query parameters rather than path components.
        let mealId = "meal/1 2+3&x=y"
        let url = try #require(MealAnnouncementLink.url(bundleIdentifier: coach, mealId: mealId))
        let parsed = try #require(MealAnnouncementLink.parse(url))

        #expect(parsed.mealId == mealId)
    }

    @Test func urlsThatArentMealLinksAreNotClaimed() throws {
        // The settings link this shares a domain with, and a few near misses.
        // `MainView` falls through to settings when parse returns nil, so
        // anything claimed here is taken away from that.
        let notOurs = [
            // A JSON blob as the last path component — the shape the retired
            // settings-import link used. It must not read as a meal link.
            "https://typezero.ai/%7B%22created%22%3A1%7D",
            "https://typezero.ai/meals?bundleId=a&mealId=b",
            "https://typezero.ai/meal?bundleId=a",
            "https://typezero.ai/meal?mealId=b",
            "https://typezero.ai/meal",
            "https://typezero.ai/meal?bundleId=&mealId=b"
        ]
        for string in notOurs {
            let url = try #require(URL(string: string))
            #expect(MealAnnouncementLink.parse(url) == nil, "\(string) should not parse")
        }
    }
}
