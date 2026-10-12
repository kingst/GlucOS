//
//  AiInterfaceContainer.swift
//  BioKernel
//
//  Created by Sam King on 8/1/26.
//
//  File-system mechanics for the shared app-group container GlucOS publishes
//  into. See dev/backlog/ai-interface-prompt.md §7.
//
//  Two invariants this type is responsible for:
//
//    - Everything GlucOS creates is NSFileProtectionNone. The app runs before
//      first unlock on CGM/pump wake, and a protected file would fail to open
//      exactly when the loop needs it.
//
//    - GlucOS is the single writer for `AiInterface/GlucOS/` and touches
//      nothing else in the container. `ai/<bundle.id>/` belongs to the AI apps.
//
//  Nothing here throws. A missing container, a full disk, or a failed
//  `FileHandle` degrades to a logged no-op: publishing data for an AI app must
//  never be able to take insulin delivery down with it.
//

import Foundation

struct AiInterfaceContainer {
    /// Must stay in sync with the `com.apple.security.application-groups` entry
    /// in BioKernel.entitlements. This is the only place it appears in Swift.
    ///
    /// App group identifiers are registered to one developer team and the
    /// entitlement only validates against that team's provisioning profile, so
    /// a third-party AI app either ships under the same team or the user
    /// self-builds both apps and edits the identifier in these two places.
    static let appGroupIdentifier = "group.com.getgrowthmetrics.BioKernel.AiInterface"

    static let rootDirectoryName = "AiInterface"
    static let writerDirectoryName = "GlucOS"
    /// `AiInterface/ai/<bundle.id>/` — written by the AI apps, one directory per
    /// app. GlucOS never writes here; it only enumerates it for the export UI.
    static let aiDirectoryName = "ai"
    static let currentInsulinDosingFileName = "current_insulin_dosing.json"
    static let finalizedPrefix = "finalized_insulin_dosing."
    static let finalizedSuffix = ".jsonl"
    static let glucosePrefix = "glucose."
    static let glucoseSuffix = ".jsonl"

    /// The day-stamped families we write. Everything that walks the writer
    /// directory — retention, the reset, the export listing — iterates this
    /// rather than naming one family, so adding a third file type can't quietly
    /// leave one of them behind.
    static let dayFileFamilies: [(prefix: String, suffix: String)] = [
        (finalizedPrefix, finalizedSuffix),
        (glucosePrefix, glucoseSuffix)
    ]
    /// `ai/<bundle.id>/meal_announcements.<UTC_DAY>.jsonl`. Named here so we can
    /// find the files; the name is the only thing GlucOS knows about them, since
    /// the AI app is their writer.
    static let mealAnnouncementPrefix = "meal_announcements."
    static let mealAnnouncementSuffix = ".jsonl"

    /// GlucOS retains 90 UTC days of finalized insulin and glucose records. The
    /// requirements doc asks for at least 2 days so a reader can always rebuild
    /// its own picture, and for 90 for these two families specifically.
    static let retentionInDays = 90

    /// How many finalized day files the export UI hands to a share sheet.
    ///
    /// Well short of `retentionInDays`: the point of the export is to get a few
    /// recent days off the device to look at, and 90 attachments is not that.
    /// Three covers the day being debugged plus the rollover on either side of
    /// it, which matters because a record's day file is picked at append time —
    /// a record that started yesterday can be in today's file, and one appended
    /// just before midnight UTC can be in the file before the one you'd expect.
    static let exportInDays = 3

    /// `<base>/AiInterface` — shared with AI apps, we only create it.
    let rootURL: URL
    /// `<base>/AiInterface/GlucOS` — the only directory GlucOS may write to.
    let writerURL: URL

    private let log = DiagnosticLog(category: "AiInterfaceContainer")

    // MARK: - Construction

    /// Resolves the real app-group container.
    ///
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil
    /// whenever the group isn't in the signed profile, so a signing regression
    /// shows up here as a logged nil rather than a crash.
    static func appGroupContainer() -> AiInterfaceContainer? {
        let log = DiagnosticLog(category: "AiInterfaceContainer")
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            log.error("app group %{public}@ is not available; AI interface publishing is disabled", appGroupIdentifier)
            return nil
        }
        return AiInterfaceContainer(baseURL: base)
    }

    /// Tests point `baseURL` at a temp directory. Returns nil if the directory
    /// tree can't be created, which callers treat as "publishing is off".
    init?(baseURL: URL) {
        let rootURL = baseURL.appendingPathComponent(Self.rootDirectoryName, isDirectory: true)
        let writerURL = rootURL.appendingPathComponent(Self.writerDirectoryName, isDirectory: true)

        // Create each level explicitly rather than relying on
        // withIntermediateDirectories, which does not promise to apply the
        // attributes to the intermediates it creates.
        for url in [rootURL, writerURL] {
            do {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.none]
                )
            } catch {
                let log = DiagnosticLog(category: "AiInterfaceContainer")
                log.error("could not create %{public}@: %{public}@", url.lastPathComponent, String(describing: error))
                return nil
            }
        }

        self.rootURL = rootURL
        self.writerURL = writerURL

        // createDirectory only applies attributes when it actually creates the
        // directory, so a tree left over from a prior install keeps whatever
        // protection it had. Re-assert on both levels every launch.
        setProtectionNone(at: rootURL)
        setProtectionNone(at: writerURL)

        // One line per launch naming the container we actually got. The shared
        // container lives at /Shared/AppGroup/<UUID>/ and a re-provisioned group
        // can leave a stale one behind, so the UUID is the only way to tell
        // which of them an external tool is looking at versus which one we
        // write to.
        log.default("publishing to %{public}@", writerURL.path)
    }

    // MARK: - Reading back what we published

    /// The files we offer in the export UI: `current_insulin_dosing.json` plus
    /// the newest `exportInDays` day files of each day-stamped family. Creates
    /// nothing and returns empty when the group is unavailable.
    static func publishedFileURLs() -> [URL] {
        guard let rootURL = sharedRootURL() else { return [] }
        return publishedFileURLs(inWriterDirectory: rootURL.appendingPathComponent(writerDirectoryName, isDirectory: true))
    }

    /// Split out from the app-group lookup so tests can point it at a temp tree.
    ///
    /// "Newest" is the newest days that exist, not the last `exportInDays`
    /// calendar days — a device that stopped publishing a week ago should still
    /// export the last three days it managed, since that is exactly the case
    /// you'd be exporting to look at. Day-stamped names are zero-padded ISO, so
    /// `regularFiles` already has them in chronological order.
    ///
    /// The limit applies per family rather than across all day files, so a day of
    /// glucose can't push a day of insulin out of the share sheet.
    ///
    /// Anything of ours that isn't a day file rides along unfiltered, which is
    /// how `current_insulin_dosing.json` gets in.
    static func publishedFileURLs(inWriterDirectory writerURL: URL) -> [URL] {
        let files = regularFiles(in: writerURL)
        var newestDayFiles = Set<URL>()
        for family in dayFileFamilies {
            let dayFiles = files.filter { isDayFile($0, of: family) }
            newestDayFiles.formUnion(dayFiles.suffix(exportInDays))
        }
        return files.filter { url in
            !dayFileFamilies.contains { isDayFile(url, of: $0) } || newestDayFiles.contains(url)
        }
    }

    private static func isDayFile(_ url: URL, of family: (prefix: String, suffix: String)) -> Bool {
        return utcDay(fromFileName: url.lastPathComponent, prefix: family.prefix, suffix: family.suffix) != nil
    }

    // MARK: - Reading back what the AI apps published

    /// What the AI apps have published, for the export UI: the newest
    /// `exportInDays` day files per app, grouped by bundle id and sorted by it.
    ///
    /// GlucOS is not the writer for this subtree, so this is read-only in the
    /// strongest sense the single-writer rule implies: we enumerate, we don't
    /// create the directories we're looking for, we don't touch the files'
    /// attributes, and the export UI offers no way to delete any of them.
    static func aiFilesForExport() -> [AiAppFiles] {
        guard let aiURL = sharedAiDirectoryURL() else { return [] }
        return aiFilesForExport(inAiDirectory: aiURL)
    }

    /// Split out from the app-group lookup so tests can point it at a temp tree.
    ///
    /// Deliberately a layer above `aiPublishedFiles(inAiDirectory:)` rather than
    /// folded into it: that listing also feeds `mealAnnouncementFiles(utcDays:)`,
    /// which the meal banner reads, and a limit that exists to keep a share
    /// sheet manageable has no business narrowing what the app itself can see.
    static func aiFilesForExport(inAiDirectory aiURL: URL) -> [AiAppFiles] {
        return aiPublishedFiles(inAiDirectory: aiURL).map { app in
            let dayFiles = app.urls.filter { utcDay(fromMealAnnouncementFileName: $0.lastPathComponent) != nil }
            let newestDayFiles = Set(dayFiles.suffix(exportInDays))
            // Anything of theirs that isn't a day file rides along, the way
            // `current_insulin_dosing.json` does on our own side.
            return AiAppFiles(bundleIdentifier: app.bundleIdentifier, urls: app.urls.filter { url in
                utcDay(fromMealAnnouncementFileName: url.lastPathComponent) == nil || newestDayFiles.contains(url)
            })
        }
    }

    /// Split out from the app-group lookup so tests can point it at a temp tree.
    static func aiPublishedFiles(inAiDirectory aiURL: URL) -> [AiAppFiles] {
        // A missing `ai/` directory is the normal case rather than an error: it
        // appears the first time an AI app writes into the shared container.
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: aiURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.compactMap { url -> AiAppFiles? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let files = regularFiles(in: url)
            // An app that has a directory but hasn't written anything into it
            // yet has nothing to export.
            guard !files.isEmpty else { return nil }
            return AiAppFiles(bundleIdentifier: url.lastPathComponent, urls: files)
        }.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    }

    /// Every AI app's meal announcement file for the given UTC days.
    ///
    /// Days are matched against the file name rather than the file's contents:
    /// a row's own `startTime` says nothing about which day file it landed in,
    /// because the writer picks the day at append time just as we do.
    static func mealAnnouncementFiles(utcDays: Set<String>) -> [MealAnnouncementFile] {
        guard let aiURL = sharedAiDirectoryURL() else { return [] }
        return mealAnnouncementFiles(inAiDirectory: aiURL, utcDays: utcDays)
    }

    /// Split out from the app-group lookup so tests can point it at a temp tree.
    static func mealAnnouncementFiles(inAiDirectory aiURL: URL, utcDays: Set<String>) -> [MealAnnouncementFile] {
        return aiPublishedFiles(inAiDirectory: aiURL).flatMap { app in
            app.urls.filter { url in
                guard let day = utcDay(fromMealAnnouncementFileName: url.lastPathComponent) else { return false }
                return utcDays.contains(day)
            }.map { MealAnnouncementFile(bundleIdentifier: app.bundleIdentifier, url: $0) }
        }
    }

    /// `AiInterface/ai/` in the shared container, resolved without creating it —
    /// GlucOS is not its writer, and an app group where no AI app has ever run
    /// simply doesn't have one.
    static func sharedAiDirectoryURL() -> URL? {
        return sharedRootURL()?.appendingPathComponent(aiDirectoryName, isDirectory: true)
    }

    /// `AiInterface/` in the shared container, resolved without creating
    /// anything — unlike `init?`, which builds the tree GlucOS writes to.
    private static func sharedRootURL() -> URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return nil
        }
        return base.appendingPathComponent(rootDirectoryName, isDirectory: true)
    }

    /// Files only, sorted by name. Day-stamped names are zero-padded ISO, so
    /// that ordering is chronological. Directories are dropped because the
    /// export UI can neither size nor share one.
    private static func regularFiles(in directoryURL: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - UTC days

    /// `YYYY-MM-DD` in UTC. Pinned to en_US_POSIX so a user's calendar or
    /// numbering system can never reshape a file name.
    private static let utcDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Always computed at append time, never from a record's own timestamps —
    /// a record finalized just after midnight UTC belongs in the new day's file
    /// even though its `startTime` is in the previous day.
    static func utcDay(for date: Date) -> String {
        return utcDayFormatter.string(from: date)
    }

    static func date(forUtcDay day: String) -> Date? {
        return utcDayFormatter.date(from: day)
    }

    static func finalizedFileName(forUtcDay day: String) -> String {
        return "\(finalizedPrefix)\(day)\(finalizedSuffix)"
    }

    static func glucoseFileName(forUtcDay day: String) -> String {
        return "\(glucosePrefix)\(day)\(glucoseSuffix)"
    }

    static func mealAnnouncementFileName(forUtcDay day: String) -> String {
        return "\(mealAnnouncementPrefix)\(day)\(mealAnnouncementSuffix)"
    }

    /// Returns the UTC day encoded in a finalized file name, or nil if the name
    /// isn't one of ours or doesn't carry a well-formed day. Callers use nil to
    /// mean "leave this file alone".
    static func utcDay(fromFinalizedFileName name: String) -> String? {
        return utcDay(fromFileName: name, prefix: finalizedPrefix, suffix: finalizedSuffix)
    }

    /// Same, for a glucose day file.
    static func utcDay(fromGlucoseFileName name: String) -> String? {
        return utcDay(fromFileName: name, prefix: glucosePrefix, suffix: glucoseSuffix)
    }

    /// Same, for a file an AI app wrote. nil means "not a meal announcement
    /// file", which is the only reason we'd open something in their subtree.
    static func utcDay(fromMealAnnouncementFileName name: String) -> String? {
        return utcDay(fromFileName: name, prefix: mealAnnouncementPrefix, suffix: mealAnnouncementSuffix)
    }

    private static func utcDay(fromFileName name: String, prefix: String, suffix: String) -> String? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let day = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        // Round-trip through the formatter so "2026-13-45" or "latest" can't
        // look like a day we're willing to delete.
        guard let parsed = date(forUtcDay: day), utcDay(for: parsed) == day else { return nil }
        return day
    }

    // MARK: - Paths

    var currentInsulinDosingURL: URL {
        return writerURL.appendingPathComponent(Self.currentInsulinDosingFileName, isDirectory: false)
    }

    func finalizedURL(forUtcDay day: String) -> URL {
        return writerURL.appendingPathComponent(Self.finalizedFileName(forUtcDay: day), isDirectory: false)
    }

    func glucoseURL(forUtcDay day: String) -> URL {
        return writerURL.appendingPathComponent(Self.glucoseFileName(forUtcDay: day), isDirectory: false)
    }

    // MARK: - Writing

    /// Atomically replaces `current_insulin_dosing.json`.
    ///
    /// `.atomic` writes a temp file and renames it, and `.noFileProtection` is
    /// applied before the rename, so a reader never sees a half-written object
    /// and the result is never protected. Same pattern as `StoredJsonObject`.
    @discardableResult
    func writeCurrentInsulinDosing(_ data: Data) -> Bool {
        do {
            try data.write(to: currentInsulinDosingURL, options: [.atomic, .noFileProtection])
            return true
        } catch {
            log.error("failed to write current_insulin_dosing.json: %{public}@", String(describing: error))
            return false
        }
    }

    /// Appends one complete `line + "\n"` to
    /// `finalized_insulin_dosing.<UTC_DAY>.jsonl`.
    @discardableResult
    func appendFinalized(line: Data, utcDay day: String) -> Bool {
        return append(line: line, to: finalizedURL(forUtcDay: day))
    }

    /// The same, for `glucose.<UTC_DAY>.jsonl`.
    @discardableResult
    func appendGlucose(line: Data, utcDay day: String) -> Bool {
        return append(line: line, to: glucoseURL(forUtcDay: day))
    }

    /// One complete line, written in a single call.
    ///
    /// Appends can't be atomic, so a reader is told to drop any trailing line
    /// without a newline. Writing the whole line in one call keeps that window
    /// as small as the file system will allow.
    private func append(line: Data, to url: URL) -> Bool {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.protectionKey: FileProtectionType.none]
            ) else {
                log.error("failed to create %{public}@", url.lastPathComponent)
                return false
            }
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            return true
        } catch {
            log.error("failed to append to %{public}@: %{public}@", url.lastPathComponent, String(describing: error))
            return false
        }
    }

    // MARK: - Retention

    /// Every finalized file we own, newest day last. Files we don't recognize
    /// are skipped rather than reported — the single-writer rule cuts both ways.
    func finalizedDayFiles() -> [(day: String, url: URL)] {
        return dayFiles(prefix: Self.finalizedPrefix, suffix: Self.finalizedSuffix)
    }

    /// The same, for `glucose.<UTC_DAY>.jsonl`.
    func glucoseDayFiles() -> [(day: String, url: URL)] {
        return dayFiles(prefix: Self.glucosePrefix, suffix: Self.glucoseSuffix)
    }

    private func dayFiles(prefix: String, suffix: String) -> [(day: String, url: URL)] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: writerURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            log.error("could not enumerate the writer directory: %{public}@", String(describing: error))
            return []
        }

        return contents.compactMap { url -> (day: String, url: URL)? in
            guard let day = Self.utcDay(fromFileName: url.lastPathComponent, prefix: prefix, suffix: suffix) else {
                return nil
            }
            return (day: day, url: url)
        }.sorted { $0.day < $1.day }
    }

    /// Deletes finalized insulin files older than `retentionInDays` UTC days.
    ///
    /// The day comes out of the file name — we never stat, because the mtime of
    /// a file reflects when a record was appended, not the day it covers.
    /// Day strings are zero-padded ISO, so lexicographic order is chronological.
    @discardableResult
    func pruneFinalizedFiles(at now: Date) -> Int {
        return prune(finalizedDayFiles(), at: now)
    }

    /// The same, for `glucose.<UTC_DAY>.jsonl`. Separate from the insulin pass so
    /// each family's retention is legible on its own, even though the two share
    /// one horizon.
    @discardableResult
    func pruneGlucoseFiles(at now: Date) -> Int {
        return prune(glucoseDayFiles(), at: now)
    }

    private func prune(_ files: [(day: String, url: URL)], at now: Date) -> Int {
        let cutoffDay = Self.utcDay(for: now - Double(Self.retentionInDays).daysToSeconds())
        var deleted = 0
        for file in files where file.day < cutoffDay {
            do {
                try FileManager.default.removeItem(at: file.url)
                deleted += 1
                log.default("pruned %{public}@", file.url.lastPathComponent)
            } catch {
                log.error("failed to prune %{public}@: %{public}@", file.url.lastPathComponent, String(describing: error))
            }
        }
        return deleted
    }

    /// Removes every file GlucOS has published.
    ///
    /// Scoped to `AiInterface/GlucOS/` and to names we recognize, so the
    /// single-writer rule holds even here: an AI app's subtree, and anything in
    /// our own directory that isn't ours, is left alone.
    @discardableResult
    func deletePublishedFiles() -> Int {
        var urls = (finalizedDayFiles() + glucoseDayFiles()).map { $0.url }
        if FileManager.default.fileExists(atPath: currentInsulinDosingURL.path) {
            urls.append(currentInsulinDosingURL)
        }

        var deleted = 0
        for url in urls {
            do {
                try FileManager.default.removeItem(at: url)
                deleted += 1
            } catch {
                log.error("failed to delete %{public}@: %{public}@", url.lastPathComponent, String(describing: error))
            }
        }
        return deleted
    }

    // MARK: - File protection

    /// Re-asserts `NSFileProtectionNone` across everything GlucOS owns, the way
    /// `AppComposition.migrateExistingFilesToNoFileProtection` does for the
    /// documents directory. Covers files left behind by an older build.
    ///
    /// Deliberately stops at `AiInterface/GlucOS/` — we never modify an AI app's
    /// subtree, not even its attributes.
    func reassertFileProtection() {
        setProtectionNone(at: rootURL)
        setProtectionNone(at: writerURL)

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: writerURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }

        for url in contents {
            setProtectionNone(at: url)
        }
    }

    private func setProtectionNone(at url: URL) {
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: url.path)
        } catch {
            log.error("could not set file protection on %{public}@: %{public}@", url.lastPathComponent, String(describing: error))
        }
    }
}

/// One AI app's files from `AiInterface/ai/<bundle.id>/`.
///
/// The bundle id has to travel with the URLs rather than being recoverable from
/// them at the point of use: every app writes the same
/// `meal_announcements.<UTC_DAY>.jsonl` name, so a flat list of file names from
/// two apps is ambiguous about which app wrote what.
struct AiAppFiles: Equatable {
    let bundleIdentifier: String
    let urls: [URL]
}

/// One AI app's meal announcement file for one UTC day.
///
/// The bundle id travels with the URL for the same reason it does above, and
/// one more: `mealId` is only unique within an app, so the app that wrote a row
/// is part of that row's identity.
struct MealAnnouncementFile: Equatable {
    let bundleIdentifier: String
    let url: URL
}
