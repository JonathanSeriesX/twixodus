// Step 4 of the pipeline: pick which threads to import for the date range.
//
// A thread whose first tweet falls inside the configured range is imported as
// usual. Threads that *started* before the range but were extended with new
// tweets inside it are a special case: Day One can't update an existing entry,
// so the whole thread has to be imported again and the older, shorter copy
// deleted by hand. This module finds those threads, and formats the reminder
// to delete the duplicates.

import Foundation

/// What a run would do with an archive, computed up front for the UI: how many
/// threads are new, how many grew since their import and need the full
/// re-import treatment, and how many are already in Day One. Mirrors exactly
/// what the engine will skip and import.
public struct ImportPreview {
    public var newThreads = 0
    public var grownThreads = 0
    public var alreadyImported = 0
    /// What the run will actually send to Day One.
    public var pending: Int { newThreads + grownThreads }
}

/// A tiny deterministic generator (SplitMix64), so importOrder == .random
/// shuffles reproducibly from a seed. The Retrieve step plans against the
/// same permutation the import will walk.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The threads a run will walk, in order, with the counts the log reports.
public struct RunPlan {
    /// Every thread the run will consider, re-imports first.
    public var imports: [PlannedImport]
    /// Threads left after the debug-ID filter, before the date partition.
    public var consideredThreads: Int
    public var reimportCount: Int
    public var inRangeCount: Int
}

public enum ThreadSelection {

    /// Step 4 in one call: narrow to the debug IDs, put the threads in the
    /// configured order, split them by date against the ledger, and plan the
    /// re-imports first so a per-run limit can't starve them.
    ///
    /// The engine runs this to build its plan; the Retrieve step runs it to
    /// find out which threads the next import will actually touch — one
    /// definition of "what this run does", not two.
    public static func planRun(
        _ threads: [TweetThread], config: ImportConfig, processedIDs: Set<String>
    ) -> RunPlan {
        var threads = threads
        if !config.debugTweetIDs.isEmpty {
            threads = filterToDebugIDs(threads, ids: config.debugTweetIDs)
        }

        switch config.importOrder {
        case .oldestFirst:
            threads = threads.stableSorted { $0[0].createdAt < $1[0].createdAt }
        case .newestFirst:
            threads = threads.stableSorted { $0[0].createdAt > $1[0].createdAt }
        case .random:
            var generator = SeededGenerator(seed: config.randomSeed)
            threads.shuffle(using: &generator)
        }

        let (inRange, extended) = partitionThreadsByDate(
            threads, startDate: config.startDate, endDate: config.endDate,
            processedIDs: processedIDs, coveredThrough: config.lastCoveredThrough)

        return RunPlan(
            imports: extended.map { PlannedImport(thread: $0, isReimport: true) }
                + inRange.map { PlannedImport(thread: $0, isReimport: false) },
            consideredThreads: threads.count,
            reimportCount: extended.count,
            inRangeCount: inRange.count)
    }

    /// The threads this run will actually turn into entries: the ones still
    /// pending in the ledger, cut off at the per-run limit. Already-imported
    /// threads are dropped — the run skips them without spending its budget.
    public static func threadsThisRunWillImport(
        _ plan: [PlannedImport], processedIDs: Set<String>, limit: Int?
    ) -> [TweetThread] {
        var picked: [TweetThread] = []
        for planned in plan {
            if let limit, picked.count >= limit { break }
            let key = planned.isReimport
                ? ImportLedger.extensionMarker(planned.thread)
                : planned.thread[0].idStr
            if !processedIDs.contains(key) {
                picked.append(planned.thread)
            }
        }
        return picked
    }

    /// Computes the ImportPreview for these threads against the ledger state,
    /// with the same selection rules the run itself will use.
    public static func preview(
        _ threads: [TweetThread], startDate: Date, endDate: Date,
        processedIDs: Set<String>, coveredThrough: Date?
    ) -> ImportPreview {
        let (inRange, extended) = partitionThreadsByDate(
            threads, startDate: startDate, endDate: endDate,
            processedIDs: processedIDs, coveredThrough: coveredThrough)
        let newThreads = inRange.filter { !processedIDs.contains($0[0].idStr) }.count
        let grown = extended.filter { !processedIDs.contains(ImportLedger.extensionMarker($0)) }.count
        return ImportPreview(
            newThreads: newThreads,
            grownThreads: grown,
            alreadyImported: (inRange.count - newThreads) + (extended.count - grown))
    }

    /// Splits threads into the ones to import normally and the ones to re-import.
    ///
    /// Returns (inRange, extended):
    ///   - inRange: threads whose first tweet was posted within the date range.
    ///   - extended: threads that already live in Day One as a shorter entry and
    ///     gained tweets since. Either they began before the range and grew into
    ///     it, or — when the last import's coverage point is known — they were
    ///     imported whole and their tail is newer than that point. Both kinds get
    ///     imported again in full and reported to the user.
    ///
    /// Threads that started after the range, or that ended before it, are dropped.
    public static func partitionThreadsByDate(
        _ threads: [TweetThread], startDate: Date, endDate: Date,
        processedIDs: Set<String> = [], coveredThrough: Date? = nil
    ) -> (inRange: [TweetThread], extended: [TweetThread]) {
        var inRange: [TweetThread] = []
        var extended: [TweetThread] = []

        for thread in threads {
            guard let root = thread.first else { continue }
            let rootDate = root.createdAt

            if startDate <= rootDate && rootDate <= endDate {
                // An already-imported thread whose tail is newer than what the
                // last import covered has grown since — Day One can't extend
                // the existing entry, so it needs the full re-import treatment
                // even though its root falls inside the range.
                if let covered = coveredThrough, rootDate <= covered,
                   processedIDs.contains(root.idStr),
                   thread.contains(where: { covered < $0.createdAt && $0.createdAt <= endDate }) {
                    extended.append(thread)
                } else {
                    inRange.append(thread)
                }
            } else if rootDate < startDate,
                      thread.dropFirst().contains(where: { startDate <= $0.createdAt && $0.createdAt <= endDate }) {
                extended.append(thread)
            }
        }

        return (inRange, extended)
    }

    /// Debug helper: keeps only the threads containing any of the listed
    /// tweet IDs. (The Python version matched root IDs only; matching any
    /// tweet is friendlier when the interesting tweet sits mid-thread.)
    public static func filterToDebugIDs(_ threads: [TweetThread], ids: Set<String>) -> [TweetThread] {
        threads.filter { thread in thread.contains { ids.contains($0.idStr) } }
    }

    /// Counts the tweets the already-imported copy of this thread is expected
    /// to hold: everything before the range — or, when the last import's
    /// coverage point is known and the thread existed by then, everything up
    /// to that point (a completed import always took the whole thread as the
    /// archive had it).
    public static func countTweetsBefore(
        _ thread: TweetThread, startDate: Date, coveredThrough: Date? = nil
    ) -> Int {
        let beforeRange = thread.filter { $0.createdAt < startDate }.count
        guard let covered = coveredThrough,
              let rootDate = thread.first?.createdAt, rootDate <= covered
        else { return beforeRange }
        return max(beforeRange, thread.filter { $0.createdAt <= covered }.count)
    }

    /// Builds a link to a tweet, falling back to the account-agnostic URL.
    public static func tweetURL(tweetId: String, username: String?) -> String {
        if let username, !username.isEmpty {
            return "https://twitter.com/\(username)/status/\(tweetId)"
        }
        return "https://twitter.com/i/web/status/\(tweetId)"
    }

    private static let reportDateFormatter = PipelineDates.formatter("dd MMMM yyyy, HH:mm")

    /// Formats the list of re-imported threads into a reminder to delete the
    /// older duplicates.
    public static func formatReimportReport(
        _ reimported: [ImportedEntry], username: String?
    ) -> String {
        let line = String(repeating: "=", count: 72)
        let header = """
            \(line)
            ⚠️  ACTION REQUIRED — \(reimported.count) thread(s) were re-imported in full
            \(line)
            These threads were imported once before, but you added more tweets to
            them afterwards. Day One can't extend an existing entry, so each one was
            imported again as a complete thread — which leaves an older, shorter
            copy in your journal. Delete the older copy of each:

            """

        var blocks: [String] = []
        for (i, entry) in reimported.enumerated() {
            let dateStr = reportDateFormatter.string(from: entry.date)
            let oldEntryStr: String
            if let count = entry.previousTweetCount, count != 0 {
                oldEntryStr = "≈\(count) tweets (the shorter, previously imported copy)"
            } else {
                oldEntryStr = "the shorter, previously imported copy"
            }
            blocks.append("""

                \(i + 1). \(dateStr) — “\(entry.title)”
                   Journal: \(entry.journal)
                   Old entry to delete: \(oldEntryStr)
                   New entry: \(entry.tweetCount) tweets
                   First tweet: \(tweetURL(tweetId: entry.tweetId, username: username))

                """)
        }

        let footer = """

            Both copies share the same entry date, so searching that date in Day One
            will show them side by side — keep the longer one.

            """

        return header + blocks.joined() + footer
    }
}
